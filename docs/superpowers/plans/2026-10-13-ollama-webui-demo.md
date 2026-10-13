# CyVerse AI Sandbox Demo (Ollama + Open WebUI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a container image that runs Ollama, with a small model baked in, plus Open WebUI as a VICE app for live
AI Sandboxes UI demos. Ship it with a Justfile, a smoke test, sample data and a demo README.

**Architecture:** Extend the official `ghcr.io/open-webui/open-webui:v0.12.0-ollama` image. At build time, pull the
chat model into `/opt/ollama/models`. At runtime, a small entrypoint starts Ollama on localhost, preloads the model and
`exec`s upstream's `start.sh` with upstream's own Ollama launch disabled. A bash smoke test runs the image the way VICE
would (non-root, no network) and checks startup, the model and answer quality.

**Tech Stack:** Docker or Podman, `just` (1.58 is installed), bash, `shellcheck`, Ollama, Open WebUI v0.12.0, and
`llama3.2:3b`.

**Spec:** `docs/superpowers/specs/2026-10-13-ollama-webui-demo-design.md`

## Global Constraints

- Base image is pinned: `ghcr.io/open-webui/open-webui:v0.12.0-ollama` (confirmed to exist for amd64 and arm64).
- Default model: `llama3.2:3b`, overridable with `MODEL`.
- Registry image: `harbor.cyverse.org/de/ollama-webui-demo`.
- Pushed images must be `linux/amd64`, because the VICE nodes are amd64.
- Fully offline at runtime: no downloads after the build.
- No login screen: `WEBUI_AUTH=False`.
- Must run as an arbitrary non-root UID and GID.
- Must build and run with both Docker and Podman; the Dockerfile uses no `RUN --mount` and no `COPY --chmod`.
- Exposes one port: 8080.
- Startup budget: healthy within 90 s in the smoke test (VICE target is about 60 s on a node with the image cached).
- Bash scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, and must pass `shellcheck`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Facts verified against upstream v0.12.0 (read before Task 3)

These were read from upstream's `Dockerfile` and `backend/start.sh` at tag `v0.12.0`:

- **Working directory and ports:** `WORKDIR` is `/app/backend`, `PORT=8080`, and the `CMD` is `["bash", "start.sh"]`.
  The image runs as root (`UID=0`) by default.
- **Data directory:** `/app/backend/data`, owned by root.
- **Baked-in models:** the embedding model (`all-MiniLM-L6-v2`), the auxiliary embedding model, Whisper and tiktoken are
  already baked into `/app/backend/data/cache/...` and made readable by everyone. `HF_HOME` and
  `SENTENCE_TRANSFORMERS_HOME` point there. The spec's "pre-download embedding model" step is therefore already done
  upstream, and we only need to keep that cache readable.
- **Bundled Ollama:** `USE_OLLAMA_DOCKER=true` in the `-ollama` image, which makes `start.sh` run its own
  `ollama serve &`. We must set `USE_OLLAMA_DOCKER=false` to avoid two Ollama servers.
- **Secret key file:** `start.sh` writes `.webui_secret_key` to `/app/backend` (its own directory) unless
  `WEBUI_SECRET_KEY_FILE` is set. That directory isn't writable for non-root users, so we point the file into `DATA_DIR`.
- **Home directory:** `HOME=/root`. Ollama writes `~/.ollama/id_ed25519` on startup, so non-root users need a writable
  `HOME`.
- **Tools:** `curl` and `jq` are installed in the image.

## Review Focus

1. **Running as an unexpected UID and GID** (for example `54321:54321`, where the group isn't root). The UI should still
   start, because nothing should depend on group 0. Covered by the degraded scenario in Task 2's `smoke-test.sh`.
2. **Ollama failing to start or to load the model.** The UI should still become healthy within the timeout and the logs
   should contain a clear `WARNING`, rather than an endless VICE spinner. Covered by the degraded scenario in Task 2.
3. **VICE stopping the analysis.** The container should exit on SIGTERM within 10 s instead of being force-killed.
   Covered by the stop-timing check in Task 2.
4. **The container restarting in the same pod with a populated data directory.** The entrypoint must be safe to run
   again and the UI should come back. Covered by the restart check in Task 2.
5. **Pushing an arm64 image built on a Mac.** `just push` should refuse anything that isn't amd64. Covered by the
   guard and its manual check in Task 1 (Step 4).

---

## File Structure

All new, under `ollama-webui/`:

| File | Responsibility |
|---|---|
| `Justfile` | Engine detection plus the build, run, shell, smoke, lint and push recipes |
| `sample-data/field-station-report.md` | Made-up document with checkable facts, for document Q&A |
| `sample-data/demo-questions.tsv` | Scripted questions and expected keywords, shared by the smoke test and the README |
| `smoke-test.sh` | VICE-like runtime checks: main, restart, stop and degraded scenarios |
| `Dockerfile` | Extends the upstream image: model pull, environment, permissions, entrypoint |
| `entrypoint.sh` | Writable paths, starts Ollama, preloads the model, `exec`s upstream `start.sh` |
| `README.md` | Build, DE registration, demo script, pre-demo checklist |

---

### Task 1: Justfile and sample data

**Files:**
- Create: `ollama-webui/Justfile`
- Create: `ollama-webui/sample-data/field-station-report.md`
- Create: `ollama-webui/sample-data/demo-questions.tsv`

**Interfaces:**
- Produces:
  - Just variables `MODEL` (default `llama3.2:3b`), `PLATFORM` (default `linux/amd64`), `TAG` (default: today's date)
    and `engine`.
  - The local image name `ollama-webui-demo:latest`.
  - The recipe `smoke`, which calls `./smoke-test.sh` with the environment variables `CONTAINER_ENGINE`, `IMAGE` and
    `MODEL`.
  - `demo-questions.tsv`: one `question<TAB>expected keyword` per line. Lines starting with `#` are comments.

- [ ] **Step 1: Write the sample report**

Create `ollama-webui/sample-data/field-station-report.md`:

```markdown
# Sky Island Field Station — Spring 2026 Survey Report

*Fictional document prepared for the CyVerse AI Sandbox demo. All names, sites and figures are invented.*

## Summary

Between April 6 and May 15, 2026, the Sky Island Field Station team surveyed three sites in the
Santa Ventana foothills: Cholla Flats, Juniper Bench and Mesquite Draw. The survey focused on
pollinator activity and soil moisture following an unusually wet winter.

## Sites and Results

| Site | Elevation (m) | Pollinator visits recorded | Soil cores collected |
|---|---|---|---|
| Cholla Flats | 1,140 | 412 | 52 |
| Juniper Bench | 1,620 | 287 | 61 |
| Mesquite Draw | 980 | 198 | 35 |

Cholla Flats recorded the highest number of pollinator visits of any site, driven largely by
a strong bloom of desert marigold in late April. In total, the team collected 148 soil cores
across all three sites.

## Night Survey

A night survey for moth pollinators took place on April 19 at Juniper Bench and was led by
Dr. Amara Okonkwo. The team recorded 23 moth species, including two not previously documented
at the station.

## Equipment Issues

The weather station anemometer at Mesquite Draw failed on May 2 and was replaced on May 9.
Wind data for that week is missing and has been flagged in the dataset.

## Next Steps

- Repeat the pollinator transects in September to compare against the spring baseline.
- Send the soil cores to the Tucson lab for moisture and nutrient analysis.
```

- [ ] **Step 2: Write the scripted questions**

Create `ollama-webui/sample-data/demo-questions.tsv`. Use a real tab between each question and its keyword.

```
# question<TAB>expected keyword (case-insensitive substring of a correct answer)
Which site had the highest number of pollinator visits?	Cholla Flats
How many soil cores were collected in total?	148
Who led the night survey on April 19?	Okonkwo
What piece of equipment failed at Mesquite Draw?	anemometer
```

Run `grep -P '\t' ollama-webui/sample-data/demo-questions.tsv | wc -l`. Expected: `4` (the comment line has no tab).
On macOS, if `grep -P` isn't available, use `awk -F'\t' 'NF==2' ollama-webui/sample-data/demo-questions.tsv | wc -l`.
Expected: `4`.

- [ ] **Step 3: Write the Justfile**

Create `ollama-webui/Justfile`:

```just
set shell := ["bash", "-euo", "pipefail", "-c"]

# Podman if installed, otherwise Docker. Override with CONTAINER_ENGINE=docker (or podman).
engine := env("CONTAINER_ENGINE", `command -v podman >/dev/null 2>&1 && echo podman || echo docker`)

registry := "harbor.cyverse.org/de"
image := "ollama-webui-demo"
MODEL := "llama3.2:3b"
# VICE nodes are amd64. For quick local testing on Apple Silicon, use PLATFORM=linux/arm64 (never push it).
PLATFORM := "linux/amd64"
TAG := `date +%Y-%m-%d`

# List recipes
default:
    @just --list

# Print the container engine that will be used
show-engine:
    @echo {{ engine }}

# Build the image (tagged ollama-webui-demo:latest locally)
build:
    {{ engine }} build --platform {{ PLATFORM }} --build-arg MODEL={{ MODEL }} -t {{ image }}:latest .

# Run locally on http://localhost:8080 as a non-root user, like VICE
run:
    {{ engine }} run --rm -it --platform {{ PLATFORM }} --user 1000:0 -p 8080:8080 {{ image }}:latest

# Open a shell in the image
shell:
    {{ engine }} run --rm -it --platform {{ PLATFORM }} --user 1000:0 --entrypoint bash {{ image }}:latest

# Run the smoke test against the local image
smoke:
    CONTAINER_ENGINE={{ engine }} IMAGE={{ image }}:latest MODEL={{ MODEL }} ./smoke-test.sh

# Lint the shell scripts
lint:
    shellcheck entrypoint.sh smoke-test.sh

# Push the local image to Harbor, tagged with TAG (amd64 only)
push:
    #!/usr/bin/env bash
    set -euo pipefail
    arch=$({{ engine }} image inspect --format '{{{{.Architecture}}' {{ image }}:latest)
    if [[ "$arch" != "amd64" ]]; then
        echo "Refusing to push: local image is $arch, but VICE nodes need amd64. Rebuild with 'just build'." >&2
        exit 1
    fi
    {{ engine }} tag {{ image }}:latest {{ registry }}/{{ image }}:{{ TAG }}
    {{ engine }} push {{ registry }}/{{ image }}:{{ TAG }}
```

- [ ] **Step 4: Verify the Justfile**

Run these from `ollama-webui/`:
- `just --list`. Expected: the recipes `build`, `lint`, `push`, `run`, `shell`, `show-engine` and `smoke`, with their
  comments.
- `just show-engine`. Expected: `docker` on this machine (Podman isn't installed).
- `CONTAINER_ENGINE=podman just show-engine`. Expected: `podman`.
- `just --dry-run MODEL=qwen2.5:3b build`. Expected: the printed command contains `--build-arg MODEL=qwen2.5:3b` and
  `--platform linux/amd64`.
- Push guard (Review Focus 5): `docker pull --platform linux/arm64 alpine:3.20 && docker tag alpine:3.20 ollama-webui-demo:latest && just registry=localhost:1/guard-test push`.
  Expected: exits non-zero with `Refusing to push: local image is arm64`. The `registry` override means a broken guard
  can't push anything to Harbor. Then clean up with
  `docker rmi ollama-webui-demo:latest`.

- [ ] **Step 5: Commit**

```bash
git add ollama-webui/Justfile ollama-webui/sample-data
git commit -m "Add Justfile and sample data for the Ollama WebUI demo

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Smoke test (written before the image exists)

**Files:**
- Create: `ollama-webui/smoke-test.sh` (mode 755)

**Interfaces:**
- Consumes: the environment variables `CONTAINER_ENGINE`, `IMAGE` and `MODEL` (from the `just smoke` recipe in
  Task 1); `sample-data/field-station-report.md` and `sample-data/demo-questions.tsv` (Task 1).
- Expects from the image (Task 3):
  - Open WebUI serves `GET http://127.0.0.1:8080/health` inside the container.
  - Ollama listens on `127.0.0.1:11434` inside the container, and `ollama list` works through `exec`.
  - The entrypoint logs `[entrypoint] Model <MODEL> loaded` on success, and a line containing `[entrypoint] WARNING` on
    failure.
  - It honors `WARMUP_TIMEOUT` (seconds) and `OLLAMA_MODELS`.
- Optional overrides: `RUN_USER` (default `1000:0`), `STARTUP_TIMEOUT` (default `90`), `ANSWER_WARN_SECONDS`
  (default `30`).

- [ ] **Step 1: Write the smoke test**

Create `ollama-webui/smoke-test.sh`:

```bash
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

echo "== Main scenario: $IMAGE as $RUN_USER, no network =="
start_container "$RUN_USER"
wait_healthy
pass "Open WebUI healthy after ${HEALTHY_AFTER}s"

"$ENGINE" logs "$NAME" 2>&1 | grep -qF "[entrypoint] Model $MODEL loaded" ||
    fail "entrypoint did not report the model as loaded"
pass "model preloaded by entrypoint"

"$ENGINE" exec "$NAME" ollama list | awk 'NR > 1 { print $1 }' | grep -qxF "$MODEL" ||
    fail "ollama list does not include $MODEL"
pass "ollama list includes $MODEL"

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

echo "== Degraded scenario: unusual UID/GID, Ollama cannot load a model =="
start_container 54321:54321 -e WARMUP_TIMEOUT=5 -e OLLAMA_MODELS=/nonexistent/models
wait_healthy
pass "Open WebUI healthy without a model after ${HEALTHY_AFTER}s"
"$ENGINE" logs "$NAME" 2>&1 | grep -qF "[entrypoint] WARNING" ||
    fail "entrypoint did not log a WARNING for the missing model"
pass "entrypoint logged a WARNING"

echo "All smoke checks passed."
```

Then run `chmod 755 ollama-webui/smoke-test.sh`.

- [ ] **Step 2: Lint it**

Run `shellcheck ollama-webui/smoke-test.sh`. If shellcheck isn't installed, run `brew install shellcheck` first.
Expected: no output, exit code 0.

- [ ] **Step 3: Run it against the plain upstream image to see it fail**

From `ollama-webui/`, run:

```bash
CONTAINER_ENGINE=docker IMAGE=ghcr.io/open-webui/open-webui:v0.12.0-ollama STARTUP_TIMEOUT=120 ./smoke-test.sh
```

The image is about 4.5 GB, so the first pull is slow. Expected: `FAIL`, because upstream can't write its secret key as
UID 1000, has no baked-in model, and never logs `[entrypoint] Model ... loaded`. Any of these three is the expected
failure. Record which one occurred. If it **passes**, stop and investigate, because the test isn't testing anything.

- [ ] **Step 4: Commit**

```bash
git add ollama-webui/smoke-test.sh
git commit -m "Add VICE-like smoke test for the Ollama WebUI demo image

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Dockerfile and entrypoint

**Files:**
- Create: `ollama-webui/entrypoint.sh` (mode 755)
- Create: `ollama-webui/Dockerfile`

**Interfaces:**
- Consumes: the build argument `MODEL` (passed by `just build`); the smoke-test expectations listed in Task 2.
- Produces:
  - Image environment variables `SANDBOX_MODEL`, `OLLAMA_HOST=127.0.0.1:11434` and `OLLAMA_MODELS=/opt/ollama/models`.
  - Entrypoint log lines `[entrypoint] Model <model> loaded` and `[entrypoint] WARNING: ...`.
  - The `WARMUP_TIMEOUT` environment variable (default 60).

- [ ] **Step 1: Write the entrypoint**

Create `ollama-webui/entrypoint.sh`:

```bash
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

log "Starting Open WebUI"
exec bash /app/backend/start.sh "$@"
```

Then run `chmod 755 ollama-webui/entrypoint.sh` and `shellcheck ollama-webui/entrypoint.sh`. Expected: no output.

- [ ] **Step 2: Write the Dockerfile**

Create `ollama-webui/Dockerfile`:

```dockerfile
# CyVerse AI Sandbox demo: Open WebUI + Ollama with a small model baked in,
# run as a VICE app from the AI Sandboxes UI. Fully offline at runtime.
FROM ghcr.io/open-webui/open-webui:v0.12.0-ollama

ARG MODEL=llama3.2:3b

ENV OLLAMA_MODELS=/opt/ollama/models \
    OLLAMA_HOST=127.0.0.1:11434 \
    OLLAMA_KEEP_ALIVE=-1 \
    OLLAMA_BASE_URL=http://127.0.0.1:11434 \
    SANDBOX_MODEL=${MODEL} \
    DEFAULT_MODELS=${MODEL} \
    WEBUI_AUTH=False \
    WEBUI_NAME="CyVerse AI Sandbox" \
    ENABLE_OPENAI_API=False \
    OFFLINE_MODE=True \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    USE_OLLAMA_DOCKER=false

# Pull the chat model at build time so the sandbox never downloads anything.
RUN set -eu; \
    mkdir -p "$OLLAMA_MODELS"; \
    ollama serve > /tmp/ollama-build.log 2>&1 & \
    serve_pid=$!; \
    for _ in $(seq 1 30); do curl -sf "http://$OLLAMA_HOST/api/version" > /dev/null && break; sleep 1; done; \
    ollama pull "$MODEL"; \
    kill "$serve_pid"; \
    rm -rf /tmp/ollama-build.log /root/.ollama; \
    chmod -R a+rX "$OLLAMA_MODELS"

# VICE may run us as any user. Only directories need to be writable; changing
# just them keeps the layer small (the baked caches are already world-readable).
RUN find /app/backend/data -type d -exec chmod a+rwx {} +

COPY entrypoint.sh /usr/local/bin/sandbox-entrypoint.sh
RUN chmod 0755 /usr/local/bin/sandbox-entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/sandbox-entrypoint.sh"]
# Clear upstream's CMD so it isn't passed to start.sh as uvicorn arguments.
CMD []
```

- [ ] **Step 3: Build a native image for local testing**

From `ollama-webui/`, run `just PLATFORM=linux/arm64 build`. This machine is an arm64 Mac, and running amd64 under
emulation is too slow for a meaningful smoke test.

Expected: the build succeeds, and the `ollama pull` step shows a download progress bar ending in `success`.

Then run `docker image inspect --format '{{.Size}}' ollama-webui-demo:latest`. Expected: roughly 6–7 GB.

- [ ] **Step 4: Run the smoke test to verify it passes**

Run `just smoke` (or `STARTUP_TIMEOUT=150 just smoke` if Docker Desktop has little memory; give it at least 8 GB).

Expected: every line is `PASS:`, ending in `All smoke checks passed.`

If a keyword check fails, check whether the answer is actually wrong or just phrased differently (for example
"one hundred forty-eight"). Fix the question wording in `demo-questions.tsv` only if the question was ambiguous.
**Never loosen a keyword to make a wrong answer pass.**

- [ ] **Step 5: Run the lint recipe**

Run `just lint`. Expected: no output, exit code 0.

- [ ] **Step 6: Build the amd64 release image and check the push guard**

1. Run `just build`. This is an amd64 build under emulation on this Mac and takes about 10–20 minutes.
2. Run `docker image inspect --format '{{.Architecture}}' ollama-webui-demo:latest`. Expected: `amd64`.
3. Run `just --dry-run push`. Expected: it prints the push script without running it.

Don't push. Pushing to Harbor is done only when the user explicitly asks.

- [ ] **Step 7: Commit**

```bash
git add ollama-webui/Dockerfile ollama-webui/entrypoint.sh
git commit -m "Add Ollama + Open WebUI demo image with offline model and VICE entrypoint

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: README with DE registration, demo script and checklist

**Files:**
- Create: `ollama-webui/README.md`

**Interfaces:**
- Consumes: the Justfile recipes (Task 1), the questions and keywords in `demo-questions.tsv` (Task 1), and the image
  name and port (Task 3).

- [ ] **Step 1: Write the README**

Create `ollama-webui/README.md`:

````markdown
# CyVerse AI Sandbox Demo (Ollama + Open WebUI)

A VICE app for demonstrating the AI Sandboxes UI. A small LLM (`llama3.2:3b`) runs entirely inside the analysis,
with Open WebUI as the chat interface. Nothing is downloaded at runtime, nothing leaves the session, and everything
(chats, uploads, the document index) disappears when the analysis ends.

## Build

Requires [`just`](https://github.com/casey/just) and either Podman or Docker. Podman is used if installed; otherwise
Docker is used. To force one, set `CONTAINER_ENGINE=docker` or `CONTAINER_ENGINE=podman`.

```bash
just build   # build ollama-webui-demo:latest for linux/amd64 (what VICE runs)
just smoke   # run the smoke test: no network, non-root, checks the model and answers
just push    # push to harbor.cyverse.org/de/ollama-webui-demo:<today's date> (amd64 only)
just run     # try it at http://localhost:8080
```

Other models: `just MODEL=qwen2.5:3b build smoke`.

**Apple Silicon:** `just build` builds amd64 under emulation and takes 10–20 minutes, and running that image locally
is very slow. For local testing, use `just PLATFORM=linux/arm64 build smoke`, then run `just build` again before
`just push`. The push recipe refuses non-amd64 images.

## Registering the app in the DE

Create an interactive (VICE) app with these settings:

| Setting | Value |
|---|---|
| Image | `harbor.cyverse.org/de/ollama-webui-demo` |
| Tag | the date tag printed by `just push` |
| Container port | `8080` |
| Minimum CPU | 4 |
| Minimum memory | 12 GB |
| Name | CyVerse AI Sandbox |

No inputs or parameters are needed.

## Before every demo

- [ ] Pre-pull the image onto the VICE nodes, because a cold pull of this ~6–7 GB image ruins the startup time:
      ```sh
      curl -H "Authorization: Bearer $(./bin/vice-operator-token --config ~/.vo.qa.conf)" \
           -H "Content-Type: application/json" -X PUT \
           -d '{"images": ["harbor.cyverse.org/de/ollama-webui-demo:<tag>"]}' \
           https://vice-api.cyverse.run/image-cache
      ```
      (`vice-operator-token` is in the `app-exposer` repo.)
- [ ] Launch the app once in QA and run the full script below, including the upload.
- [ ] Have `sample-data/field-station-report.md` on the presenting laptop.
- [ ] Confirm the answers show citations, and that relaunching gives an empty chat history.

## Demo script (~5 minutes)

1. **Launch (30 s).** In the AI Sandboxes UI, launch **CyVerse AI Sandbox**. Point out the session card and the
   time-limit countdown.
2. **Private chat (1 min).** Ask something general, such as *"Explain what a sky island is in two sentences."*
   Talking point: *this model runs inside this session, with no external AI service and nothing sent anywhere.*
3. **Your data (2 min).** Drag `field-station-report.md` into the chat box, then ask:

   | Question | Expected answer |
   |---|---|
   | Which site had the highest number of pollinator visits? | Cholla Flats |
   | How many soil cores were collected in total? | 148 |
   | Who led the night survey on April 19? | Dr. Amara Okonkwo |
   | What piece of equipment failed at Mesquite Draw? | The anemometer |

   Click a citation to show the answer came from the document. The report is made up, so the model can't
   have known these facts.
4. **Containment (1 min).** *Everything you just saw — the upload, the chat, the index — exists only in this
   session.* End the analysis, relaunch, and show the empty history.
5. **Close (30 s).** *The same pattern works for any model or tool a researcher wants to try safely.*

The questions also live in `sample-data/demo-questions.tsv`, and `just smoke` checks that the model answers them
correctly.

## How it works

- `Dockerfile` extends `ghcr.io/open-webui/open-webui:v0.12.0-ollama`, pulls the model into `/opt/ollama/models` at
  build time, and sets offline and single-user mode (`WEBUI_AUTH=False`; vice-proxy handles login).
- `entrypoint.sh` picks writable paths for whatever user VICE runs as, starts Ollama on localhost, preloads the model
  so the first answer is fast, and then runs upstream's `start.sh`. If the model can't load within `WARMUP_TIMEOUT`
  seconds (default 60), it logs a `WARNING` and starts the UI anyway.
````

- [ ] **Step 2: Check the README against the files**

Check that every recipe the README mentions appears in `just --list`. Check that the four questions match
`demo-questions.tsv` word for word:
`cut -f1 ollama-webui/sample-data/demo-questions.tsv | grep -v '^#'`

- [ ] **Step 3: Commit**

```bash
git add ollama-webui/README.md
git commit -m "Add README with DE registration, demo script, and pre-demo checklist

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5 (stretch, 1-hour time box): Spike on a pre-indexed "Demo Library"

This is a spike. The output is a recommendation; keep code only if every criterion below is met.

**Question:** With `WEBUI_AUTH=False`, can the entrypoint reliably get an API token after Open WebUI starts, then
create a knowledge collection named "Demo Library" from `/opt/sandbox-data/field-station-report.md`?

- [ ] **Step 1: Investigate.** In a running container (`just run`, as UID 1000), read the Open WebUI v0.12.0
  source in `/app/backend/open_webui/routers/auths.py` and `routers/knowledge.py`. Find out how the frontend gets a
  token when auth is disabled, then try that flow with `curl` from `just shell`.
- [ ] **Step 2: Decide.**
  - **Keep it** only if it takes no more than about 30 lines of bash, works on every fresh start, and `just smoke`
    still passes. If so, add a smoke check that `GET /api/v1/knowledge/` lists "Demo Library", implement it, and
    commit.
  - **Otherwise,** discard the code and record the finding in a short "Pre-indexed library" note in the README.
    The live upload stays the demo path.
