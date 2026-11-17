#!/usr/bin/env bash
#
# Network Transfer Integrity and Resume Manager
# Transfers one file to an authorized SSH destination, verifies SHA-256,
# retries transient failures, and logs transfer status and duration.
#
# Usage:
#   ./transfer_manager.sh SOURCE_FILE user@host:/absolute/remote/path [RETRIES] [TIMEOUT_SECONDS]
#
# Requirements:
#   bash, ssh, rsync, sha256sum, timeout
#
# SSH host-key checking is intentionally left enabled. Configure the host
# in ~/.ssh/config or connect once interactively to verify its fingerprint.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/transfer.log"

DEFAULT_RETRIES=3
DEFAULT_TIMEOUT=120

usage() {
  echo "Usage: $0 SOURCE_FILE user@host:/absolute/remote/path [RETRIES] [TIMEOUT_SECONDS]"
}

log() {
  local message="$1"
  mkdir -p "$LOG_DIR"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $1"
  exit 1
}

command -v ssh >/dev/null 2>&1 || { echo "Missing command: ssh" >&2; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "Missing command: rsync" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "Missing command: sha256sum" >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "Missing command: timeout" >&2; exit 1; }

if [[ $# -lt 2 || $# -gt 4 ]]; then
  usage
  exit 2
fi

SOURCE_FILE="$1"
DESTINATION="$2"
MAX_RETRIES="${3:-$DEFAULT_RETRIES}"
TIMEOUT_SECONDS="${4:-$DEFAULT_TIMEOUT}"

[[ -f "$SOURCE_FILE" ]] || die "Source file does not exist: $SOURCE_FILE"
[[ -r "$SOURCE_FILE" ]] || die "Source file is not readable: $SOURCE_FILE"
[[ "$MAX_RETRIES" =~ ^[1-9][0-9]*$ ]] || die "Retries must be a positive integer"
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "Timeout must be a positive integer"

# Require user@host:/absolute/path syntax. This avoids accepting arbitrary
# local paths or ambiguous rsync destination forms.
if [[ ! "$DESTINATION" =~ ^([a-zA-Z0-9._-]+)@([a-zA-Z0-9.-]+):(/[^:]*)$ ]]; then
  die "Destination must look like user@host:/absolute/remote/path"
fi
REMOTE_USER="${BASH_REMATCH[1]}"
REMOTE_HOST="${BASH_REMATCH[2]}"
REMOTE_PATH="${BASH_REMATCH[3]}"

# Restrict remote path to a conservative character set; quote it again
# when sending it through the remote shell.
if [[ ! "$REMOTE_PATH" =~ ^/[a-zA-Z0-9._/-]+$ ]]; then
  die "Remote path may contain only letters, digits, dot, underscore, slash and hyphen"
fi

REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=15)

mkdir -p "$LOG_DIR"

# Validate connectivity and destination directory before starting.
log "Checking SSH access to $REMOTE"
timeout "${TIMEOUT_SECONDS}s" ssh "${SSH_OPTIONS[@]}" "$REMOTE" \
  "test -d '$REMOTE_PATH' && test -w '$REMOTE_PATH'" \
  || die "Cannot access writable destination directory: $DESTINATION"

SOURCE_NAME="$(basename -- "$SOURCE_FILE")"
SOURCE_CHECKSUM="$(sha256sum -- "$SOURCE_FILE" | awk '{print $1}')"
REMOTE_FILE="${REMOTE_PATH%/}/$SOURCE_NAME"
START_TIME="$(date +%s)"

log "Starting transfer: $SOURCE_FILE -> $DESTINATION"
log "Source SHA-256: $SOURCE_CHECKSUM"

SUCCESS=0
for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
  log "Transfer attempt $attempt of $MAX_RETRIES"

  # --partial keeps partially transferred data; --append-verify allows
  # rsync to continue a partially transferred file while verifying data.
  if timeout "${TIMEOUT_SECONDS}s" rsync -a --partial --append-verify \
      -e "ssh -o BatchMode=yes -o ConnectTimeout=15" \
      -- "$SOURCE_FILE" "${REMOTE}:${REMOTE_FILE}"; then

    log "Transfer command completed; verifying destination checksum"

    # -- protects the remote shell command from path interpretation.
    REMOTE_CHECKSUM="$(
      timeout "${TIMEOUT_SECONDS}s" ssh "${SSH_OPTIONS[@]}" "$REMOTE" \
        "sha256sum -- '$REMOTE_FILE'" | awk '{print $1}'
    )" || REMOTE_CHECKSUM=""

    if [[ -n "$REMOTE_CHECKSUM" && "$SOURCE_CHECKSUM" == "$REMOTE_CHECKSUM" ]]; then
      SUCCESS=1
      break
    fi

    log "Checksum mismatch or verification failure (source=$SOURCE_CHECKSUM, destination=${REMOTE_CHECKSUM:-unavailable})"
  else
    TRANSFER_STATUS=$?
    log "Transfer attempt failed with exit status $TRANSFER_STATUS"
  fi

  if (( attempt < MAX_RETRIES )); then
    DELAY=$((attempt * 2))
    log "Retrying in ${DELAY} seconds"
    sleep "$DELAY"
  fi
done

END_TIME="$(date +%s)"
DURATION=$((END_TIME - START_TIME))

if (( SUCCESS == 1 )); then
  log "SUCCESS: checksum verified; duration=${DURATION}s; destination=$DESTINATION"
  exit 0
else
  log "FAILURE: transfer or checksum verification failed after $MAX_RETRIES attempts; duration=${DURATION}s; destination=$DESTINATION"
  exit 1
fi
