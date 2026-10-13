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
- [ ] Have `sample-data/field-station-report.md` on the presenting laptop (for the live upload), or plan to use the
      pre-indexed **Demo Library** instead (see step 3).
- [ ] Confirm the answers show citations, and that relaunching gives an empty chat history.

## Demo script (~5 minutes)

1. **Launch (30 s).** In the AI Sandboxes UI, launch **CyVerse AI Sandbox**. Point out the session card and the
   time-limit countdown.
2. **Private chat (1 min).** Ask something general, such as *"Explain what a sky island is in two sentences."*
   Talking point: *this model runs inside this session, with no external AI service and nothing sent anywhere.*
3. **Your data (2 min).** Drag `field-station-report.md` into the chat box, or type `#` and pick **Demo Library**
   (the same report, indexed at startup), then ask:

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
- `seed-library.sh` runs in the background at startup and indexes `/opt/sandbox-data` into a **Demo Library**
  knowledge collection. If it fails it logs a `WARNING` and the live upload still works.
- `entrypoint.sh` picks writable paths for whatever user VICE runs as, starts Ollama on localhost, preloads the model
  so the first answer is fast, and then runs upstream's `start.sh`. If the model can't load within `WARMUP_TIMEOUT`
  seconds (default 60), it logs a `WARNING` and starts the UI anyway.
