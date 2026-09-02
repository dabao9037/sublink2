#!/usr/bin/env bash
set -Eeuo pipefail

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "run as root" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${1:-$ROOT}"
SERVICE_USER="${SUBLINK2_SMOKE_USER:-nobody}"
id "$SERVICE_USER" >/dev/null 2>&1 || { echo "missing service user: $SERVICE_USER" >&2; exit 1; }
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
SMOKE_USER="$SERVICE_USER"
SMOKE_ROOT="$(mktemp -d /opt/sublink2-lowpriv-smoke.XXXXXX)"
RELEASE="$SMOKE_ROOT/releases/test"
DATA="$SMOKE_ROOT/data"
LOG="$SMOKE_ROOT/uvicorn.log"
PID=""

cleanup(){
  [ -z "$PID" ] || kill "$PID" >/dev/null 2>&1 || true
  [ -z "$PID" ] || wait "$PID" >/dev/null 2>&1 || true
  rm -rf "$SMOKE_ROOT"
}
trap cleanup EXIT

install -d -o root -g root -m 0755 "$SMOKE_ROOT" "$SMOKE_ROOT/releases" "$RELEASE"
install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0750 "$DATA"
cp -a "$SOURCE_DIR/app" "$SOURCE_DIR/requirements.txt" "$RELEASE/"

# Reproduce the installer bug: write_config used to leak umask 0077, causing
# python -m venv to create venv/ and venv/bin/ as root-only 0700.
umask 0077
python3 -m venv "$RELEASE/venv"
"$RELEASE/venv/bin/pip" install --disable-pip-version-check -q -r "$RELEASE/requirements.txt"

before_mode="$(stat -c '%a' "$RELEASE/venv/bin")"
[ "$before_mode" = 700 ] || { echo "expected red-capable 0700 venv/bin, got $before_mode" >&2; exit 1; }
if /usr/sbin/runuser -u "$SERVICE_USER" -- "$RELEASE/venv/bin/python" -c 'print("unexpected")' >/dev/null 2>&1; then
  echo "low-privilege permission repro unexpectedly passed before normalization" >&2
  exit 1
fi

# Load function definitions without dispatching the installer's CLI.
source <(sed '/^case "$ACTION" in$/,$d' "$ROOT/install.sh")
SERVICE_USER="$SMOKE_USER"
DATA_DIR="$DATA"
normalize_release_permissions "$RELEASE"
verify_release_for_service_user "$RELEASE"

/usr/sbin/runuser -u "$SERVICE_USER" -- "$RELEASE/venv/bin/python" -c 'import sys; print(sys.executable)' | grep -Fq "$RELEASE/venv/bin/python"
/usr/sbin/runuser -u "$SERVICE_USER" -- "$RELEASE/venv/bin/uvicorn" --version | grep -Fq 'uvicorn'

PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)"
SECRET="$(python3 - <<'PY'
from cryptography.fernet import Fernet
print(Fernet.generate_key().decode())
PY
)"

/usr/sbin/runuser -u "$SERVICE_USER" -- env \
  APP_SECRET="$SECRET" ADMIN_USER=admin ADMIN_PASSWORD=test-password \
  DB_PATH="$DATA/smoke.db" \
  "$RELEASE/venv/bin/uvicorn" app.main:app --app-dir "$RELEASE" \
  --host 127.0.0.1 --port "$PORT" >"$LOG" 2>&1 &
PID=$!
for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:${PORT}/healthz" 2>/dev/null | grep -Fq '"status":"ok"'; then
    break
  fi
  kill -0 "$PID" 2>/dev/null || { cat "$LOG" >&2; exit 1; }
  sleep 1
done
curl -fsS "http://127.0.0.1:${PORT}/healthz" | grep -Fq '"status":"ok"'
curl -fsS "http://127.0.0.1:${PORT}/login" | grep -Fq '欢迎回来'

echo "low-privilege native smoke passed"
