#!/usr/bin/env bash
set -euo pipefail

TARGET="${AMARPLAYER_DIR:-$HOME/amarPlayer-Web}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$TARGET/backups/pre-v1-$STAMP"

mkdir -p "$TARGET" "$BACKUP" "$TARGET/css" "$TARGET/js" "$TARGET/icons" "$TARGET/tests"

echo "== amarPlayer Web v1.0 upgrade =="
echo "Target : $TARGET"
echo "Backup : $BACKUP"

for item in server.py index.html css js service-worker.js manifest.webmanifest icons requirements.txt README.md run.sh tests; do
  if [[ -e "$TARGET/$item" ]]; then
    cp -a "$TARGET/$item" "$BACKUP/" 2>/dev/null || true
  fi
done

write_file() {
  local rel="$1"
  mkdir -p "$(dirname "$TARGET/$rel")"
  cat > "$TARGET/$rel"
}

write_file "server.py" <<'EOF_AMAR_d355af6697'
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import mimetypes
import os
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from mutagen import File as MutagenFile
from mutagen.flac import Picture
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

ROOT = Path(__file__).resolve().parent
HOME = Path.home()

AUDIO_EXTENSIONS = {
    ".mp3", ".flac", ".wav", ".ogg", ".opus", ".m4a", ".aac", ".wma"
}

library_lock = threading.RLock()
scan_lock = threading.Lock()

LIBRARY: list[dict[str, Any]] = []
FILE_INDEX: dict[str, Path] = {}
GENERATION = 0
LAST_SCAN_AT = 0.0
SCAN_ERROR: str | None = None

observer: Observer | None = None
rescan_timer: threading.Timer | None = None
timer_lock = threading.Lock()


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return default


def expand_path(value: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(value)))


def get_music_directories() -> list[Path]:
    candidates: list[Path] = []

    config = load_json(ROOT / "amarplayer-config.json", {})
    for directory in config.get("music_dirs", []):
        if isinstance(directory, str) and directory.strip():
            candidates.append(expand_path(directory.strip()))

    env_dirs = os.environ.get("AMARPLAYER_MUSIC_DIRS")
    if env_dirs:
        for directory in env_dirs.split(os.pathsep):
            if directory.strip():
                candidates.append(expand_path(directory.strip()))

    # Linux XDG music directory.
    xdg_config = HOME / ".config" / "user-dirs.dirs"
    if xdg_config.exists():
        try:
            for line in xdg_config.read_text(encoding="utf-8").splitlines():
                if line.startswith("XDG_MUSIC_DIR="):
                    value = line.split("=", 1)[1].strip().strip('"')
                    value = value.replace("$HOME", str(HOME))
                    candidates.append(Path(value))
        except OSError:
            pass

    candidates.extend([HOME / "Music", HOME / "Musik"])

    result: list[Path] = []
    seen: set[str] = set()
    for candidate in candidates:
        try:
            candidate = candidate.expanduser().resolve()
        except OSError:
            continue
        if not candidate.is_dir():
            continue
        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)
        result.append(candidate)
    return result


def first_tag(tags: Any, key: str, default: str = "") -> str:
    if not tags:
        return default
    try:
        value = tags.get(key)
    except Exception:
        return default
    if value is None:
        return default
    if isinstance(value, (list, tuple)):
        if not value:
            return default
        value = value[0]
    text = str(value).strip()
    return text or default


def safe_audio_metadata(path: Path) -> dict[str, Any]:
    title = path.stem.replace("_", " ").strip()
    artist = "Unknown Artist"
    album = "Unknown Album"
    genre = ""
    date = ""
    track_number = ""
    duration = 0.0
    bitrate = 0
    sample_rate = 0
    channels = 0

    try:
        audio = MutagenFile(path, easy=True)
        if audio is not None:
            tags = getattr(audio, "tags", None)
            title = first_tag(tags, "title", title)
            artist = first_tag(tags, "artist", artist)
            album = first_tag(tags, "album", album)
            genre = first_tag(tags, "genre", "")
            date = first_tag(tags, "date", "")
            track_number = first_tag(tags, "tracknumber", "")

            info = getattr(audio, "info", None)
            if info is not None:
                duration = float(getattr(info, "length", 0.0) or 0.0)
                bitrate = int(getattr(info, "bitrate", 0) or 0)
                sample_rate = int(getattr(info, "sample_rate", 0) or 0)
                channels = int(getattr(info, "channels", 0) or 0)
    except Exception:
        pass

    return {
        "title": title,
        "artist": artist,
        "album": album,
        "genre": genre,
        "date": date,
        "track_number": track_number,
        "duration": round(duration, 3),
        "bitrate": bitrate,
        "sample_rate": sample_rate,
        "channels": channels,
    }


def build_track(path: Path, base_directory: Path) -> dict[str, Any] | None:
    try:
        resolved = path.resolve()
        stat = resolved.stat()
    except OSError:
        return None

    file_id = hashlib.sha256(str(resolved).encode("utf-8")).hexdigest()[:24]
    metadata = safe_audio_metadata(resolved)

    try:
        relative = str(resolved.relative_to(base_directory))
    except ValueError:
        relative = resolved.name

    return {
        "id": file_id,
        "name": resolved.name,
        "relative_path": relative,
        "title": metadata["title"],
        "artist": metadata["artist"],
        "album": metadata["album"],
        "genre": metadata["genre"],
        "date": metadata["date"],
        "track_number": metadata["track_number"],
        "duration": metadata["duration"],
        "bitrate": metadata["bitrate"],
        "sample_rate": metadata["sample_rate"],
        "channels": metadata["channels"],
        "extension": resolved.suffix[1:].upper(),
        "size": stat.st_size,
        "modified": stat.st_mtime,
        "stream_url": f"/api/stream/{file_id}",
        "cover_url": f"/api/cover/{file_id}",
    }


def scan_library() -> None:
    global LIBRARY, FILE_INDEX, GENERATION, LAST_SCAN_AT, SCAN_ERROR

    if not scan_lock.acquire(blocking=False):
        return

    try:
        music_dirs = get_music_directories()
        tracks: list[dict[str, Any]] = []
        file_index: dict[str, Path] = {}
        error: str | None = None

        print("\n======================================")
        print(" amarPlayer Web — Automatic Scan")
        print("======================================")

        if not music_dirs:
            print("[amarPlayer] No configured music directory exists.")

        for base_directory in music_dirs:
            print("[SCAN]", base_directory)
            try:
                walker = os.walk(base_directory, followlinks=False)
                for root_dir, dirs, files in walker:
                    dirs[:] = [d for d in dirs if not d.startswith(".")]
                    for filename in files:
                        path = Path(root_dir) / filename
                        if path.suffix.lower() not in AUDIO_EXTENSIONS:
                            continue
                        track = build_track(path, base_directory)
                        if track is None:
                            continue
                        tracks.append(track)
                        file_index[track["id"]] = path.resolve()
            except OSError as exc:
                error = str(exc)
                print("[SCAN ERROR]", exc)

        tracks.sort(
            key=lambda item: (
                item["artist"].casefold(),
                item["album"].casefold(),
                item["title"].casefold(),
            )
        )

        with library_lock:
            LIBRARY = tracks
            FILE_INDEX = file_index
            GENERATION += 1
            LAST_SCAN_AT = time.time()
            SCAN_ERROR = error

        print(f"[amarPlayer] {len(tracks)} tracks, generation {GENERATION}\n")
    finally:
        scan_lock.release()


def request_rescan(delay: float = 0.8) -> None:
    global rescan_timer
    with timer_lock:
        if rescan_timer is not None:
            rescan_timer.cancel()
        rescan_timer = threading.Timer(delay, scan_library)
        rescan_timer.daemon = True
        rescan_timer.start()


class MusicEventHandler(FileSystemEventHandler):
    def on_any_event(self, event) -> None:
        source = Path(event.src_path)
        destination = getattr(event, "dest_path", None)

        relevant = event.is_directory or source.suffix.lower() in AUDIO_EXTENSIONS
        if destination:
            relevant = relevant or Path(destination).suffix.lower() in AUDIO_EXTENSIONS
        if relevant:
            request_rescan()


def find_folder_cover(path: Path) -> tuple[bytes, str] | None:
    names = (
        "cover.jpg", "cover.jpeg", "cover.png",
        "folder.jpg", "folder.jpeg", "folder.png",
        "front.jpg", "front.jpeg", "front.png",
    )
    candidates = [path.with_suffix(".jpg"), path.with_suffix(".png")]
    candidates.extend(path.parent / name for name in names)

    for candidate in candidates:
        try:
            if candidate.is_file():
                data = candidate.read_bytes()
                media_type = mimetypes.guess_type(candidate.name)[0] or "image/jpeg"
                return data, media_type
        except OSError:
            continue
    return None


def image_mime(data: bytes, fallback: str = "image/jpeg") -> str:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data[:4] in (b"GIF8",):
        return "image/gif"
    if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return "image/webp"
    return fallback


def embedded_cover(path: Path) -> tuple[bytes, str] | None:
    try:
        audio = MutagenFile(path, easy=False)
        if audio is None:
            return None

        # FLAC pictures.
        pictures = getattr(audio, "pictures", None)
        if pictures:
            pic = pictures[0]
            return bytes(pic.data), getattr(pic, "mime", None) or image_mime(bytes(pic.data))

        tags = getattr(audio, "tags", None)
        if tags is None:
            return None

        # ID3 APIC frames (MP3/WAV and compatible containers).
        try:
            for key in tags.keys():
                if str(key).startswith("APIC"):
                    frame = tags[key]
                    data = bytes(frame.data)
                    return data, getattr(frame, "mime", None) or image_mime(data)
        except Exception:
            pass

        # MP4/M4A cover list.
        try:
            covr = tags.get("covr")
            if covr:
                data = bytes(covr[0])
                return data, image_mime(data)
        except Exception:
            pass

        # Ogg/Vorbis metadata_block_picture.
        try:
            blocks = tags.get("metadata_block_picture", [])
            if blocks:
                raw = base64.b64decode(blocks[0])
                pic = Picture(raw)
                return bytes(pic.data), pic.mime or image_mime(bytes(pic.data))
        except Exception:
            pass

    except Exception:
        return None

    return None


def get_cover(path: Path) -> tuple[bytes, str] | None:
    return embedded_cover(path) or find_folder_cover(path)


def public_auth_config() -> dict[str, Any]:
    config = load_json(ROOT / "auth-config.json", {})
    enabled = bool(config.get("enabled"))
    if not enabled:
        return {"enabled": False}
    return {
        "enabled": True,
        "issuer": config.get("issuer", ""),
        "client_id": config.get("client_id", ""),
        "redirect_uri": config.get("redirect_uri", ""),
        "scope": config.get("scope", "openid profile email"),
        "authorization_endpoint": config.get("authorization_endpoint", ""),
    }


@asynccontextmanager
async def lifespan(app: FastAPI):
    global observer

    scan_library()

    music_dirs = get_music_directories()
    if music_dirs:
        handler = MusicEventHandler()
        observer = Observer()
        for directory in music_dirs:
            print("[WATCH]", directory)
            observer.schedule(handler, str(directory), recursive=True)
        observer.start()

    yield

    if observer is not None:
        observer.stop()
        observer.join(timeout=5)


app = FastAPI(
    title="amarPlayer Web Local Service",
    version="1.0.0",
    lifespan=lifespan,
)


@app.get("/api/health")
def health():
    with library_lock:
        return {
            "status": "ok",
            "version": "1.0.0",
            "tracks": len(LIBRARY),
            "generation": GENERATION,
            "last_scan_at": LAST_SCAN_AT,
            "scan_error": SCAN_ERROR,
            "scan_dirs": [str(p) for p in get_music_directories()],
        }


@app.get("/api/library")
def library():
    with library_lock:
        return {
            "count": len(LIBRARY),
            "generation": GENERATION,
            "last_scan_at": LAST_SCAN_AT,
            "scan_dirs": [str(p) for p in get_music_directories()],
            "tracks": list(LIBRARY),
        }


@app.post("/api/rescan")
def rescan():
    scan_library()
    with library_lock:
        return {"status": "ok", "count": len(LIBRARY), "generation": GENERATION}


@app.get("/api/events")
async def events(request: Request):
    async def event_stream():
        last_seen = -1
        while not await request.is_disconnected():
            with library_lock:
                generation = GENERATION
            if generation != last_seen:
                last_seen = generation
                yield f"event: library\ndata: {generation}\n\n"
            else:
                yield ": keepalive\n\n"
            await asyncio.sleep(1.5)

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


@app.get("/api/stream/{file_id}")
def stream_audio(file_id: str):
    with library_lock:
        path = FILE_INDEX.get(file_id)

    if path is None or not path.is_file():
        raise HTTPException(status_code=404, detail="Audio file not found")

    media_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    # Starlette FileResponse supports HTTP Range requests, which is important for seeking.
    return FileResponse(
        path,
        media_type=media_type,
        headers={
            "Cache-Control": "private, max-age=0, must-revalidate",
            "Content-Disposition": "inline",
        },
    )


@app.get("/api/cover/{file_id}")
def cover(file_id: str):
    with library_lock:
        path = FILE_INDEX.get(file_id)

    if path is None or not path.is_file():
        raise HTTPException(status_code=404, detail="Audio file not found")

    result = get_cover(path)
    if result is None:
        raise HTTPException(status_code=404, detail="Cover not found")

    data, media_type = result
    return Response(
        content=data,
        media_type=media_type,
        headers={"Cache-Control": "private, max-age=3600"},
    )


@app.get("/api/auth/config")
def auth_config():
    return public_auth_config()


app.mount("/css", StaticFiles(directory=ROOT / "css"), name="css")
app.mount("/js", StaticFiles(directory=ROOT / "js"), name="js")
app.mount("/icons", StaticFiles(directory=ROOT / "icons"), name="icons")


@app.get("/")
def index():
    return FileResponse(ROOT / "index.html", media_type="text/html")


@app.get("/manifest.webmanifest")
def manifest():
    return FileResponse(
        ROOT / "manifest.webmanifest",
        media_type="application/manifest+json",
    )


@app.get("/service-worker.js")
def service_worker():
    return FileResponse(
        ROOT / "service-worker.js",
        media_type="application/javascript",
        headers={"Cache-Control": "no-cache"},
    )


@app.exception_handler(404)
async def not_found_handler(request: Request, exc: HTTPException):
    # Keep API 404s as JSON; only the root frontend is intentionally served.
    if request.url.path.startswith("/api/"):
        return JSONResponse({"detail": exc.detail}, status_code=404)
    return JSONResponse({"detail": "Not found"}, status_code=404)
EOF_AMAR_d355af6697

write_file "index.html" <<'EOF_AMAR_eacf331f0f'
<!doctype html>
<html lang="id">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="theme-color" content="#121212">
  <meta name="description" content="amarPlayer Web — local-first music player">
  <title>amarPlayer Web</title>
  <link rel="manifest" href="/manifest.webmanifest">
  <link rel="icon" href="/icons/icon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/css/main.css">
</head>
<body>
<div class="app-shell">
  <aside class="sidebar">
    <div class="brand">
      <div class="logo">A</div>
      <div>
        <h1>amarPlayer</h1>
        <small>Web v1.0</small>
      </div>
    </div>

    <nav class="nav">
      <button class="nav-item active" data-view="library"><span>♫</span> Library <b id="songCount">0</b></button>
      <button class="nav-item" data-view="favorites"><span>♥</span> Favorites <b id="favoriteCount">0</b></button>
      <button class="nav-item" data-view="history"><span>↺</span> History</button>
    </nav>

    <div class="sidebar-section">
      <label for="searchInput">Search</label>
      <input id="searchInput" type="search" placeholder="Judul, artis, album…">
    </div>

    <div class="scanner-card">
      <div>
        <span id="scannerDot" class="status-dot"></span>
        <strong id="scannerStatus">Connecting…</strong>
      </div>
      <small id="scannerDetail">Local scanner</small>
      <button id="rescanBtn">Rescan Library</button>
    </div>

    <div class="account-card" id="accountCard" hidden>
      <span id="accountName">SSO</span>
      <button id="loginBtn">Sign in</button>
    </div>
  </aside>

  <main class="main">
    <header class="topbar">
      <div>
        <p class="eyebrow" id="viewEyebrow">LOCAL MUSIC</p>
        <h2 id="viewTitle">Library</h2>
      </div>
      <div class="topbar-actions">
        <select id="sortSelect" aria-label="Urutkan lagu">
          <option value="artist">Artist</option>
          <option value="title">Title</option>
          <option value="album">Album</option>
          <option value="recent">Recently modified</option>
        </select>
      </div>
    </header>

    <section class="hero">
      <div class="cover-shell">
        <img id="coverArt" alt="" hidden>
        <div id="coverFallback" class="cover-fallback">♪</div>
      </div>

      <div class="hero-info">
        <p class="eyebrow">NOW PLAYING</p>
        <h3 id="trackTitle">Belum ada lagu</h3>
        <p id="trackMeta">amarPlayer Web</p>
        <p id="trackTechnical" class="technical"></p>
        <button id="favoriteBtn" class="favorite-main" title="Favorite" disabled>♡ Favorite</button>
      </div>

      <canvas id="spectrum" width="900" height="220" aria-label="Audio spectrum"></canvas>
    </section>

    <section class="content-grid">
      <div class="library-panel">
        <div class="section-heading">
          <div>
            <h3 id="listTitle">Music Library</h3>
            <small id="listSubtitle">Automatic scanner</small>
          </div>
          <span id="resultCount">0 tracks</span>
        </div>
        <div id="trackList" class="track-list"></div>
      </div>

      <aside class="eq-panel">
        <div class="section-heading">
          <div>
            <h3>Equalizer</h3>
            <small>Web Audio API · 10 bands</small>
          </div>
          <button id="eqResetBtn" class="text-btn">Reset</button>
        </div>

        <label class="preset-label">
          Preset
          <select id="presetSelect">
            <option value="Flat">Flat</option>
            <option value="Bass">Bass</option>
            <option value="Rock">Rock</option>
            <option value="Pop">Pop</option>
            <option value="Vocal">Vocal</option>
            <option value="Treble">Treble</option>
            <option value="Custom">Custom</option>
          </select>
        </label>

        <div id="eqBands" class="eq-bands"></div>
      </aside>
    </section>
  </main>

  <footer class="playerbar">
    <div class="mini-track">
      <div class="mini-cover"><img id="miniCover" alt="" hidden><span id="miniCoverFallback">♪</span></div>
      <div>
        <strong id="footerTitle">amarPlayer</strong>
        <small id="footerArtist">Web Player</small>
      </div>
    </div>

    <div class="transport">
      <div class="transport-buttons">
        <button id="shuffleBtn" title="Shuffle">⇄</button>
        <button id="prevBtn" title="Previous">⏮</button>
        <button id="playBtn" class="play-btn" title="Play">▶</button>
        <button id="nextBtn" title="Next">⏭</button>
        <button id="repeatBtn" title="Repeat">↻</button>
      </div>
      <div class="timeline">
        <span id="currentTime">0:00</span>
        <input id="progress" type="range" min="0" max="1000" value="0">
        <span id="duration">0:00</span>
      </div>
    </div>

    <div class="volume">
      <span>🔊</span>
      <input id="volume" type="range" min="0" max="1" step="0.01" value="0.8" aria-label="Volume">
    </div>
  </footer>
</div>

<audio id="audio" preload="metadata"></audio>
<div id="toast" class="toast" role="status" aria-live="polite"></div>

<script type="module" src="/js/app.js"></script>
</body>
</html>
EOF_AMAR_eacf331f0f

write_file "css/main.css" <<'EOF_AMAR_23b024677d'
:root {
  color-scheme: dark;
  --bg: #0b0b0c;
  --panel: #151517;
  --panel-2: #1d1d20;
  --border: #2b2b2f;
  --text: #f4f4f5;
  --muted: #9b9ba1;
  --soft: #73737a;
  --accent: #ffffff;
  --danger: #ff7474;
}

* { box-sizing: border-box; }
html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text); font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
body { overflow: hidden; }
button, input, select { font: inherit; }
button { cursor: pointer; }
button:disabled { cursor: not-allowed; opacity: .45; }
input, select { color: var(--text); background: #111113; border: 1px solid var(--border); outline: none; }
input:focus, select:focus { border-color: #5e5e66; }

.app-shell {
  display: grid;
  grid-template-columns: 235px minmax(0, 1fr);
  grid-template-rows: minmax(0, 1fr) 96px;
  height: 100vh;
}

.sidebar {
  grid-row: 1;
  display: flex;
  flex-direction: column;
  gap: 20px;
  padding: 22px 16px;
  border-right: 1px solid var(--border);
  background: #101012;
  overflow-y: auto;
}

.brand { display: flex; align-items: center; gap: 11px; padding: 0 6px 8px; }
.logo { width: 42px; height: 42px; border-radius: 12px; display: grid; place-items: center; background: var(--accent); color: #111; font-weight: 900; font-size: 23px; }
.brand h1 { font-size: 18px; margin: 0; }
.brand small { color: var(--muted); }

.nav { display: grid; gap: 4px; }
.nav-item {
  display: grid;
  grid-template-columns: 24px 1fr auto;
  gap: 8px;
  align-items: center;
  text-align: left;
  padding: 10px 11px;
  border: 0;
  border-radius: 9px;
  color: #c4c4c8;
  background: transparent;
}
.nav-item:hover, .nav-item.active { background: #202024; color: white; }
.nav-item b { font-size: 11px; padding: 2px 6px; border-radius: 99px; background: #2e2e33; }

.sidebar-section { display: grid; gap: 7px; }
.sidebar-section label, .preset-label { color: var(--muted); font-size: 12px; }
#searchInput { width: 100%; padding: 9px 10px; border-radius: 8px; }

.scanner-card, .account-card {
  margin-top: auto;
  padding: 12px;
  border: 1px solid var(--border);
  border-radius: 12px;
  background: #151517;
}
.scanner-card > div { display: flex; align-items: center; gap: 7px; font-size: 12px; }
.scanner-card small { display: block; color: var(--soft); margin: 6px 0 10px; overflow: hidden; text-overflow: ellipsis; }
.scanner-card button, .account-card button {
  width: 100%;
  border: 1px solid var(--border);
  border-radius: 8px;
  color: var(--text);
  background: #202024;
  padding: 8px;
}
.status-dot { width: 8px; height: 8px; border-radius: 50%; background: #a7823c; box-shadow: 0 0 0 4px rgba(167,130,60,.12); }
.status-dot.online { background: #66c28a; box-shadow: 0 0 0 4px rgba(102,194,138,.12); }
.status-dot.offline { background: var(--danger); box-shadow: 0 0 0 4px rgba(255,116,116,.12); }

.main {
  min-width: 0;
  overflow-y: auto;
  padding: 26px 30px 40px;
  background:
    radial-gradient(circle at 20% -10%, rgba(255,255,255,.09), transparent 34%),
    var(--bg);
}

.topbar { display: flex; justify-content: space-between; align-items: end; margin-bottom: 18px; }
.eyebrow { margin: 0 0 4px; font-size: 10px; letter-spacing: .16em; font-weight: 800; color: var(--muted); }
.topbar h2 { margin: 0; font-size: 27px; }
.topbar select { border-radius: 8px; padding: 8px 10px; }

.hero {
  display: grid;
  grid-template-columns: 178px minmax(220px, .8fr) minmax(280px, 1.25fr);
  gap: 24px;
  align-items: center;
  min-height: 210px;
  padding: 18px;
  border: 1px solid var(--border);
  border-radius: 16px;
  background: linear-gradient(140deg, #1c1c20, #111113);
  box-shadow: 0 18px 50px rgba(0,0,0,.2);
}

.cover-shell {
  width: 178px; height: 178px; overflow: hidden; border-radius: 14px; background: #26262a;
  box-shadow: 0 18px 40px rgba(0,0,0,.35);
}
.cover-shell img { width: 100%; height: 100%; object-fit: cover; display: block; }
.cover-fallback { width: 100%; height: 100%; display: grid; place-items: center; font-size: 65px; color: #777780; background: linear-gradient(145deg, #303036, #19191c); }

.hero-info { min-width: 0; }
.hero-info h3 { font-size: clamp(22px, 2.3vw, 38px); line-height: 1.05; margin: 0 0 10px; overflow-wrap: anywhere; }
.hero-info > p:not(.eyebrow) { margin: 0 0 6px; color: #c2c2c7; }
.technical { font-size: 11px; color: var(--soft) !important; }
.favorite-main { margin-top: 12px; padding: 8px 11px; border-radius: 8px; border: 1px solid var(--border); background: #222226; color: var(--text); }
.favorite-main.active { background: white; color: #111; }

#spectrum { width: 100%; height: 160px; display: block; border-radius: 10px; background: #101012; }

.content-grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 300px;
  gap: 18px;
  margin-top: 18px;
}
.library-panel, .eq-panel { border: 1px solid var(--border); border-radius: 14px; background: var(--panel); overflow: hidden; }
.library-panel { min-height: 420px; }
.eq-panel { padding: 16px; align-self: start; position: sticky; top: 0; }

.section-heading { display: flex; justify-content: space-between; align-items: center; gap: 10px; padding: 16px; border-bottom: 1px solid var(--border); }
.eq-panel .section-heading { padding: 0 0 13px; }
.section-heading h3 { margin: 0; font-size: 15px; }
.section-heading small, .section-heading > span { color: var(--muted); font-size: 11px; }
.text-btn { border: 0; background: transparent; color: var(--muted); padding: 4px; }
.text-btn:hover { color: white; }

.track-list { display: grid; }
.track-row {
  display: grid;
  grid-template-columns: 34px minmax(0, 1.4fr) minmax(0, .8fr) 70px 34px;
  gap: 10px;
  align-items: center;
  min-height: 58px;
  padding: 8px 14px;
  border-bottom: 1px solid rgba(255,255,255,.045);
  cursor: pointer;
}
.track-row:hover { background: #202024; }
.track-row.active { background: #28282d; }
.track-index { text-align: center; color: var(--soft); font-size: 12px; }
.track-primary, .track-album { min-width: 0; }
.track-primary strong, .track-primary small, .track-album { display: block; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.track-primary strong { font-size: 13px; }
.track-primary small, .track-album { margin-top: 3px; color: var(--muted); font-size: 11px; }
.track-duration { color: var(--muted); font-size: 11px; text-align: right; }
.heart-btn { border: 0; background: transparent; color: #77777f; font-size: 18px; }
.heart-btn.active { color: white; }
.empty { padding: 70px 25px; text-align: center; color: var(--soft); }

.preset-label { display: grid; gap: 6px; margin: 14px 0; }
.preset-label select { width: 100%; padding: 8px; border-radius: 8px; }
.eq-bands { display: grid; grid-template-columns: repeat(10, 1fr); gap: 4px; min-height: 240px; }
.eq-band { display: grid; grid-template-rows: 1fr auto auto; place-items: center; gap: 5px; min-width: 0; }
.eq-band input[type="range"] { writing-mode: vertical-lr; direction: rtl; appearance: slider-vertical; width: 28px; height: 170px; accent-color: white; }
.eq-band b { font-size: 9px; color: #b5b5ba; }
.eq-band span { font-size: 8px; color: var(--soft); }

.playerbar {
  grid-column: 1 / -1;
  display: grid;
  grid-template-columns: minmax(170px, 1fr) minmax(360px, 2.2fr) minmax(160px, 1fr);
  align-items: center;
  gap: 20px;
  padding: 11px 20px;
  border-top: 1px solid var(--border);
  background: #111113;
  z-index: 20;
}
.mini-track { display: grid; grid-template-columns: 48px minmax(0, 1fr); gap: 10px; align-items: center; min-width: 0; }
.mini-track > div:last-child { min-width: 0; }
.mini-track strong, .mini-track small { display: block; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.mini-track strong { font-size: 12px; }
.mini-track small { color: var(--muted); margin-top: 3px; font-size: 10px; }
.mini-cover { width: 48px; height: 48px; border-radius: 8px; overflow: hidden; background: #29292d; display: grid; place-items: center; color: var(--soft); }
.mini-cover img { width: 100%; height: 100%; object-fit: cover; }
.transport { min-width: 0; }
.transport-buttons { display: flex; justify-content: center; gap: 12px; align-items: center; }
.transport-buttons button { border: 0; background: transparent; color: #b7b7bc; font-size: 15px; min-width: 30px; }
.transport-buttons button.active { color: white; font-weight: 800; }
.transport-buttons .play-btn { width: 38px; height: 38px; border-radius: 50%; background: white; color: #111; font-size: 16px; }
.timeline { display: grid; grid-template-columns: 38px 1fr 38px; gap: 7px; align-items: center; margin-top: 4px; color: var(--muted); font-size: 9px; }
input[type="range"] { accent-color: white; width: 100%; }
.volume { display: flex; justify-content: flex-end; align-items: center; gap: 8px; }
.volume input { max-width: 130px; }

.toast {
  position: fixed;
  left: 50%;
  bottom: 112px;
  transform: translateX(-50%) translateY(20px);
  background: white;
  color: #111;
  padding: 9px 14px;
  border-radius: 8px;
  font-size: 12px;
  opacity: 0;
  pointer-events: none;
  transition: .2s ease;
  z-index: 99;
}
.toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }

@media (max-width: 1100px) {
  .hero { grid-template-columns: 150px 1fr; }
  .cover-shell { width: 150px; height: 150px; }
  #spectrum { grid-column: 1 / -1; height: 110px; }
  .content-grid { grid-template-columns: 1fr; }
  .eq-panel { position: static; }
}
@media (max-width: 780px) {
  body { overflow: auto; }
  .app-shell { display: block; height: auto; min-height: 100vh; padding-bottom: 112px; }
  .sidebar { border-right: 0; border-bottom: 1px solid var(--border); padding: 12px; gap: 10px; }
  .brand { padding: 0; }
  .nav { grid-template-columns: repeat(3, 1fr); }
  .nav-item { grid-template-columns: auto 1fr; font-size: 11px; }
  .nav-item b { display: none; }
  .scanner-card { margin-top: 0; }
  .main { padding: 16px 12px 24px; overflow: visible; }
  .hero { grid-template-columns: 100px 1fr; gap: 14px; min-height: 0; padding: 12px; }
  .cover-shell { width: 100px; height: 100px; }
  .cover-fallback { font-size: 40px; }
  .hero-info h3 { font-size: 20px; }
  .technical { display: none; }
  #spectrum { grid-column: 1 / -1; height: 90px; }
  .track-row { grid-template-columns: 28px minmax(0, 1fr) 52px 30px; }
  .track-album { display: none; }
  .eq-bands { overflow-x: auto; min-width: 650px; }
  .eq-panel { overflow-x: auto; }
  .playerbar { position: fixed; left: 0; right: 0; bottom: 0; grid-template-columns: 110px 1fr; padding: 8px 10px; }
  .mini-cover { display: none; }
  .mini-track { grid-template-columns: 1fr; }
  .volume { display: none; }
  .timeline { grid-template-columns: 32px 1fr 32px; }
}
EOF_AMAR_23b024677d

write_file "js/db.js" <<'EOF_AMAR_7fdfefdc5b'
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
EOF_AMAR_7fdfefdc5b

write_file "js/audio-engine.js" <<'EOF_AMAR_51f9e4525b'
export const FREQUENCIES = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

export const PRESETS = {
  Flat:   [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  Bass:   [6, 5, 4, 2, 1, 0, -1, -1, -1, -1],
  Rock:   [4, 3, 1, -1, -2, 1, 3, 4, 4, 3],
  Pop:    [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2],
  Vocal:  [-3, -2, -1, 1, 3, 5, 5, 3, 1, -1],
  Treble: [-2, -2, -1, 0, 1, 2, 4, 5, 6, 6],
};

export class AudioEngine {
  constructor(audio) {
    this.audio = audio;
    this.context = null;
    this.source = null;
    this.filters = [];
    this.analyser = null;
    this.values = [...PRESETS.Flat];
  }

  async init() {
    if (this.context) {
      if (this.context.state === "suspended") await this.context.resume();
      return;
    }

    const AudioContext = window.AudioContext || window.webkitAudioContext;
    if (!AudioContext) throw new Error("Web Audio API tidak didukung browser ini.");

    this.context = new AudioContext();
    this.source = this.context.createMediaElementSource(this.audio);

    this.filters = FREQUENCIES.map((frequency, index) => {
      const filter = this.context.createBiquadFilter();
      filter.type = "peaking";
      filter.frequency.value = frequency;
      filter.Q.value = 1.15;
      filter.gain.value = this.values[index];
      return filter;
    });

    this.analyser = this.context.createAnalyser();
    this.analyser.fftSize = 256;
    this.analyser.smoothingTimeConstant = 0.82;

    let node = this.source;
    for (const filter of this.filters) {
      node.connect(filter);
      node = filter;
    }
    node.connect(this.analyser);
    this.analyser.connect(this.context.destination);

    await this.context.resume();
  }

  async resume() {
    await this.init();
    if (this.context.state === "suspended") await this.context.resume();
  }

  async setBand(index, gain) {
    this.values[index] = Number(gain);
    await this.init();
    this.filters[index].gain.setTargetAtTime(Number(gain), this.context.currentTime, 0.01);
  }

  async applyValues(values) {
    this.values = values.map(Number);
    await this.init();
    this.values.forEach((gain, index) => {
      this.filters[index].gain.setTargetAtTime(gain, this.context.currentTime, 0.01);
    });
  }

  frequencyData() {
    if (!this.analyser) return null;
    const data = new Uint8Array(this.analyser.frequencyBinCount);
    this.analyser.getByteFrequencyData(data);
    return data;
  }
}
EOF_AMAR_51f9e4525b

write_file "js/oidc.js" <<'EOF_AMAR_b26bb36045'
function base64Url(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function sha256(text) {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
}

function randomVerifier() {
  const bytes = new Uint8Array(48);
  crypto.getRandomValues(bytes);
  return base64Url(bytes);
}

export async function loadAuthConfig() {
  try {
    const response = await fetch("/api/auth/config", { cache: "no-store" });
    if (!response.ok) return { enabled: false };
    return response.json();
  } catch {
    return { enabled: false };
  }
}

export async function startLogin(config) {
  if (!config?.enabled || !config.authorization_endpoint) return;

  const verifier = randomVerifier();
  const challenge = base64Url(await sha256(verifier));
  const state = crypto.randomUUID();

  sessionStorage.setItem("amar_oidc_verifier", verifier);
  sessionStorage.setItem("amar_oidc_state", state);

  const url = new URL(config.authorization_endpoint);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", config.client_id);
  url.searchParams.set("redirect_uri", config.redirect_uri || location.origin + "/");
  url.searchParams.set("scope", config.scope || "openid profile email");
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");

  location.assign(url.toString());
}

/*
 * amarSSO is intentionally not emulated locally.
 * This module prepares Authorization Code + PKCE initiation.
 * Token exchange will be wired when amarSSO's OIDC endpoints are created.
 */
EOF_AMAR_b26bb36045

write_file "js/app.js" <<'EOF_AMAR_41d794d24f'
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
EOF_AMAR_41d794d24f

write_file "service-worker.js" <<'EOF_AMAR_01a188ba38'
const CACHE = "amarplayer-web-v1.0.0";
const SHELL = [
  "/",
  "/index.html",
  "/css/main.css",
  "/js/app.js",
  "/js/db.js",
  "/js/audio-engine.js",
  "/js/oidc.js",
  "/manifest.webmanifest",
  "/icons/icon.svg",
];

self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(key => key !== CACHE).map(key => caches.delete(key)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", event => {
  const url = new URL(event.request.url);

  // Never cache local API, audio streams, covers, or SSE.
  if (
    event.request.method !== "GET" ||
    url.pathname.startsWith("/api/")
  ) {
    return;
  }

  event.respondWith(
    caches.match(event.request).then(cached => {
      const network = fetch(event.request)
        .then(response => {
          if (response.ok && response.type === "basic") {
            const copy = response.clone();
            caches.open(CACHE).then(cache => cache.put(event.request, copy));
          }
          return response;
        })
        .catch(() => cached);

      return cached || network;
    })
  );
});
EOF_AMAR_01a188ba38

write_file "manifest.webmanifest" <<'EOF_AMAR_7eccd05450'
{
  "name": "amarPlayer Web",
  "short_name": "amarPlayer",
  "description": "Local-first music player with automatic scanner and 10-band equalizer",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "background_color": "#0b0b0c",
  "theme_color": "#121212",
  "icons": [
    {
      "src": "/icons/icon.svg",
      "sizes": "any",
      "type": "image/svg+xml",
      "purpose": "any"
    }
  ]
}
EOF_AMAR_7eccd05450

write_file "icons/icon.svg" <<'EOF_AMAR_6b876e1484'
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <rect width="512" height="512" rx="112" fill="#121212"/>
  <circle cx="256" cy="256" r="170" fill="#f5f5f5"/>
  <path d="M165 358 236 145h40l72 213h-45l-16-53h-67l-16 53h-39Zm66-91h45l-22-77-23 77Z" fill="#121212"/>
</svg>
EOF_AMAR_6b876e1484

write_file "requirements.txt" <<'EOF_AMAR_b4ef698db8'
fastapi>=0.118,<1.0
uvicorn[standard]>=0.35,<1.0
watchdog>=6,<7
mutagen>=1.47,<2
EOF_AMAR_b4ef698db8

write_file "amarplayer-config.example.json" <<'EOF_AMAR_ac42f87017'
{
  "music_dirs": [
    "~/Music",
    "~/Musik"
  ]
}
EOF_AMAR_ac42f87017

write_file "auth-config.example.json" <<'EOF_AMAR_dcfdfd0e5e'
{
  "enabled": false,
  "issuer": "https://auth.example.com",
  "client_id": "amarplayer-web",
  "redirect_uri": "http://localhost:8080/",
  "scope": "openid profile email",
  "authorization_endpoint": "https://auth.example.com/oauth/authorize"
}
EOF_AMAR_dcfdfd0e5e

write_file ".gitignore" <<'EOF_AMAR_a084b794bc'
.venv/
venv/
__pycache__/
*.py[cod]
*.log
.cache/
amarplayer-config.json
auth-config.json
*.backup*
*.bak
*~
.vscode/
.idea/
.DS_Store
Thumbs.db
EOF_AMAR_a084b794bc

write_file "run.sh" <<'EOF_AMAR_1b0c2b516b'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi

source .venv/bin/activate

if ! python - <<'PY' >/dev/null 2>&1
import fastapi
import uvicorn
import watchdog
import mutagen
PY
then
  python -m pip install -r requirements.txt
fi

if [[ ! -f amarplayer-config.json ]]; then
  cp amarplayer-config.example.json amarplayer-config.json
fi

exec uvicorn server:app --host 127.0.0.1 --port 8080
EOF_AMAR_1b0c2b516b

write_file "README.md" <<'EOF_AMAR_04c6e90faa'
# amarPlayer Web

**amarPlayer Web v1.0** adalah versi web/local-first dari amarPlayer dengan automatic music scanner, metadata library, cover art, history, favorites, persistent queue, Web Audio API 10-band equalizer, spectrum analyzer, Media Session API, dan PWA shell.

## Status fitur

### Core player
- [x] Automatic recursive music scan
- [x] Realtime filesystem watcher
- [x] MP3 / FLAC / WAV / OGG / OPUS / M4A / AAC / WMA discovery
- [x] Play / pause / previous / next
- [x] Seek dengan HTTP Range
- [x] Volume
- [x] Shuffle
- [x] Repeat all / repeat one
- [x] Search
- [x] Sort artist / title / album / recently modified

### Metadata
- [x] Title
- [x] Artist
- [x] Album
- [x] Genre
- [x] Track number
- [x] Duration
- [x] Bitrate
- [x] Sample rate
- [x] Channels
- [x] Embedded cover art
- [x] Folder cover fallback

### Local persistence
- [x] IndexedDB track cache
- [x] Favorites
- [x] Playback history
- [x] Persistent queue/order
- [x] Volume setting
- [x] Shuffle/repeat settings
- [x] Equalizer settings

### Audio
- [x] Web Audio API
- [x] 10-band parametric equalizer
- [x] Flat / Bass / Rock / Pop / Vocal / Treble presets
- [x] Custom EQ
- [x] Spectrum analyzer

### Browser integration
- [x] Media Session metadata
- [x] Lock-screen/media controls where supported
- [x] Service Worker
- [x] PWA manifest
- [x] Offline application shell

### SSO
- [x] OIDC/PKCE initiation adapter prepared
- [ ] amarSSO identity server

`amarSSO identity server` sengaja tetap proyek terpisah. amarPlayer tidak membuat autentikasi palsu untuk menandai SSO sebagai selesai.

## Arsitektur

```text
Music folders
     │
     ▼
FastAPI local service
     ├── Mutagen metadata + artwork
     ├── Watchdog filesystem events
     ├── HTTP Range audio streaming
     └── SSE library updates
              │
              ▼
       amarPlayer Web
     ├── IndexedDB
     ├── Web Audio API
     ├── Media Session
     ├── PWA shell
     └── OIDC/PKCE adapter
```

## Instalasi Fedora/Linux

```bash
git clone https://github.com/xmuammar/amarPlayer-Web.git
cd amarPlayer-Web

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

cp amarplayer-config.example.json amarplayer-config.json
./run.sh
```

Buka:

```text
http://localhost:8080
```

## Konfigurasi scanner

`amarplayer-config.json`:

```json
{
  "music_dirs": [
    "~/Music",
    "~/Musik"
  ]
}
```

Tambahkan folder lain bila perlu. File konfigurasi lokal ini diabaikan Git.

## SSO-ready

`auth-config.example.json` menunjukkan konfigurasi OIDC public client. Jangan membuat `client_secret` di frontend. amarPlayer menyiapkan Authorization Code + PKCE initiation; token exchange akan diselesaikan ketika `amarSSO` identity server dibangun.

## Keamanan

Local service bind ke `127.0.0.1` secara default karena mempunyai akses baca ke library musik komputer. Jangan mengganti ke `0.0.0.0` dan mengeksposnya ke jaringan publik tanpa authentication, authorization, TLS, dan pembatasan akses yang sesuai.

## Developer

**Muammar, SST, M.Kom**  
Programmer / Software Engineer
EOF_AMAR_04c6e90faa

write_file "tests/test_smoke.py" <<'EOF_AMAR_5ddec22bf3'
from pathlib import Path
import importlib.util

def test_project_files_exist():
    root = Path(__file__).resolve().parents[1]
    for name in [
        "server.py", "index.html", "service-worker.js",
        "js/app.js", "js/db.js", "js/audio-engine.js",
        "css/main.css", "manifest.webmanifest"
    ]:
        assert (root / name).exists(), name

def test_server_imports():
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("amar_server", root / "server.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.app.title.startswith("amarPlayer")
EOF_AMAR_5ddec22bf3

chmod +x "$TARGET/run.sh"

cd "$TARGET"

if [[ ! -f amarplayer-config.json ]]; then
  cp amarplayer-config.example.json amarplayer-config.json
fi

python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt

python -m py_compile server.py

echo
echo "Upgrade selesai."
echo "Backup versi lama: $BACKUP"
echo
echo "Jalankan:"
echo "  cd \"$TARGET\""
echo "  ./run.sh"
echo
echo "Lalu buka http://localhost:8080"
