#!/usr/bin/env bash
#
# Network Transfer Integrity and Resume Manager
# Usage: ./transfer_manager.sh SOURCE_FILE user@host:/absolute/remote/dir [RETRIES] [TIMEOUT_SECONDS]
#
# Requires: bash, ssh, rsync, a SHA-256 utility, and timeout (or gtimeout).
# Host-key checking remains enabled. Never use StrictHostKeyChecking=no.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/transfer.log"
DEFAULT_RETRIES=3
DEFAULT_TIMEOUT=120
START_TIME=0
FINISHED=0

usage() {
  echo "Usage: $0 SOURCE_FILE user@host:/absolute/remote/dir [RETRIES] [TIMEOUT_SECONDS]"
}

log() {
  mkdir -p "$LOG_DIR"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $1"
  exit 1
}

on_signal() {
  local signal="$1"
  log "INTERRUPTED: received $signal; rsync partial data is retained where supported"
  exit 130
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

# Pick GNU timeout on macOS (installed as gtimeout by Homebrew coreutils),
# or the standard timeout command on Linux.
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="$(command -v gtimeout)"
else
  echo "Missing timeout utility. macOS: brew install coreutils; Linux: install coreutils." >&2
  exit 1
fi

for cmd in ssh rsync awk date basename; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd" >&2; exit 1; }
done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 127
  fi
}

if [[ $# -lt 2 || $# -gt 4 ]]; then
  usage
  exit 2
fi

SOURCE_FILE="$1"
DESTINATION="$2"
MAX_RETRIES="${3:-$DEFAULT_RETRIES}"
TIMEOUT_SECONDS="${4:-$DEFAULT_TIMEOUT}"

[[ -f "$SOURCE_FILE" && -r "$SOURCE_FILE" ]] || die "Source file is missing or unreadable: $SOURCE_FILE"
[[ "$MAX_RETRIES" =~ ^[1-9][0-9]*$ ]] || die "RETRIES must be a positive integer"
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "TIMEOUT_SECONDS must be a positive integer"

if [[ ! "$DESTINATION" =~ ^([a-zA-Z0-9._-]+)@([a-zA-Z0-9.-]+):(/[^:]*)$ ]]; then
  die "Destination must use user@host:/absolute/remote/directory syntax"
fi
REMOTE_USER="${BASH_REMATCH[1]}"
REMOTE_HOST="${BASH_REMATCH[2]}"
REMOTE_PATH="${BASH_REMATCH[3]}"

# Restrict paths and filenames to safe characters for the remote shell command.
[[ "$REMOTE_PATH" =~ ^/[a-zA-Z0-9._/-]+$ ]] || die "Remote path may contain only letters, digits, dot, underscore, slash and hyphen"
SOURCE_NAME="$(basename "$SOURCE_FILE")"
[[ "$SOURCE_NAME" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Source filename may contain only letters, digits, dot, underscore and hyphen"

REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
REMOTE_FILE="${REMOTE_PATH%/}/$SOURCE_NAME"
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=15)

mkdir -p "$LOG_DIR"
START_TIME="$(date +%s)"
trap 'log "EXIT: transfer manager stopped"' EXIT

log "Checking SSH access and destination directory: $DESTINATION"
if ! "$TIMEOUT_CMD" "${TIMEOUT_SECONDS}s" ssh "${SSH_OPTIONS[@]}" "$REMOTE" \
  "test -d '$REMOTE_PATH' && test -w '$REMOTE_PATH'"; then
  die "Cannot connect or destination directory is not writable. Check SSH authorization, host key, and remote path."
fi

SOURCE_CHECKSUM="$(sha256_file "$SOURCE_FILE")" || die "No SHA-256 utility found (install coreutils or use shasum)"
log "Source SHA-256: $SOURCE_CHECKSUM"
log "Starting transfer: $SOURCE_FILE -> $DESTINATION"

SUCCESS=0
for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
  log "Attempt $attempt/$MAX_RETRIES"

  # --partial retains an incomplete file. --append-verify resumes it and
  # verifies the already-transferred portion before continuing.
  if "$TIMEOUT_CMD" "${TIMEOUT_SECONDS}s" rsync -a --partial --append-verify \
      -e "ssh -o BatchMode=yes -o ConnectTimeout=15" \
      -- "$SOURCE_FILE" "${REMOTE}:${REMOTE_FILE}"; then
    log "Transfer command completed; checking destination checksum"

    REMOTE_CHECKSUM="$(
      "$TIMEOUT_CMD" "${TIMEOUT_SECONDS}s" ssh "${SSH_OPTIONS[@]}" "$REMOTE" \
        "if command -v sha256sum >/dev/null 2>&1; then sha256sum '$REMOTE_FILE'; elif command -v shasum >/dev/null 2>&1; then shasum -a 256 '$REMOTE_FILE'; else exit 127; fi" \
        | awk 'NR==1 {print $1}'
    )" || REMOTE_CHECKSUM=""

    if [[ -n "$REMOTE_CHECKSUM" && "$SOURCE_CHECKSUM" == "$REMOTE_CHECKSUM" ]]; then
      SUCCESS=1
      break
    fi
    log "Checksum verification failed (source=$SOURCE_CHECKSUM, destination=${REMOTE_CHECKSUM:-unavailable})"
  else
    status=$?
    log "Transfer attempt failed (exit status $status)"
  fi

  if (( attempt < MAX_RETRIES )); then
    delay=$((attempt * 2))
    log "Retrying in ${delay}s"
    sleep "$delay"
  fi
done

END_TIME="$(date +%s)"
DURATION=$((END_TIME - START_TIME))
FINISHED=1

if (( SUCCESS == 1 )); then
  log "SUCCESS: destination checksum matches source; duration=${DURATION}s; destination=$DESTINATION"
  exit 0
fi

log "FAILURE: transfer/checksum verification failed after $MAX_RETRIES attempts; duration=${DURATION}s; destination=$DESTINATION"
exit 1
