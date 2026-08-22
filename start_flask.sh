#!/bin/bash
# Local development helper. Reads configuration from .env (see .env.example).
# Never hardcode database credentials in this file.
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f .env ]; then
    echo "No .env found. Copy .env.example to .env and fill in your values." >&2
    exit 1
fi

if [ ! -d venv ]; then
    python3 -m venv venv
fi

./venv/bin/pip install --upgrade pip wheel
./venv/bin/pip install -r requirements.txt

set -a
# shellcheck disable=SC1091
source .env
set +a

exec ./venv/bin/gunicorn app:app --bind "0.0.0.0:${PORT:-5000}" --workers 2
