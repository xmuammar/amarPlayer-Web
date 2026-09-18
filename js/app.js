import {
  addHistory, getCachedTracks, getFavorites, getHistory, getQueue,
  getSetting, replaceTracks, saveQueue, setFavorite, setSetting
} from "./db.js";
import { AudioEngine, FREQUENCIES, PRESETS } from "./audio-engine.js";
import { loadAuthConfig, startLogin } from "./oidc.js";

const $ = id => document.getElementById(id);

const audio = $("audio");
const engine = new AudioEngine(audio);

const state = {
  library: [],
  favorites: new Set(),
  queue: [],
  currentIndex: -1,
  currentTrack: null,
  view: "library",
  search: "",
  sort: "artist",
  shuffle: false,
  repeat: "off",
  lastHistoryTrackId: null,
  scannerOnline: false,
  auth: { enabled: false },
};

let toastTimer;
let eventSource;

function toast(message) {
  const el = $("toast");
  el.textContent = message;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 2200);
}

function formatTime(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const min = Math.floor(seconds / 60);
  const sec = Math.floor(seconds % 60).toString().padStart(2, "0");
  return `${min}:${sec}`;
}

function technical(track) {
  if (!track) return "";
  const values = [];
  if (track.extension) values.push(track.extension);
  if (track.bitrate) values.push(`${Math.round(track.bitrate / 1000)} kbps`);
  if (track.sample_rate) values.push(`${(track.sample_rate / 1000).toFixed(1)} kHz`);
  if (track.channels) values.push(`${track.channels} ch`);
  return values.join(" · ");
}

function currentQueueIndex(id) {
  return state.queue.findIndex(track => track.id === id);
}

function sortTracks(tracks) {
  const copy = [...tracks];
  switch (state.sort) {
    case "title":
      copy.sort((a, b) => a.title.localeCompare(b.title));
      break;
    case "album":
      copy.sort((a, b) => (a.album || "").localeCompare(b.album || "") || a.title.localeCompare(b.title));
      break;
    case "recent":
      copy.sort((a, b) => b.modified - a.modified);
      break;
    default:
      copy.sort((a, b) =>
        (a.artist || "").localeCompare(b.artist || "") ||
        (a.album || "").localeCompare(b.album || "") ||
        a.title.localeCompare(b.title)
      );
  }
  return copy;
}

async function rebuildQueue() {
  const savedIds = await getQueue();
  const map = new Map(state.library.map(track => [track.id, track]));
  const restored = savedIds.map(id => map.get(id)).filter(Boolean);
  const remaining = state.library.filter(track => !savedIds.includes(track.id));
  state.queue = [...restored, ...sortTracks(remaining)];

  if (!savedIds.length) {
    state.queue = sortTracks(state.library);
    await saveQueue(state.queue.map(track => track.id));
  }
}

async function syncLibrary({ silent = false } = {}) {
  try {
    const response = await fetch("/api/library", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();

    const playingId = state.currentTrack?.id ?? null;
    state.library = data.tracks;
    state.scannerOnline = true;
    await replaceTracks(state.library);
    await rebuildQueue();

    if (playingId) {
      const replacement = state.queue.find(track => track.id === playingId);
      if (replacement) {
        state.currentTrack = replacement;
        state.currentIndex = currentQueueIndex(playingId);
      }
    }

    scannerUI(true, `${data.count} tracks · ${data.scan_dirs.join(", ") || "no folder"}`);
    render();
  } catch (error) {
    state.scannerOnline = false;
    scannerUI(false, "Backend tidak terhubung · menggunakan metadata cache");
    const cached = await getCachedTracks();
    if (cached.length && !state.library.length) {
      state.library = cached;
      await rebuildQueue();
      render();
    }
    if (!silent) toast("Local scanner tidak terhubung");
  }
}

function scannerUI(online, detail) {
  $("scannerDot").classList.toggle("online", online);
  $("scannerDot").classList.toggle("offline", !online);
  $("scannerStatus").textContent = online ? "Scanner Online" : "Scanner Offline";
  $("scannerDetail").textContent = detail;
}

function filteredTracks() {
  let tracks;

  if (state.view === "favorites") {
    tracks = state.library.filter(track => state.favorites.has(track.id));
  } else if (state.view === "history") {
    return [];
  } else {
    tracks = state.library;
  }

  const query = state.search.trim().toLowerCase();
  if (query) {
    tracks = tracks.filter(track =>
      [track.title, track.artist, track.album, track.genre]
        .filter(Boolean)
        .some(value => value.toLowerCase().includes(query))
    );
  }
  return sortTracks(tracks);
}

function rowForTrack(track, index) {
  const row = document.createElement("div");
  row.className = "track-row";
  if (track.id === state.currentTrack?.id) row.classList.add("active");

  const favorite = state.favorites.has(track.id);
  row.innerHTML = `
    <div class="track-index">${track.id === state.currentTrack?.id && !audio.paused ? "▶" : index + 1}</div>
    <div class="track-primary">
      <strong></strong>
      <small></small>
    </div>
    <div class="track-album"></div>
    <div class="track-duration">${formatTime(track.duration)}</div>
    <button class="heart-btn ${favorite ? "active" : ""}" title="Favorite">${favorite ? "♥" : "♡"}</button>
  `;
  row.querySelector(".track-primary strong").textContent = track.title;
  row.querySelector(".track-primary small").textContent = track.artist || "Unknown Artist";
  row.querySelector(".track-album").textContent = track.album || "Unknown Album";

  row.addEventListener("click", () => playTrackById(track.id));
  row.querySelector(".heart-btn").addEventListener("click", async event => {
    event.stopPropagation();
    await toggleFavorite(track.id);
  });
  return row;
}

async function renderHistory() {
  const container = $("trackList");
  const history = await getHistory(100);
  const query = state.search.trim().toLowerCase();
  const visible = history.filter(row =>
    !query || [row.title, row.artist, row.album].filter(Boolean).some(v => v.toLowerCase().includes(query))
  );

  container.replaceChildren();
  $("resultCount").textContent = `${visible.length} plays`;

  if (!visible.length) {
    container.innerHTML = `<div class="empty">Belum ada riwayat pemutaran.</div>`;
    return;
  }

  for (const [index, event] of visible.entries()) {
    const track = state.library.find(item => item.id === event.trackId);
    const row = document.createElement("div");
    row.className = "track-row";
    const when = new Date(event.playedAt).toLocaleString();
    row.innerHTML = `
      <div class="track-index">${index + 1}</div>
      <div class="track-primary"><strong></strong><small></small></div>
      <div class="track-album"></div>
      <div class="track-duration">${track ? formatTime(track.duration) : ""}</div>
      <button class="heart-btn" title="${when}">↺</button>
    `;
    row.querySelector(".track-primary strong").textContent = event.title;
    row.querySelector(".track-primary small").textContent = event.artist || "Unknown Artist";
    row.querySelector(".track-album").textContent = event.album || "Unknown Album";
    if (track) row.addEventListener("click", () => playTrackById(track.id));
    container.append(row);
  }
}

function render() {
  $("songCount").textContent = state.library.length;
  $("favoriteCount").textContent = state.favorites.size;

  const titles = {
    library: ["LOCAL MUSIC", "Library", "Music Library", "Automatic scanner"],
    favorites: ["YOUR MUSIC", "Favorites", "Favorite Tracks", "Stored in IndexedDB"],
    history: ["RECENTLY PLAYED", "History", "Playback History", "Stored locally"],
  };
  const [eyebrow, title, listTitle, subtitle] = titles[state.view];
  $("viewEyebrow").textContent = eyebrow;
  $("viewTitle").textContent = title;
  $("listTitle").textContent = listTitle;
  $("listSubtitle").textContent = subtitle;

  document.querySelectorAll(".nav-item").forEach(button => {
    button.classList.toggle("active", button.dataset.view === state.view);
  });

  if (state.view === "history") {
    renderHistory();
    return;
  }

  const visible = filteredTracks();
  $("resultCount").textContent = `${visible.length} tracks`;
  const container = $("trackList");
  container.replaceChildren();

  if (!visible.length) {
    container.innerHTML = `<div class="empty">${state.library.length ? "Tidak ada lagu yang cocok." : "Tidak ada musik yang ditemukan. Periksa amarplayer-config.json."}</div>`;
    return;
  }

  visible.forEach((track, index) => container.append(rowForTrack(track, index)));
}

async function playTrackById(id, autoplay = true) {
  const index = currentQueueIndex(id);
  if (index < 0) return;
  await loadTrack(index, autoplay);
}

async function loadTrack(index, autoplay = true) {
  if (!state.queue.length) return;
  if (index < 0 || index >= state.queue.length) return;

  state.currentIndex = index;
  state.currentTrack = state.queue[index];
  const track = state.currentTrack;

  const wasSame = audio.dataset.trackId === track.id;
  if (!wasSame) {
    audio.src = track.stream_url;
    audio.dataset.trackId = track.id;
    audio.load();
  }

  $("trackTitle").textContent = track.title;
  $("trackMeta").textContent = `${track.artist || "Unknown Artist"} · ${track.album || "Unknown Album"}`;
  $("trackTechnical").textContent = technical(track);
  $("footerTitle").textContent = track.title;
  $("footerArtist").textContent = track.artist || "Unknown Artist";
  $("favoriteBtn").disabled = false;
  updateFavoriteMain();
  updateArtwork(track);
  updateMediaSession(track);
  document.title = `${track.title} — amarPlayer`;

  render();

  if (autoplay) {
    try {
      await engine.resume();
      await audio.play();
    } catch (error) {
      console.error(error);
      toast("Browser menahan autoplay. Tekan Play.");
    }
  }
}

function updateArtwork(track) {
  const src = track.cover_url + `?m=${Math.round(track.modified || 0)}`;
  const cover = $("coverArt");
  const mini = $("miniCover");

  cover.hidden = false;
  mini.hidden = false;
  $("coverFallback").hidden = true;
  $("miniCoverFallback").hidden = true;

  const failed = () => {
    cover.hidden = true;
    mini.hidden = true;
    $("coverFallback").hidden = false;
    $("miniCoverFallback").hidden = false;
  };
  cover.onerror = failed;
  mini.onerror = failed;
  cover.src = src;
  mini.src = src;
}

function updateFavoriteMain() {
  const active = state.currentTrack && state.favorites.has(state.currentTrack.id);
  $("favoriteBtn").classList.toggle("active", !!active);
  $("favoriteBtn").textContent = active ? "♥ Favorite" : "♡ Favorite";
}

async function toggleFavorite(id) {
  const enabled = !state.favorites.has(id);
  if (enabled) state.favorites.add(id);
  else state.favorites.delete(id);
  await setFavorite(id, enabled);
  updateFavoriteMain();
  render();
}

async function togglePlay() {
  if (!state.currentTrack && state.queue.length) await loadTrack(0, false);
  if (!state.currentTrack) return;
  await engine.resume();
  if (audio.paused) await audio.play();
  else audio.pause();
}

async function nextTrack({ fromEnded = false } = {}) {
  if (!state.queue.length) return;

  if (fromEnded && state.repeat === "one") {
    audio.currentTime = 0;
    await audio.play();
    return;
  }

  let next;
  if (state.shuffle && state.queue.length > 1) {
    do next = Math.floor(Math.random() * state.queue.length);
    while (next === state.currentIndex);
  } else {
    next = state.currentIndex + 1;
    if (next >= state.queue.length) {
      if (state.repeat === "all") next = 0;
      else if (fromEnded) {
        audio.pause();
        return;
      } else next = 0;
    }
  }
  await loadTrack(next, true);
}

async function previousTrack() {
  if (!state.queue.length) return;
  if (audio.currentTime > 3) {
    audio.currentTime = 0;
    return;
  }
  let previous = state.currentIndex - 1;
  if (previous < 0) previous = state.queue.length - 1;
  await loadTrack(previous, true);
}

function updateMediaSession(track) {
  if (!("mediaSession" in navigator)) return;
  navigator.mediaSession.metadata = new MediaMetadata({
    title: track.title,
    artist: track.artist || "Unknown Artist",
    album: track.album || "Unknown Album",
    artwork: [
      { src: new URL(track.cover_url, location.origin).href, sizes: "512x512" }
    ],
  });
}

function updateMediaPosition() {
  if (!("mediaSession" in navigator) || !navigator.mediaSession.setPositionState) return;
  if (!Number.isFinite(audio.duration) || audio.duration <= 0) return;
  try {
    navigator.mediaSession.setPositionState({
      duration: audio.duration,
      playbackRate: audio.playbackRate,
      position: Math.min(audio.currentTime, audio.duration),
    });
  } catch {}
}

async function initEQ() {
  const savedValues = await getSetting("eqValues", PRESETS.Flat);
  const savedPreset = await getSetting("eqPreset", "Flat");
  engine.values = Array.isArray(savedValues) && savedValues.length === 10 ? savedValues.map(Number) : [...PRESETS.Flat];

  const container = $("eqBands");
  container.replaceChildren();

  FREQUENCIES.forEach((frequency, index) => {
    const band = document.createElement("div");
    band.className = "eq-band";
    const label = frequency >= 1000 ? `${frequency / 1000}k` : String(frequency);
    band.innerHTML = `
      <input type="range" min="-12" max="12" step="0.5" value="${engine.values[index]}" aria-label="${label} Hz">
      <b>${label}</b>
      <span>${Number(engine.values[index]).toFixed(1)}</span>
    `;
    const slider = band.querySelector("input");
    const value = band.querySelector("span");
    slider.addEventListener("input", async () => {
      const gain = Number(slider.value);
      value.textContent = gain.toFixed(1);
      await engine.setBand(index, gain);
      $("presetSelect").value = "Custom";
      await setSetting("eqPreset", "Custom");
      await setSetting("eqValues", [...engine.values]);
    });
    container.append(band);
  });

  $("presetSelect").value = savedPreset in PRESETS || savedPreset === "Custom" ? savedPreset : "Custom";
}

async function applyPreset(name) {
  if (name === "Custom") return;
  const values = PRESETS[name] ?? PRESETS.Flat;
  await engine.applyValues(values);
  document.querySelectorAll("#eqBands input").forEach((slider, index) => {
    slider.value = values[index];
    slider.parentElement.querySelector("span").textContent = Number(values[index]).toFixed(1);
  });
  await setSetting("eqPreset", name);
  await setSetting("eqValues", values);
}

function drawSpectrum() {
  const canvas = $("spectrum");
  const ctx = canvas.getContext("2d");

  const renderFrame = () => {
    const width = canvas.width = Math.max(300, Math.round(canvas.clientWidth * devicePixelRatio));
    const height = canvas.height = Math.max(100, Math.round(canvas.clientHeight * devicePixelRatio));
    ctx.clearRect(0, 0, width, height);

    const data = engine.frequencyData();
    if (!data) {
      ctx.fillStyle = "rgba(255,255,255,.06)";
      for (let i = 0; i < 36; i++) {
        const x = (i / 36) * width;
        const h = ((i % 7) + 1) / 10 * height;
        ctx.fillRect(x, height - h, Math.max(2, width / 60), h);
      }
      requestAnimationFrame(renderFrame);
      return;
    }

    const bars = Math.min(64, data.length);
    const step = Math.floor(data.length / bars);
    const gap = Math.max(2, width / 350);
    const barWidth = width / bars - gap;

    for (let i = 0; i < bars; i++) {
      const value = data[i * step] / 255;
      const h = Math.max(2, value * height * .92);
      const x = i * (barWidth + gap);
      ctx.fillStyle = `rgba(255,255,255,${0.18 + value * 0.8})`;
      ctx.fillRect(x, height - h, Math.max(1, barWidth), h);
    }
    requestAnimationFrame(renderFrame);
  };

  requestAnimationFrame(renderFrame);
}

function connectLibraryEvents() {
  try {
    eventSource = new EventSource("/api/events");
    eventSource.addEventListener("library", () => syncLibrary({ silent: true }));
    eventSource.onerror = () => {
      eventSource?.close();
      setTimeout(connectLibraryEvents, 5000);
    };
  } catch {
    setInterval(() => syncLibrary({ silent: true }), 10000);
  }
}

async function initAuth() {
  state.auth = await loadAuthConfig();
  if (!state.auth.enabled) return;
  $("accountCard").hidden = false;
  $("loginBtn").addEventListener("click", () => startLogin(state.auth));
}

function bindEvents() {
  document.querySelectorAll(".nav-item").forEach(button => {
    button.addEventListener("click", () => {
      state.view = button.dataset.view;
      render();
    });
  });

  $("searchInput").addEventListener("input", event => {
    state.search = event.target.value;
    render();
  });

  $("sortSelect").addEventListener("change", async event => {
    state.sort = event.target.value;
    await setSetting("sort", state.sort);
    if (state.view !== "history") render();
  });

  $("rescanBtn").addEventListener("click", async () => {
    $("rescanBtn").disabled = true;
    $("rescanBtn").textContent = "Scanning…";
    try {
      const response = await fetch("/api/rescan", { method: "POST" });
      if (!response.ok) throw new Error();
      await syncLibrary({ silent: true });
      toast("Library selesai dipindai");
    } catch {
      toast("Rescan gagal");
    } finally {
      $("rescanBtn").disabled = false;
      $("rescanBtn").textContent = "Rescan Library";
    }
  });

  $("playBtn").addEventListener("click", togglePlay);
  $("nextBtn").addEventListener("click", () => nextTrack());
  $("prevBtn").addEventListener("click", previousTrack);

  $("shuffleBtn").addEventListener("click", async () => {
    state.shuffle = !state.shuffle;
    $("shuffleBtn").classList.toggle("active", state.shuffle);
    await setSetting("shuffle", state.shuffle);
  });

  $("repeatBtn").addEventListener("click", async () => {
    state.repeat = state.repeat === "off" ? "all" : state.repeat === "all" ? "one" : "off";
    $("repeatBtn").classList.toggle("active", state.repeat !== "off");
    $("repeatBtn").textContent = state.repeat === "one" ? "↻¹" : "↻";
    $("repeatBtn").title = `Repeat: ${state.repeat}`;
    await setSetting("repeat", state.repeat);
  });

  $("favoriteBtn").addEventListener("click", async () => {
    if (state.currentTrack) await toggleFavorite(state.currentTrack.id);
  });

  $("volume").addEventListener("input", async event => {
    audio.volume = Number(event.target.value);
    await setSetting("volume", audio.volume);
  });

  $("progress").addEventListener("input", event => {
    if (Number.isFinite(audio.duration)) {
      audio.currentTime = (Number(event.target.value) / 1000) * audio.duration;
    }
  });

  $("presetSelect").addEventListener("change", event => applyPreset(event.target.value));
  $("eqResetBtn").addEventListener("click", () => {
    $("presetSelect").value = "Flat";
    applyPreset("Flat");
  });

  audio.addEventListener("play", async () => {
    $("playBtn").textContent = "⏸";
    render();
    if ("mediaSession" in navigator) navigator.mediaSession.playbackState = "playing";

    if (state.currentTrack && state.lastHistoryTrackId !== state.currentTrack.id) {
      state.lastHistoryTrackId = state.currentTrack.id;
      await addHistory(state.currentTrack);
      if (state.view === "history") render();
    }
  });

  audio.addEventListener("pause", () => {
    $("playBtn").textContent = "▶";
    render();
    if ("mediaSession" in navigator) navigator.mediaSession.playbackState = "paused";
  });

  audio.addEventListener("ended", () => nextTrack({ fromEnded: true }));

  audio.addEventListener("loadedmetadata", () => {
    $("duration").textContent = formatTime(audio.duration);
  });

  audio.addEventListener("timeupdate", () => {
    $("currentTime").textContent = formatTime(audio.currentTime);
    $("duration").textContent = formatTime(audio.duration);
    if (Number.isFinite(audio.duration) && audio.duration > 0) {
      $("progress").value = Math.round((audio.currentTime / audio.duration) * 1000);
    }
    updateMediaPosition();
  });

  audio.addEventListener("error", () => {
    if (state.currentTrack) toast(`Gagal memutar ${state.currentTrack.name}`);
  });

  if ("mediaSession" in navigator) {
    navigator.mediaSession.setActionHandler("play", () => togglePlay());
    navigator.mediaSession.setActionHandler("pause", () => audio.pause());
    navigator.mediaSession.setActionHandler("previoustrack", previousTrack);
    navigator.mediaSession.setActionHandler("nexttrack", () => nextTrack());
    navigator.mediaSession.setActionHandler("seekto", details => {
      if (Number.isFinite(details.seekTime)) audio.currentTime = details.seekTime;
    });
    navigator.mediaSession.setActionHandler("seekbackward", details => {
      audio.currentTime = Math.max(0, audio.currentTime - (details.seekOffset || 10));
    });
    navigator.mediaSession.setActionHandler("seekforward", details => {
      audio.currentTime = Math.min(audio.duration || Infinity, audio.currentTime + (details.seekOffset || 10));
    });
  }
}

async function restoreSettings() {
  state.sort = await getSetting("sort", "artist");
  state.shuffle = Boolean(await getSetting("shuffle", false));
  state.repeat = await getSetting("repeat", "off");
  audio.volume = Number(await getSetting("volume", 0.8));

  $("sortSelect").value = state.sort;
  $("volume").value = audio.volume;
  $("shuffleBtn").classList.toggle("active", state.shuffle);
  $("repeatBtn").classList.toggle("active", state.repeat !== "off");
  $("repeatBtn").textContent = state.repeat === "one" ? "↻¹" : "↻";
}

async function init() {
  state.favorites = await getFavorites();
  await restoreSettings();
  await initEQ();
  bindEvents();
  drawSpectrum();
  await syncLibrary({ silent: true });
  connectLibraryEvents();
  await initAuth();

  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/service-worker.js").catch(console.error);
  }
}

init().catch(error => {
  console.error(error);
  toast("amarPlayer gagal melakukan inisialisasi");
});
