#!/usr/bin/env bash
# LAB ONLY: start the edge forwarder on the Mac (ports 80/443 -> the VM at 10.30.0.10)
set -euo pipefail
cd "$(dirname "$0")"
docker rm -f edge >/dev/null 2>&1 || true
docker run -d --name edge --restart unless-stopped --network deploynet --ip 10.30.0.5 \
  -p 80:80 -p 443:443 -v "$PWD/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:alpine
