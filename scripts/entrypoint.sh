#!/bin/bash
set -e
sudo chown -R ubuntu:ubuntu /home/ubuntu/.cloudflared /home/ubuntu/.ollama /home/ubuntu/.local/share/open-webui
exec sudo \
    WEBUI_SECRET_KEY="${WEBUI_SECRET_KEY}" \
    CLOUDFLARED_TUNNEL_ID="${CLOUDFLARED_TUNNEL_ID}" \
    /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
