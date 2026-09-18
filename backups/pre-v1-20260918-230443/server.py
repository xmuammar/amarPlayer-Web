from pathlib import Path
from contextlib import asynccontextmanager
import hashlib
import json
import mimetypes
import os
import threading

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer


ROOT = Path(__file__).resolve().parent
HOME = Path.home()

AUDIO_EXTENSIONS = {
    ".mp3",
    ".flac",
    ".wav",
    ".ogg",
    ".opus",
    ".m4a",
    ".aac",
    ".wma",
}


library_lock = threading.Lock()

LIBRARY = []
FILE_INDEX = {}

observer = None
rescan_timer = None
timer_lock = threading.Lock()


# =========================================================
# MUSIC DIRECTORIES
# =========================================================

def get_music_directories():

    candidates = []


    # ---------------------------------
    # Config amarPlayer
    # ---------------------------------

    config_file = ROOT / "amarplayer-config.json"

    if config_file.exists():

        try:

            data = json.loads(
                config_file.read_text(
                    encoding="utf-8"
                )
            )

            for directory in data.get(
                "music_dirs",
                []
            ):

                candidates.append(
                    Path(
                        os.path.expandvars(
                            os.path.expanduser(
                                directory
                            )
                        )
                    )
                )

        except Exception as error:

            print(
                "[amarPlayer] Config error:",
                error
            )


    # ---------------------------------
    # Environment variable
    # ---------------------------------

    env_dirs = os.environ.get(
        "AMARPLAYER_MUSIC_DIRS"
    )

    if env_dirs:

        for directory in env_dirs.split(
            os.pathsep
        ):

            if directory.strip():

                candidates.append(
                    Path(
                        os.path.expanduser(
                            directory.strip()
                        )
                    )
                )


    # ---------------------------------
    # XDG Music directory Fedora/Linux
    # ---------------------------------

    xdg_config = (
        HOME /
        ".config" /
        "user-dirs.dirs"
    )

    if xdg_config.exists():

        try:

            for line in xdg_config.read_text(
                encoding="utf-8"
            ).splitlines():

                if line.startswith(
                    "XDG_MUSIC_DIR="
                ):

                    value = (
                        line
                        .split("=", 1)[1]
                        .strip()
                        .strip('"')
                    )

                    value = value.replace(
                        "$HOME",
                        str(HOME)
                    )

                    candidates.append(
                        Path(value)
                    )

        except Exception:

            pass


    # ---------------------------------
    # Fallback
    # ---------------------------------

    candidates.extend(
        [
            HOME / "Music",
            HOME / "Musik",
        ]
    )


    # ---------------------------------
    # Hapus duplikat
    # ---------------------------------

    directories = []

    seen = set()

    for directory in candidates:

        try:

            directory = (
                directory
                .expanduser()
                .resolve()
            )

        except Exception:

            continue


        if not directory.is_dir():

            continue


        key = str(directory)

        if key in seen:

            continue

        seen.add(key)

        directories.append(
            directory
        )


    return directories


# =========================================================
# SCANNER
# =========================================================

def scan_library():

    global LIBRARY
    global FILE_INDEX

    music_dirs = (
        get_music_directories()
    )

    tracks = []

    file_index = {}


    print()
    print(
        "======================================"
    )
    print(
        " amarPlayer Automatic Library Scan"
    )
    print(
        "======================================"
    )


    if not music_dirs:

        print(
            "[amarPlayer] Tidak ada folder musik."
        )


    for base_directory in music_dirs:

        print(
            "[SCAN]",
            base_directory
        )


        for root, dirs, files in os.walk(
            base_directory,
            followlinks=False
        ):

            # Jangan scan hidden directories
            dirs[:] = [
                directory
                for directory in dirs
                if not directory.startswith(".")
            ]


            for filename in files:

                path = (
                    Path(root) /
                    filename
                )


                if (
                    path.suffix.lower()
                    not in AUDIO_EXTENSIONS
                ):

                    continue


                try:

                    stat = path.stat()

                except OSError:

                    continue


                file_id = hashlib.sha256(
                    str(
                        path.resolve()
                    ).encode(
                        "utf-8"
                    )
                ).hexdigest()[:24]


                file_index[file_id] = path


                artist = "Local Music"

                if (
                    path.parent !=
                    base_directory
                ):

                    artist = (
                        path.parent.name
                        or "Local Music"
                    )


                tracks.append(
                    {
                        "id": file_id,

                        "title": (
                            path.stem
                            .replace("_", " ")
                        ),

                        "name":
                            path.name,

                        "artist":
                            artist,

                        "extension":
                            path.suffix[
                                1:
                            ].upper(),

                        "size":
                            stat.st_size,

                        "modified":
                            stat.st_mtime,

                        "url":
                            f"/api/stream/{file_id}"
                    }
                )


    tracks.sort(
        key=lambda item:
            item[
                "title"
            ].lower()
    )


    with library_lock:

        LIBRARY = tracks
        FILE_INDEX = file_index


    print()
    print(
        f"[amarPlayer] "
        f"{len(tracks)} lagu ditemukan"
    )
    print()


# =========================================================
# REALTIME WATCHER
# =========================================================

def delayed_scan():

    global rescan_timer

    scan_library()

    with timer_lock:

        rescan_timer = None


def request_rescan():

    global rescan_timer

    with timer_lock:

        if rescan_timer is not None:

            rescan_timer.cancel()


        rescan_timer = threading.Timer(
            1.0,
            delayed_scan
        )

        rescan_timer.daemon = True

        rescan_timer.start()


class MusicEventHandler(
    FileSystemEventHandler
):

    def on_any_event(
        self,
        event
    ):

        source = Path(
            event.src_path
        )

        destination = getattr(
            event,
            "dest_path",
            None
        )


        relevant = (
            event.is_directory
            or
            source.suffix.lower()
            in AUDIO_EXTENSIONS
        )


        if destination:

            relevant = (
                relevant
                or
                Path(
                    destination
                ).suffix.lower()
                in AUDIO_EXTENSIONS
            )


        if relevant:

            request_rescan()


# =========================================================
# START / STOP
# =========================================================

@asynccontextmanager
async def lifespan(app):

    global observer

    scan_library()

    music_dirs = (
        get_music_directories()
    )


    observer = Observer()

    handler = (
        MusicEventHandler()
    )


    for directory in music_dirs:

        print(
            "[WATCH]",
            directory
        )

        observer.schedule(
            handler,
            str(directory),
            recursive=True
        )


    if music_dirs:

        observer.start()


    yield


    if observer:

        observer.stop()

        observer.join()


app = FastAPI(
    title="amarPlayer Local Service",
    lifespan=lifespan
)


# =========================================================
# API
# =========================================================

@app.get(
    "/api/library"
)
def library():

    with library_lock:

        tracks = list(
            LIBRARY
        )


    return {
        "count":
            len(tracks),

        "scan_dirs":
            [
                str(directory)
                for directory
                in get_music_directories()
            ],

        "tracks":
            tracks
    }


@app.post(
    "/api/rescan"
)
def rescan():

    scan_library()

    return {
        "status":
            "ok",

        "count":
            len(LIBRARY)
    }


@app.get(
    "/api/stream/{file_id}"
)
def stream_audio(
    file_id: str
):

    with library_lock:

        path = FILE_INDEX.get(
            file_id
        )


    if (
        path is None
        or
        not path.exists()
    ):

        raise HTTPException(
            status_code=404,
            detail="File tidak ditemukan"
        )


    media_type = (
        mimetypes.guess_type(
            path.name
        )[0]
        or
        "application/octet-stream"
    )


    return FileResponse(
        path,
        media_type=media_type,
        filename=path.name
    )


# =========================================================
# FRONTEND
# =========================================================

app.mount(
    "/css",
    StaticFiles(
        directory=ROOT / "css"
    ),
    name="css"
)

app.mount(
    "/js",
    StaticFiles(
        directory=ROOT / "js"
    ),
    name="js"
)

app.mount(
    "/icons",
    StaticFiles(
        directory=ROOT / "icons"
    ),
    name="icons"
)


@app.get("/")
def index():

    return FileResponse(
        ROOT /
        "index.html"
    )


@app.get(
    "/manifest.webmanifest"
)
def manifest():

    return FileResponse(
        ROOT /
        "manifest.webmanifest",
        media_type=(
            "application/"
            "manifest+json"
        )
    )


@app.get(
    "/service-worker.js"
)
def service_worker():

    return FileResponse(
        ROOT /
        "service-worker.js",
        media_type=(
            "application/javascript"
        )
    )
