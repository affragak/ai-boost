#!/bin/bash
set -e
sudo chown -R ubuntu:ubuntu /home/ubuntu/.cloudflared /home/ubuntu/.ollama
exec sudo /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
