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
