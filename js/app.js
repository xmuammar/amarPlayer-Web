const audio = document.getElementById("audio");

const fileInput =
    document.getElementById("fileInput");

const folderInput =
    document.getElementById("folderInput");

const openFilesBtn =
    document.getElementById("openFilesBtn");

const openFolderBtn =
    document.getElementById("openFolderBtn");

const playlistElement =
    document.getElementById("playlist");

const playBtn =
    document.getElementById("playBtn");

const nextBtn =
    document.getElementById("nextBtn");

const prevBtn =
    document.getElementById("prevBtn");

const progress =
    document.getElementById("progress");

const volume =
    document.getElementById("volume");

const currentTimeElement =
    document.getElementById("currentTime");

const durationElement =
    document.getElementById("duration");

const titleElement =
    document.getElementById("trackTitle");

const artistElement =
    document.getElementById("trackArtist");

const footerTitle =
    document.getElementById("footerTitle");

const footerArtist =
    document.getElementById("footerArtist");

const songCount =
    document.getElementById("songCount");

const searchInput =
    document.getElementById("searchInput");

const clearPlaylist =
    document.getElementById("clearPlaylist");


let playlist = [];

let currentIndex = -1;



function cleanTitle(filename) {

    return filename
        .replace(/\.[^/.]+$/, "")
        .replace(/_/g, " ")
        .trim();

}



function formatTime(seconds) {

    if (
        Number.isNaN(seconds) ||
        !Number.isFinite(seconds)
    ) {
        return "0:00";
    }

    const minutes =
        Math.floor(seconds / 60);

    const secs =
        Math.floor(seconds % 60)
            .toString()
            .padStart(2, "0");

    return `${minutes}:${secs}`;

}



function isAudioFile(file) {

    if (file.type.startsWith("audio/")) {
        return true;
    }

    const extension =
        file.name
            .split(".")
            .pop()
            ?.toLowerCase();

    return [
        "mp3",
        "wav",
        "ogg",
        "m4a",
        "aac",
        "flac",
        "opus"
    ].includes(extension);

}



function addFiles(fileList) {

    const files =
        [...fileList]
            .filter(isAudioFile);

    for (const file of files) {

        playlist.push({

            id:
                crypto.randomUUID(),

            name:
                file.name,

            title:
                cleanTitle(file.name),

            file,

            url:
                URL.createObjectURL(file)

        });

    }

    updateSongCount();

    renderPlaylist();

    if (
        currentIndex === -1 &&
        playlist.length > 0
    ) {

        loadTrack(0, false);

    }

}



function updateSongCount() {

    songCount.textContent =
        `${playlist.length} lagu`;

}



function renderPlaylist(filter = "") {

    playlistElement.innerHTML = "";

    const normalizedFilter =
        filter
            .trim()
            .toLowerCase();

    let visibleTracks = 0;

    playlist.forEach(
        (track, index) => {

            if (
                normalizedFilter &&
                !track.title
                    .toLowerCase()
                    .includes(normalizedFilter)
            ) {
                return;
            }

            visibleTracks++;

            const row =
                document.createElement("div");

            row.className =
                "track";

            if (index === currentIndex) {
                row.classList.add("active");
            }


            const number =
                document.createElement("div");

            number.className =
                "track-number";

            number.textContent =
                index === currentIndex &&
                !audio.paused
                    ? "▶"
                    : index + 1;


            const title =
                document.createElement("div");

            title.className =
                "track-name";

            title.textContent =
                track.title;


            const extension =
                document.createElement("div");

            extension.className =
                "track-extension";

            extension.textContent =
                track.name
                    .split(".")
                    .pop()
                    .toUpperCase();


            row.append(
                number,
                title,
                extension
            );


            row.addEventListener(
                "click",
                () => loadTrack(
                    index,
                    true
                )
            );


            playlistElement.appendChild(row);

        }
    );


    if (visibleTracks === 0) {

        const empty =
            document.createElement("div");

        empty.className =
            "empty-library";

        empty.textContent =
            playlist.length
                ? "Lagu tidak ditemukan."
                : "Pilih file musik untuk memulai.";

        playlistElement.appendChild(empty);

    }

}



function loadTrack(
    index,
    autoPlay = true
) {

    if (
        index < 0 ||
        index >= playlist.length
    ) {
        return;
    }

    currentIndex =
        index;

    const track =
        playlist[currentIndex];

    audio.src =
        track.url;

    titleElement.textContent =
        track.title;

    artistElement.textContent =
        "Local Music";

    footerTitle.textContent =
        track.title;

    footerArtist.textContent =
        "amarPlayer Web";

    document.title =
        `${track.title} — amarPlayer`;

    updateMediaSession(track);

    renderPlaylist(
        searchInput.value
    );


    if (autoPlay) {

        audio
            .play()
            .catch(error => {

                console.error(
                    "Play gagal:",
                    error
                );

            });

    }

}



function togglePlay() {

    if (!playlist.length) {
        return;
    }

    if (currentIndex === -1) {

        loadTrack(
            0,
            true
        );

        return;
    }


    if (audio.paused) {

        audio.play();

    } else {

        audio.pause();

    }

}



function nextTrack() {

    if (!playlist.length) {
        return;
    }

    let next =
        currentIndex + 1;

    if (
        next >= playlist.length
    ) {
        next = 0;
    }

    loadTrack(
        next,
        true
    );

}



function previousTrack() {

    if (!playlist.length) {
        return;
    }


    if (audio.currentTime > 3) {

        audio.currentTime = 0;

        return;

    }


    let previous =
        currentIndex - 1;

    if (previous < 0) {

        previous =
            playlist.length - 1;

    }

    loadTrack(
        previous,
        true
    );

}



function updateMediaSession(track) {

    if (
        !("mediaSession" in navigator)
    ) {
        return;
    }


    navigator.mediaSession.metadata =
        new MediaMetadata({

            title:
                track.title,

            artist:
                "amarPlayer",

            album:
                "Local Music"

        });

}



openFilesBtn?.addEventListener(
    "click",
    () => fileInput.click()
);


openFolderBtn?.addEventListener(
    "click",
    () => folderInput.click()
);


fileInput?.addEventListener(
    "change",
    event => {

        addFiles(
            event.target.files
        );

        event.target.value = "";

    }
);


folderInput?.addEventListener(
    "change",
    event => {

        addFiles(
            event.target.files
        );

        event.target.value = "";

    }
);


playBtn.addEventListener(
    "click",
    togglePlay
);


nextBtn.addEventListener(
    "click",
    nextTrack
);


prevBtn.addEventListener(
    "click",
    previousTrack
);


audio.addEventListener(
    "play",
    () => {

        playBtn.textContent =
            "⏸";

        renderPlaylist(
            searchInput.value
        );

        if (
            "mediaSession" in navigator
        ) {

            navigator.mediaSession
                .playbackState =
                "playing";

        }

    }
);


audio.addEventListener(
    "pause",
    () => {

        playBtn.textContent =
            "▶";

        renderPlaylist(
            searchInput.value
        );

        if (
            "mediaSession" in navigator
        ) {

            navigator.mediaSession
                .playbackState =
                "paused";

        }

    }
);


audio.addEventListener(
    "ended",
    nextTrack
);


audio.addEventListener(
    "loadedmetadata",
    () => {

        durationElement.textContent =
            formatTime(
                audio.duration
            );

    }
);


audio.addEventListener(
    "timeupdate",
    () => {

        currentTimeElement.textContent =
            formatTime(
                audio.currentTime
            );


        if (
            Number.isFinite(
                audio.duration
            )
        ) {

            progress.value =
                (
                    audio.currentTime /
                    audio.duration
                ) * 100;

        }

    }
);


progress.addEventListener(
    "input",
    () => {

        if (
            Number.isFinite(
                audio.duration
            )
        ) {

            audio.currentTime =
                (
                    progress.value /
                    100
                ) *
                audio.duration;

        }

    }
);


volume.addEventListener(
    "input",
    () => {

        audio.volume =
            Number(
                volume.value
            );

    }
);


audio.volume =
    Number(
        volume.value
    );


searchInput.addEventListener(
    "input",
    () => {

        renderPlaylist(
            searchInput.value
        );

    }
);


clearPlaylist.addEventListener(
    "click",
    () => {

        audio.pause();

        audio.removeAttribute(
            "src"
        );

        playlist.forEach(
            track =>
                URL.revokeObjectURL(
                    track.url
                )
        );

        playlist = [];

        currentIndex = -1;

        titleElement.textContent =
            "Belum ada lagu";

        artistElement.textContent =
            "amarPlayer Web";

        footerTitle.textContent =
            "amarPlayer";

        footerArtist.textContent =
            "Web Player";

        currentTimeElement.textContent =
            "0:00";

        durationElement.textContent =
            "0:00";

        progress.value =
            0;

        updateSongCount();

        renderPlaylist();

    }
);


if (
    "mediaSession" in navigator
) {

    navigator.mediaSession
        .setActionHandler(
            "play",
            () => audio.play()
        );

    navigator.mediaSession
        .setActionHandler(
            "pause",
            () => audio.pause()
        );

    navigator.mediaSession
        .setActionHandler(
            "nexttrack",
            nextTrack
        );

    navigator.mediaSession
        .setActionHandler(
            "previoustrack",
            previousTrack
        );

}


if (
    "serviceWorker" in navigator
) {

    window.addEventListener(
        "load",
        () => {

            navigator
                .serviceWorker
                .register(
                    "./service-worker.js"
                )
                .catch(
                    error =>
                        console.error(
                            "Service Worker:",
                            error
                        )
                );

        }
    );

}


/*
=========================================================
 amarPlayer Automatic Local Scanner
=========================================================
*/

let scannerConnected = false;


async function syncScannerLibrary() {

    try {

        const response = await fetch(
            "/api/library",
            {
                cache:
                    "no-store"
            }
        );


        if (!response.ok) {

            scannerConnected = false;

            return;

        }


        const data =
            await response.json();


        scannerConnected = true;


        const currentTrack =
            currentIndex >= 0
                ? playlist[
                    currentIndex
                ]
                : null;


        const currentTrackId =
            currentTrack
                ? currentTrack.id
                : null;


        /*
         * Pertahankan lagu yang
         * dipilih manual melalui browser.
         */

        const manualTracks =
            playlist.filter(
                track =>
                    track.source !==
                    "scanner"
            );


        /*
         * Library hasil scanner.
         */

        const scannedTracks =
            data.tracks.map(
                track => ({

                    id:
                        `scan:${track.id}`,

                    scannerId:
                        track.id,

                    name:
                        track.name,

                    title:
                        track.title,

                    artist:
                        track.artist,

                    extension:
                        track.extension,

                    url:
                        track.url,

                    source:
                        "scanner"

                })
            );


        playlist = [
            ...scannedTracks,
            ...manualTracks
        ];


        /*
         * Pertahankan posisi lagu
         * yang sedang dimainkan.
         */

        if (currentTrackId) {

            const newIndex =
                playlist.findIndex(
                    track =>
                        track.id ===
                        currentTrackId
                );


            if (newIndex >= 0) {

                currentIndex =
                    newIndex;

            }

        }


        updateSongCount();


        renderPlaylist(
            searchInput.value
        );


        /*
         * Jika belum ada lagu aktif,
         * load lagu pertama.
         */

        if (
            currentIndex === -1
            &&
            playlist.length > 0
        ) {

            loadTrack(
                0,
                false
            );

        }


        console.log(
            "[amarPlayer Scanner]",
            `${data.count} lagu`,
            data.scan_dirs
        );

    }

    catch (error) {

        /*
         * Tidak menjadi error fatal.
         * amarPlayer masih bisa
         * menggunakan File Picker.
         */

        scannerConnected = false;

        console.log(
            "[amarPlayer]",
            "Local scanner tidak tersedia."
        );

    }

}


/*
 * Scan pertama ketika amarPlayer dibuka.
 */

syncScannerLibrary();


/*
 * Sinkronisasi hasil watcher.
 *
 * Ini BUKAN scan filesystem setiap
 * 5 detik.
 *
 * FastAPI/watchdog yang mengawasi
 * filesystem.
 *
 * Browser hanya meminta daftar terbaru.
 */

setInterval(
    syncScannerLibrary,
    5000
);
