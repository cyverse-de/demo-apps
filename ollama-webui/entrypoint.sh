#!/usr/bin/env bash
# VICE entrypoint for the CyVerse AI Sandbox demo: makes sure the paths Open
# WebUI and Ollama write to are writable for whatever user VICE runs us as,
# starts Ollama, preloads the model, then hands off to upstream's start.sh.
set -euo pipefail

log() { echo "[entrypoint] $*"; }

# Open WebUI's data directory (chats, uploads, vector index) for this session.
DATA_DIR="${DATA_DIR:-/app/backend/data}"
if ! { mkdir -p "$DATA_DIR" && [[ -w "$DATA_DIR" ]]; } 2>/dev/null; then
    log "DATA_DIR $DATA_DIR is not writable; using /tmp/webui-data"
    DATA_DIR=/tmp/webui-data
    mkdir -p "$DATA_DIR"
fi
export DATA_DIR

# Upstream's start.sh writes its secret key next to itself unless told otherwise.
export WEBUI_SECRET_KEY_FILE="${WEBUI_SECRET_KEY_FILE:-$DATA_DIR/.webui_secret_key}"

# Ollama writes ~/.ollama on startup; HOME=/root isn't writable for non-root users.
if [[ ! -w "${HOME:-/nonexistent}" ]]; then
    export HOME=/tmp/sandbox-home
    mkdir -p "$HOME"
fi

# We start Ollama ourselves so the model is loaded before the UI comes up.
export USE_OLLAMA_DOCKER=false

WARMUP_TIMEOUT="${WARMUP_TIMEOUT:-60}"
MODEL="${SANDBOX_MODEL:?SANDBOX_MODEL must be set}"

warm_up() {
    local start=$SECONDS
    until curl -sf "http://${OLLAMA_HOST}/api/version" >/dev/null 2>&1; do
        if ((SECONDS - start >= WARMUP_TIMEOUT)); then
            log "WARNING: Ollama did not respond within ${WARMUP_TIMEOUT}s; starting the UI without a model"
            return 1
        fi
        sleep 1
    done
    # A generate request with no prompt just loads the model into memory.
    if curl -sf --max-time 180 "http://${OLLAMA_HOST}/api/generate" \
        -d "{\"model\": \"${MODEL}\", \"keep_alive\": -1}" >/dev/null; then
        log "Model ${MODEL} loaded"
    else
        log "WARNING: could not load model ${MODEL}; see the ollama output above"
        return 1
    fi
}

log "Starting ollama serve on ${OLLAMA_HOST}"
ollama serve &
warm_up || true

# Waits for the UI in the background, then indexes the sample documents.
/usr/local/bin/seed-library.sh &

log "Starting Open WebUI"
exec bash /app/backend/start.sh "$@"
