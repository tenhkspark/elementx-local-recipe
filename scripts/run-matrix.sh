#!/usr/bin/env bash
# run-matrix.sh — launch a private Conduit (Matrix homeserver) in Docker.
# Designed for a Mac mini + colima, but any Docker host works.
#
# Usage:
#   ./run-matrix.sh            # first run creates ./conduwuit.toml from the template if missing
#
# Layout (all under the directory this script lives in):
#   ./conduwuit.toml   homeserver config (edit server_name + registration_token)
#   ./db/              RocksDB data directory (bind-mounted into the container)
#
# The server listens on 127.0.0.1:8008 only. TLS is terminated by
# `tailscale serve` in front of it (see docs in README.md).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${CONDUIT_IMAGE:-matrixconduit/matrix-conduit:v0.10.15}"

if [ ! -f "$HERE/conduit.toml" ]; then
  echo "conduit.toml not found — copy it from conduit.toml.example and edit server_name first." >&2
  exit 1
fi

mkdir -p "$HERE/db"

docker rm -f matrix-server 2>/dev/null || true
exec docker run -d \
  --name matrix-server \
  --restart always \
  -p 127.0.0.1:8008:8008 \
  -e CONDUIT_CONFIG=/etc/matrix-conduit/conduwuit.toml \
  -v "$HERE/db":/var/lib/matrix-conduit \
  -v "$HERE/conduit.toml":/etc/matrix-conduit/conduwuit.toml:ro \
  "$IMAGE"
