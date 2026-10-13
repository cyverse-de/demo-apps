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
