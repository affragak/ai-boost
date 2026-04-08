# podman build --format docker -t ai .
FROM nvidia/cuda:12.8.0-runtime-ubuntu24.04

# 1. System Installations (Run as Root)
COPY --from=jdxcode/mise /usr/local/bin/mise /usr/local/bin/
COPY --from=ghcr.io/astral-sh/uv:0.11.4 /uv /usr/local/bin/uv

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    sudo zstd libatomic1 supervisor nvtop git curl vim zsh \
    && rm -rf /var/lib/apt/lists/*

ARG OLLAMA_VERSION=0.20.3
RUN ARCH=$(uname -m); \
    case "$ARCH" in \
        x86_64)  OLLAMA_ARCH="amd64" ;; \
        aarch64) OLLAMA_ARCH="arm64" ;; \
        *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/ollama-linux-${OLLAMA_ARCH}.tar.zst" \
        | zstd -d -c | tar -x -C /usr/local

RUN curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" > /etc/apt/sources.list.d/cloudflared.list && \
    apt-get update && apt-get install -y cloudflared && \
    rm -rf /var/lib/apt/lists/*

RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --system --break-system-packages open-webui==0.8.12

# 2. System Configuration & Log Prep (Run as Root)
COPY supervisord/ollama.conf      /etc/supervisor/conf.d/ollama.conf
COPY supervisord/open-webui.conf  /etc/supervisor/conf.d/open-webui.conf
COPY supervisord/cloudflared.conf /etc/supervisor/conf.d/cloudflared.conf

COPY scripts/pull-models /usr/local/bin/pull-models
RUN chmod +x /usr/local/bin/pull-models

COPY scripts/create-user /usr/local/bin/create-user
RUN chmod +x /usr/local/bin/create-user

COPY scripts/fix-model-access /usr/local/bin/fix-model-access
RUN chmod +x /usr/local/bin/fix-model-access

COPY scripts/healthcheck /usr/local/bin/healthcheck
RUN chmod +x /usr/local/bin/healthcheck

COPY scripts/backup /usr/local/bin/backup
RUN chmod +x /usr/local/bin/backup

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

RUN echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# PREPARE LOGS: Do this as root BEFORE switching users
RUN touch /var/log/cloudflared.log /var/log/cloudflared.err /var/log/open-webui.log /var/log/open-webui.err && \
    chown ubuntu:ubuntu /var/log/cloudflared.* /var/log/open-webui.* && \
    mkdir -p /home/ubuntu/.local/share/open-webui && \
    chown -R ubuntu:ubuntu /home/ubuntu/


# 3. User-Level Setup (Switch to Ubuntu)
USER ubuntu
WORKDIR /home/ubuntu

# Set environment for mise and WebUI
ENV PATH="/home/ubuntu/.local/share/mise/shims:$PATH" \
    DATA_DIR="/home/ubuntu/.local/share/open-webui" \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all \
    OLLAMA_BASE_URL="http://127.0.0.1:11434"

COPY --chown=ubuntu:ubuntu mise.toml /home/ubuntu/.config/mise/config.toml
RUN --mount=type=cache,uid=1000,gid=1000,target=/home/ubuntu/.cache/mise \
    mise install

# Install Claude Code via mise-managed node
RUN mise exec -- npm install -g @anthropic-ai/claude-code

RUN echo 'eval "$(mise activate bash)"' >> /home/ubuntu/.bashrc && \
    echo 'eval "$(mise activate zsh)"'  >> /home/ubuntu/.zshrc

# 4. Runtime Config
VOLUME /home/ubuntu/.ollama
VOLUME /home/ubuntu/.cloudflared
EXPOSE 8080 11434

CMD ["/usr/local/bin/entrypoint.sh"]
