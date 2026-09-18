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
