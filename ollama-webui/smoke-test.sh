#!/usr/bin/env bash
# Smoke test for the ollama-webui-demo image. Runs the container the way VICE
# would (non-root, no network) and checks startup, the model, answer quality,
# graceful stop, restart, and degraded startup when Ollama can't load a model.
set -euo pipefail

ENGINE="${CONTAINER_ENGINE:-docker}"
IMAGE="${IMAGE:-ollama-webui-demo:latest}"
MODEL="${MODEL:-llama3.2:3b}"
RUN_USER="${RUN_USER:-1000:0}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-90}"
ANSWER_WARN_SECONDS="${ANSWER_WARN_SECONDS:-30}"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SAMPLE_DIR="$SCRIPT_DIR/sample-data"
NAME="ollama-webui-smoke-$$"

cleanup() { "$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    echo "--- last 50 lines of container logs ---" >&2
    "$ENGINE" logs "$NAME" 2>&1 | tail -n 50 >&2 || true
    exit 1
}

pass() { echo "PASS: $*"; }

# start_container USER [extra run args...]
start_container() {
    local user="$1"
    shift
    cleanup
    "$ENGINE" run -d --name "$NAME" --user "$user" --network none \
        -v "$SAMPLE_DIR:/sample-data:ro" "$@" "$IMAGE" >/dev/null
}

# wait_healthy: polls /health until healthy, failing on timeout or container exit.
# Sets HEALTHY_AFTER (seconds). Not called via $(...) so that fail exits the script.
wait_healthy() {
    local start=$SECONDS
    until "$ENGINE" exec "$NAME" curl -sf http://127.0.0.1:8080/health >/dev/null 2>&1; do
        if [[ "$("$ENGINE" inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]]; then
            fail "container exited before becoming healthy"
        fi
        if ((SECONDS - start >= STARTUP_TIMEOUT)); then
            fail "Open WebUI not healthy after ${STARTUP_TIMEOUT}s"
        fi
        sleep 2
    done
    HEALTHY_AFTER=$((SECONDS - start))
}

# ask QUESTION: asks the model QUESTION about the sample report, prints the answer.
ask() {
    # shellcheck disable=SC2016 # $1/$2 expand inside the container's bash, not here.
    "$ENGINE" exec "$NAME" bash -c '
        jq -Rs --arg model "$1" --arg q "$2" \
            "{model: \$model, stream: false, options: {temperature: 0},
              prompt: (\"Answer the question using only the report below. Be brief.\n\nREPORT:\n\" + . + \"\n\nQUESTION: \" + \$q)}" \
            /sample-data/field-station-report.md |
        curl -sf --max-time 300 http://127.0.0.1:11434/api/generate -d @- |
        jq -r .response
    ' _ "$MODEL" "$1"
}

# wait_library: waits up to 60s for exactly one "Demo Library" collection
# holding at least one file. Seeding runs in the background after startup.
wait_library() {
    local start=$SECONDS state=""
    while ((SECONDS - start < 60)); do
        # shellcheck disable=SC2016 # expands inside the container's bash, not here.
        state=$("$ENGINE" exec "$NAME" bash -c '
            api=http://127.0.0.1:8080/api/v1
            token=$(curl -sf -X POST "$api/auths/signin" -H "Content-Type: application/json" \
                -d "{\"email\": \"\", \"password\": \"\"}" | jq -r .token)
            ids=$(curl -sf "$api/knowledge/" -H "Authorization: Bearer $token" |
                jq -r ".items[] | select(.name == \"Demo Library\") | .id")
            files=0
            [[ $(wc -w <<<"$ids") -eq 1 ]] &&
                files=$(curl -sf "$api/knowledge/$ids/files" -H "Authorization: Bearer $token" | jq -r .total)
            echo "$(wc -w <<<"$ids") $files"
        ' 2>/dev/null) || true
        [[ "$state" =~ ^1\ [1-9] ]] && return 0
        sleep 3
    done
    fail "expected one 'Demo Library' with files; got collections/files: '${state}'"
}

echo "== Main scenario: $IMAGE as $RUN_USER, no network =="
start_container "$RUN_USER"
wait_healthy
pass "Open WebUI healthy after ${HEALTHY_AFTER}s"

"$ENGINE" logs "$NAME" 2>&1 | grep -F "[entrypoint] Model $MODEL loaded" >/dev/null ||
    fail "entrypoint did not report the model as loaded"
pass "model preloaded by entrypoint"

"$ENGINE" exec "$NAME" ollama list | awk 'NR > 1 { print $1 }' | grep -xF "$MODEL" >/dev/null ||
    fail "ollama list does not include $MODEL"
pass "ollama list includes $MODEL"

wait_library
pass "Demo Library pre-indexed with the sample report"

while IFS=$'\t' read -r question keyword; do
    [[ -z "$question" || "$question" == \#* ]] && continue
    q_start=$SECONDS
    answer=$(ask "$question") || fail "no answer for: $question"
    elapsed=$((SECONDS - q_start))
    grep -qiF -- "$keyword" <<<"$answer" ||
        fail "answer to '$question' lacks '$keyword'. Got: $answer"
    pass "'$question' -> contains '$keyword' (${elapsed}s)"
    if ((elapsed > ANSWER_WARN_SECONDS)); then
        echo "WARN: answer took ${elapsed}s (> ${ANSWER_WARN_SECONDS}s demo target)"
    fi
done <"$SAMPLE_DIR/demo-questions.tsv"

stop_start=$SECONDS
"$ENGINE" stop -t 10 "$NAME" >/dev/null
stop_elapsed=$((SECONDS - stop_start))
((stop_elapsed < 10)) || fail "container needed ${stop_elapsed}s to stop (was SIGTERM ignored?)"
pass "stopped gracefully in ${stop_elapsed}s"

"$ENGINE" start "$NAME" >/dev/null
wait_healthy
pass "healthy again after restart in ${HEALTHY_AFTER}s"
wait_library
pass "Demo Library still present exactly once after restart"

echo "== Degraded scenario: unusual UID/GID, Ollama cannot load a model =="
start_container 54321:54321 -e WARMUP_TIMEOUT=5 -e OLLAMA_MODELS=/nonexistent/models
wait_healthy
pass "Open WebUI healthy without a model after ${HEALTHY_AFTER}s"
"$ENGINE" logs "$NAME" 2>&1 | grep -F "[entrypoint] WARNING" >/dev/null ||
    fail "entrypoint did not log a WARNING for the missing model"
pass "entrypoint logged a WARNING"

echo "All smoke checks passed."
