const DB_NAME = "amarPlayerDB";
const DB_VERSION = 1;

let dbPromise;

function requestToPromise(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export function openDB() {
  if (dbPromise) return dbPromise;

  dbPromise = new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);

    request.onupgradeneeded = () => {
      const db = request.result;

      if (!db.objectStoreNames.contains("tracks")) {
        db.createObjectStore("tracks", { keyPath: "id" });
      }
      if (!db.objectStoreNames.contains("favorites")) {
        db.createObjectStore("favorites", { keyPath: "id" });
      }
      if (!db.objectStoreNames.contains("history")) {
        const store = db.createObjectStore("history", { keyPath: "eventId", autoIncrement: true });
        store.createIndex("playedAt", "playedAt");
      }
      if (!db.objectStoreNames.contains("settings")) {
        db.createObjectStore("settings", { keyPath: "key" });
      }
      if (!db.objectStoreNames.contains("playlists")) {
        db.createObjectStore("playlists", { keyPath: "id" });
      }
    };

    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });

  return dbPromise;
}

export async function replaceTracks(tracks) {
  const db = await openDB();
  const tx = db.transaction("tracks", "readwrite");
  const store = tx.objectStore("tracks");
  store.clear();
  for (const track of tracks) store.put(track);
  await new Promise((resolve, reject) => {
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

export async function getCachedTracks() {
  const db = await openDB();
  return requestToPromise(db.transaction("tracks").objectStore("tracks").getAll());
}

export async function getFavorites() {
  const db = await openDB();
  const rows = await requestToPromise(db.transaction("favorites").objectStore("favorites").getAll());
  return new Set(rows.map(row => row.id));
}

export async function setFavorite(id, enabled) {
  const db = await openDB();
  const tx = db.transaction("favorites", "readwrite");
  const store = tx.objectStore("favorites");
  if (enabled) store.put({ id, savedAt: Date.now() });
  else store.delete(id);
  await new Promise((resolve, reject) => {
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
}

export async function addHistory(track) {
  const db = await openDB();
  const tx = db.transaction("history", "readwrite");
  tx.objectStore("history").add({
    trackId: track.id,
    title: track.title,
    artist: track.artist,
    album: track.album,
    playedAt: Date.now(),
  });
  await new Promise((resolve, reject) => {
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
  await trimHistory(200);
}

async function trimHistory(limit) {
  const db = await openDB();
  const keys = await requestToPromise(
    db.transaction("history", "readonly").objectStore("history").getAllKeys()
  );
  const remove = Math.max(0, keys.length - limit);
  if (!remove) return;

  const tx = db.transaction("history", "readwrite");
  const store = tx.objectStore("history");
  for (const key of keys.slice(0, remove)) store.delete(key);

  await new Promise((resolve, reject) => {
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
}

export async function getHistory(limit = 100) {
  const db = await openDB();
  const rows = await requestToPromise(db.transaction("history").objectStore("history").getAll());
  return rows.sort((a, b) => b.playedAt - a.playedAt).slice(0, limit);
}

export async function getSetting(key, fallback = null) {
  const db = await openDB();
  const row = await requestToPromise(db.transaction("settings").objectStore("settings").get(key));
  return row ? row.value : fallback;
}

export async function setSetting(key, value) {
  const db = await openDB();
  const tx = db.transaction("settings", "readwrite");
  tx.objectStore("settings").put({ key, value });
  await new Promise((resolve, reject) => {
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
}

export async function saveQueue(ids) {
  const db = await openDB();
  const tx = db.transaction("playlists", "readwrite");
  tx.objectStore("playlists").put({ id: "current", trackIds: ids, updatedAt: Date.now() });
  await new Promise((resolve, reject) => {
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
}

export async function getQueue() {
  const db = await openDB();
  const row = await requestToPromise(db.transaction("playlists").objectStore("playlists").get("current"));
  return row?.trackIds ?? [];
}
