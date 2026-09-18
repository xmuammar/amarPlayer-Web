# amarPlayer Web

amarPlayer Web adalah versi web dari **amarPlayer**, aplikasi pemutar musik yang dikembangkan secara mandiri.

Versi ini dirancang untuk membawa pengalaman amarPlayer Desktop ke platform web dengan pendekatan **local-first**, sehingga library musik tetap berasal dari penyimpanan lokal pengguna.

## Fitur Saat Ini

* Automatic music library scan
* Recursive folder scanning
* Realtime filesystem monitoring menggunakan Watchdog
* Playlist otomatis
* Search lagu
* Play / Pause
* Previous / Next
* Auto Next
* Seek / progress bar
* Volume control
* Media Session API
* Progressive Web App dasar
* Responsive interface
* Local music streaming melalui FastAPI
* Support MP3, FLAC, WAV, OGG, OPUS, M4A, AAC, dan format audio lainnya
* Tidak perlu memilih file musik satu per satu

## Cara Kerja

amarPlayer Web menggunakan dua bagian utama:

```text
amarPlayer Web
      │
      ├── Frontend
      │   ├── HTML
      │   ├── CSS
      │   ├── JavaScript
      │   ├── Media Session API
      │   └── PWA
      │
      └── Local Backend
          ├── Python
          ├── FastAPI
          ├── Watchdog
          └── Automatic Music Scanner
```

Saat aplikasi dijalankan, backend melakukan scanning otomatis terhadap direktori musik yang telah dikonfigurasi.

```text
amarPlayer Web Start
        │
        ▼
Automatic Scanner
        │
        ▼
~/Music
~/Musik
Custom Music Directory
        │
        ▼
Music Library
        │
        ▼
Playlist
```

Watchdog juga memonitor perubahan filesystem.

Jika sebuah lagu ditambahkan, dipindahkan, diubah, atau dihapus, library amarPlayer akan diperbarui kembali.

## Struktur Project

```text
amarPlayer-Web/
│
├── server.py
├── index.html
├── manifest.webmanifest
├── service-worker.js
├── requirements.txt
├── amarplayer-config.example.json
│
├── css/
│   └── main.css
│
├── js/
│   └── app.js
│
└── icons/
    └── icon.svg
```

## Instalasi

Clone repository:

```bash
git clone https://github.com/xmuammar/amarPlayer-Web.git
cd amarPlayer-Web
```

Buat Python virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
```

Install dependency:

```bash
pip install -r requirements.txt
```

## Konfigurasi Music Directory

Salin file konfigurasi contoh:

```bash
cp amarplayer-config.example.json amarplayer-config.json
```

Contoh konfigurasi:

```json
{
    "music_dirs": [
        "~/Music",
        "~/Musik"
    ]
}
```

Direktori tambahan juga dapat dimasukkan:

```json
{
    "music_dirs": [
        "~/Music",
        "~/Musik",
        "~/Downloads/Music"
    ]
}
```

File `amarplayer-config.json` tidak dimasukkan ke Git karena konfigurasi folder dapat berbeda pada setiap komputer.

## Menjalankan amarPlayer Web

Aktifkan virtual environment:

```bash
source .venv/bin/activate
```

Jalankan FastAPI server:

```bash
uvicorn server:app --host 127.0.0.1 --port 8080
```

Kemudian buka:

```text
http://localhost:8080
```

amarPlayer akan melakukan scanning library secara otomatis saat server dijalankan.

## Keamanan

Local scanner hanya dijalankan melalui:

```text
127.0.0.1
```

Hal ini dilakukan karena backend memiliki akses ke direktori musik lokal pengguna.

Jangan mengekspos local scanner langsung ke jaringan publik tanpa authentication dan security layer tambahan.

## Teknologi

### Backend

* Python
* FastAPI
* Uvicorn
* Watchdog

### Frontend

* HTML5
* CSS3
* JavaScript
* HTML Audio
* Media Session API
* Service Worker
* Progressive Web App

## Roadmap

### amarPlayer Web v0.1

* [x] Automatic music scanning
* [x] Local music streaming
* [x] Playlist
* [x] Search
* [x] Play / Pause
* [x] Previous / Next
* [x] Seek
* [x] Volume
* [x] Realtime filesystem monitoring
* [x] PWA foundation

### amarPlayer Web v0.2

* [ ] Metadata reader
* [ ] Artist information
* [ ] Album information
* [ ] Album artwork
* [ ] Duration scanner
* [ ] IndexedDB library

### amarPlayer Web v0.3

* [ ] Web Audio API
* [ ] 10-band equalizer
* [ ] Equalizer presets
* [ ] Spectrum analyzer
* [ ] Audio visualization

### amarPlayer Web v0.4

* [ ] Favorites
* [ ] History
* [ ] Persistent playlist
* [ ] Music library database

### amarPlayer Web v0.5

* [ ] amarSSO integration
* [ ] User account
* [ ] Cloud playlist synchronization
* [ ] Cross-device settings synchronization

## Project Philosophy

amarPlayer dikembangkan bukan hanya sebagai pemutar musik, tetapi sebagai proyek eksplorasi software engineering yang menggabungkan desktop application, web application, audio processing, backend service, local filesystem integration, dan teknologi web modern.

Tujuan pengembangan amarPlayer adalah membangun pemutar musik lintas platform secara mandiri dan terus mengembangkan kemampuan teknis di setiap versinya.

## Platforms

Target ekosistem amarPlayer:

```text
amarPlayer
│
├── Linux
├── Windows
├── macOS
├── Android
├── iOS
└── Web / PWA
```

## Developer

**Muammar, SST, M.Kom**

Programmer / Software Engineer

## License

Project ini masih dalam tahap pengembangan.

Lisensi dapat ditentukan pada tahap release berikutnya.

