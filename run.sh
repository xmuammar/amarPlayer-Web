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
