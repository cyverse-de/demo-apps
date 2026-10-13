# CyVerse AI Sandbox Demo: Ollama + Open WebUI

**Date:** 2026-10-13
**Status:** Draft, pending review

## Purpose

A VICE app, launched from the AI Sandboxes UI, that shows off contained AI exploration. It runs a local LLM (Ollama)
with a chat UI (Open WebUI) entirely inside one analysis session. A presenter can chat privately with the model and ask
questions about their own documents, then end the session and show that nothing persists or leaves the sandbox.

**Audience:** live demos for stakeholders (funders, leadership, conferences). Reliability and fast startup matter
more than features.

## Requirements

| # | Requirement |
|---|---|
| R1 | Launches from the AI Sandboxes UI as a standard VICE app (one container, one HTTP port behind vice-proxy). |
| R2 | CPU only; target pod of 4 CPUs / 12 GB memory minimum. |
| R3 | Fully offline at runtime: chat model and embedding model are baked into the image; no outbound network calls. |
| R4 | No login or setup screen inside the app (vice-proxy already authenticates the user). |
| R5 | Usable chat within ~60 s of the pod starting on a node with the image cached. |
| R6 | A scripted question about a sample document returns a correct, cited answer in under ~30 s. |
| R7 | Runs as an arbitrary non-root user. |
| R8 | Builds with either Podman or Docker through a Justfile. |

## Assumptions

- VICE nodes are `linux/amd64`.
- The demo image will be pre-pulled onto the VICE nodes before each demo (the image is ~6–7 GB, and a cold pull would
  blow the startup budget).
- Session data (chats, uploads, vector index) is supposed to be lost when the analysis ends. That is the containment
  story, not a bug.

## Approach

Extend the official `ghcr.io/open-webui/open-webui:<version>-ollama` image, which already bundles Ollama and Open WebUI
in one container. Rejected alternatives:

- **Building from a Python base:** more control, but we would own Open WebUI's heavy dependency stack.
- **Separate Ollama and Open WebUI containers:** VICE apps are effectively one app container behind vice-proxy.

## Repository layout

```
ollama-webui/
  Dockerfile
  Justfile
  entrypoint.sh
  smoke-test.sh
  sample-data/
    field-station-report.md
    <open-access paper>.pdf      # only if its license permits redistribution
  README.md                      # build, DE registration, demo script, pre-demo checklist
```

## Image build (`Dockerfile`)

1. `FROM ghcr.io/open-webui/open-webui:<pinned-version>-ollama`, pinned to an exact tag and never a floating `:ollama`.
2. `ENV OLLAMA_MODELS=/opt/ollama/models` so the models live outside `/root`.
3. `ARG MODEL=llama3.2:3b`. At build time, start `ollama serve` in the background, `ollama pull $MODEL`, then stop it.
4. Pre-download the embedding model `sentence-transformers/all-MiniLM-L6-v2` into Open WebUI's embedding cache path.
5. Runtime environment:

   | Variable | Value | Reason |
   |---|---|---|
   | `WEBUI_AUTH` | `False` | Single-user mode (R4) |
   | `OFFLINE_MODE` | `True` | No update checks or downloads (R3) |
   | `HF_HUB_OFFLINE` | `1` | No Hugging Face fetches (R3) |
   | `ENABLE_OPENAI_API` | `False` | Show only the local model |
   | `DEFAULT_MODELS` | `$MODEL` | No model picking on stage |
   | `WEBUI_NAME` | `CyVerse AI Sandbox` | Branding |
   | `OLLAMA_HOST` | `127.0.0.1:11434` | Ollama is not exposed outside the pod |
   | `OLLAMA_KEEP_ALIVE` | `-1` | Keep the model loaded for the whole session |

6. `chmod -R a+rwX` on the Open WebUI data directory and the Ollama home only (R7).
7. `EXPOSE 8080`. `ENTRYPOINT` is `entrypoint.sh`.

The Dockerfile uses only syntax that both Podman and Docker support: no `RUN --mount` and no other BuildKit-only
features.

**Expected size:** ~6–7 GB.

## Build tooling (`Justfile`)

Engine selection, which can be overridden with `CONTAINER_ENGINE`:

```just
engine := env("CONTAINER_ENGINE", `command -v podman >/dev/null 2>&1 && echo podman || echo docker`)
```

| Recipe | Action |
|---|---|
| `build` | Build with `--platform linux/amd64`, tagged with `<date>` and `latest` |
| `push` | Push to `harbor.cyverse.org/de/ollama-webui-demo` |
| `run` | Run locally on `localhost:8080` as a non-root user |
| `shell` | Open an interactive shell in the image |
| `smoke` | Run `smoke-test.sh` |
| `lint` | Run `shellcheck` on the shell scripts |

`MODEL` and `TAG` are overridable variables. The README notes that building on Apple Silicon goes through emulation
and the model-pull step can take 10–20 minutes.

## Runtime (`entrypoint.sh`)

1. If `DATA_DIR` is not writable, fall back to `/tmp/webui-data`.
2. Start `ollama serve` in the background.
3. Poll Ollama for up to 60 s. Once it responds, send a one-token generate request to load the model into memory
   before the first real question. On timeout, log a clear error and continue, so the UI still comes up and shows a
   "no models" state instead of hanging.
4. `exec` upstream's `start.sh`, so Open WebUI runs as the main process and receives VICE's stop/terminate signal.

| What | Location | Lifetime |
|---|---|---|
| Chat model and embedding model | `/opt/ollama/models` and the image cache | Baked into the image |
| Chats, uploads, vector index | `$DATA_DIR` | This session only |

**DE app registration:** container port 8080, minimum 4 CPUs and 12 GB of memory.

## Sample data and demo script

**v1:** the presenter uploads the sample document from their laptop during the demo (Open WebUI uploads go through
the browser). The upload itself is part of the story: the document visibly goes *into* the sandbox.

**Stretch goal (start with a time-boxed spike):** at startup, create a pre-indexed "Demo Library" knowledge collection
through Open WebUI's API from files baked into the image. This depends on getting an API token while `WEBUI_AUTH=False`.
Drop it if the spike shows it is fragile.

**Content:**
- `field-station-report.md`: a short, made-up report (~2 pages) with specific, checkable facts (site names, dates,
  sample counts). Because the facts are invented, a correct answer has to come from the document.
- Optionally, one open-access paper relevant to CyVerse, included only after confirming its license (e.g. CC-BY)
  permits redistribution.
- No CSV or tabular data. Document Q&A over tables is unreliable with a 3B model.

**Demo script (~5 min, in the README with exact prompts and expected answers):**
1. Launch from the AI Sandboxes UI and show the session card and the time-limit countdown (30 s).
2. Ask a general question: the model runs inside this session, with no external API (1 min).
3. Upload the field report and ask 2–3 scripted questions, showing the citations (2 min).
4. Containment: end the analysis, relaunch, and show the clean slate (1 min).
5. Close: the same pattern works for any model or tool a researcher wants to try safely (30 s).

## Testing

**`smoke-test.sh` (`just smoke`), for both Podman and Docker:**
1. Run the container detached with `--user 1000:0 --network none` (checks R3 and R7).
2. Poll `/health` with `exec curl` inside the container. Fail if it is not ready within 90 s, and report the measured
   startup time (R5).
3. Check that `ollama list` shows `$MODEL`.
4. For each scripted question, send it to Ollama with the field report included in the prompt, and check that the
   answer contains the expected keyword (R6, model quality). This does not exercise Open WebUI's document Q&A pipeline.
5. Always remove the container.

**Static checks:** `shellcheck` via `just lint`.

**Manual checklist before each demo (in the README):** pre-pull the image onto the VICE nodes with app-exposer's
image-cache endpoint; run the full script in QA, including the UI upload and the citations; confirm the relaunch shows
a clean slate.

## Out of scope

- GPU support.
- CI image builds. The image is large and rarely rebuilt, so builds are manual (`just build && just smoke && just push`).
- Mounting Data Store files into the session for chat.
- CSV or tabular analysis.

## Open items to resolve during implementation

- Pin the exact Open WebUI image tag, and confirm the paths in that version: the data directory, the embedding cache
  directory, and the location of `start.sh`.
- Confirm that the pinned image's `start.sh` does not also start its own Ollama, which would conflict with the one
  `entrypoint.sh` starts (upstream controls this with `USE_OLLAMA_DOCKER`).
- Confirm that `curl` is available in the base image for the smoke test.
- Confirm the license of the candidate open-access paper.
- Stretch-goal spike: API token for creating the knowledge collection in no-auth mode.
