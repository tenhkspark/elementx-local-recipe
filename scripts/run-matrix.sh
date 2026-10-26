#!/usr/bin/env bash
# run-matrix.sh — launch the Tuwunel homeserver (Conduit lineage) in Docker.
# Designed for a Mac mini + colima, but any Docker host works.
#
# Usage:
#   ./run-matrix.sh            # first run: create ./tuwunel.toml from the template if missing
#
# Layout (all under the directory this script lives in):
#   ./tuwunel.toml   homeserver config (edit server_name + registration_token)
#   ./db/            RocksDB data directory (bind-mounted into the container)
#
# The server listens on 127.0.0.1:8008 only. TLS is terminated by
# `tailscale serve` in front of it (see README.md).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${HS_IMAGE:-ghcr.io/matrix-construct/tuwunel:latest}"

if [ ! -f "$HERE/tuwunel.toml" ]; then
  echo "tuwunel.toml not found — copy it from tuwunel.toml.example and edit server_name first." >&2
  exit 1
fi

mkdir -p "$HERE/db"

docker rm -f matrix-server 2>/dev/null || true
exec docker run -d \
  --name matrix-server \
  --restart always \
  -p 127.0.0.1:8008:8008 \
  -e TUWUNEL_CONFIG=/etc/tuwunel.toml \
  -v "$HERE/db":/var/lib/tuwunel \
  -v "$HERE/tuwunel.toml":/etc/tuwunel.toml:ro \
  "$IMAGE"
