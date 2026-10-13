#!/usr/bin/env bash
# Pre-indexes the sample documents into an Open WebUI "Demo Library" knowledge
# collection once Open WebUI is up, so the presenter can type #Demo Library
# without uploading anything. Started in the background by entrypoint.sh; does
# nothing if the collection already has files (e.g. after a container restart).
set -euo pipefail

BASE="http://127.0.0.1:${PORT:-8080}"
API="$BASE/api/v1"
LIBRARY="Demo Library"
DOCS_DIR="${SANDBOX_DOCS_DIR:-/opt/sandbox-data}"

log() { echo "[seed-library] $*"; }

# require VALUE WHAT: fails the seeding when an API call returned no usable value.
# Needed because `seed || ...` below disables set -e inside seed().
require() {
    [[ -n "$1" && "$1" != "null" ]] || {
        log "no $2 returned"
        return 1
    }
}

seed() {
    local token id doc file_id healthy=false
    local -a auth docs

    shopt -s nullglob
    docs=("$DOCS_DIR"/*)
    ((${#docs[@]} > 0)) || {
        log "no documents in $DOCS_DIR"
        return 1
    }

    for _ in $(seq 1 120); do
        curl -sf "$BASE/health" >/dev/null 2>&1 && healthy=true && break
        sleep 1
    done
    $healthy || {
        log "Open WebUI did not become healthy"
        return 1
    }

    # With WEBUI_AUTH=False, signin ignores the credentials and returns the built-in user's token.
    token=$(curl -sf -X POST "$API/auths/signin" -H "Content-Type: application/json" \
        -d '{"email": "", "password": ""}' | jq -r .token) || true
    require "$token" "sign-in token" || return 1
    auth=(-H "Authorization: Bearer $token")

    # Reuse an existing library (a restart, or an earlier partial run); skip it only if it already has files.
    id=$(curl -sf "$API/knowledge/" "${auth[@]}" |
        jq -r --arg n "$LIBRARY" 'first(.items[] | select(.name == $n) | .id) // empty') || true
    if [[ -n "$id" ]]; then
        if (($(curl -sf "$API/knowledge/$id/files" "${auth[@]}" | jq -r '.total // 0') > 0)); then
            log "$LIBRARY already exists"
            return 0
        fi
    else
        id=$(curl -sf -X POST "$API/knowledge/create" "${auth[@]}" -H "Content-Type: application/json" \
            -d "$(jq -n --arg n "$LIBRARY" '{name: $n, description: "Sample documents for the CyVerse AI Sandbox demo"}')" |
            jq -r .id) || true
        require "$id" "knowledge collection id" || return 1
    fi

    for doc in "${docs[@]}"; do
        file_id=$(curl -sf -X POST "$API/files/?process=true&process_in_background=false" "${auth[@]}" \
            -F "file=@$doc" | jq -r .id) || true
        require "$file_id" "file id for $(basename "$doc")" || return 1
        curl -sf -X POST "$API/knowledge/$id/file/add" "${auth[@]}" -H "Content-Type: application/json" \
            -d "$(jq -n --arg f "$file_id" '{file_id: $f}')" >/dev/null || {
            log "could not add $(basename "$doc") to $LIBRARY"
            return 1
        }
        log "added $(basename "$doc") to $LIBRARY"
    done
}

seed || log "WARNING: could not create $LIBRARY; upload the sample report by hand instead"
