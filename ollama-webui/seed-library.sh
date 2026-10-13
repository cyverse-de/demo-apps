#!/usr/bin/env bash
# Pre-indexes the sample documents into an Open WebUI "Demo Library" knowledge
# collection once Open WebUI is up, so the presenter can type #Demo Library
# without uploading anything. Started in the background by entrypoint.sh; does
# nothing if the collection already exists (e.g. after a container restart).
set -euo pipefail

BASE="http://127.0.0.1:${PORT:-8080}"
API="$BASE/api/v1"
LIBRARY="Demo Library"
DOCS_DIR="${SANDBOX_DOCS_DIR:-/opt/sandbox-data}"

log() { echo "[seed-library] $*"; }

seed() {
    local token id doc file_id
    local -a auth

    for _ in $(seq 1 120); do
        curl -sf "$BASE/health" >/dev/null 2>&1 && break
        sleep 1
    done

    # With WEBUI_AUTH=False, signin ignores the credentials and returns the built-in user's token.
    token=$(curl -sf -X POST "$API/auths/signin" -H "Content-Type: application/json" \
        -d '{"email": "", "password": ""}' | jq -r .token)
    auth=(-H "Authorization: Bearer $token")

    if curl -sf "$API/knowledge/" "${auth[@]}" |
        jq -e --arg n "$LIBRARY" 'any(.items[]; .name == $n)' >/dev/null; then
        log "$LIBRARY already exists"
        return 0
    fi

    id=$(curl -sf -X POST "$API/knowledge/create" "${auth[@]}" -H "Content-Type: application/json" \
        -d "$(jq -n --arg n "$LIBRARY" '{name: $n, description: "Sample documents for the CyVerse AI Sandbox demo"}')" |
        jq -r .id)

    for doc in "$DOCS_DIR"/*; do
        file_id=$(curl -sf -X POST "$API/files/?process=true&process_in_background=false" "${auth[@]}" \
            -F "file=@$doc" | jq -r .id)
        curl -sf -X POST "$API/knowledge/$id/file/add" "${auth[@]}" -H "Content-Type: application/json" \
            -d "$(jq -n --arg f "$file_id" '{file_id: $f}')" >/dev/null
        log "added $(basename "$doc") to $LIBRARY"
    done
}

seed || log "WARNING: could not create $LIBRARY; upload the sample report by hand instead"
