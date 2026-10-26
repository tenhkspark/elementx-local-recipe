#!/usr/bin/env bash
# create-account.sh — create a Matrix account on a token-gated Conduit server.
#
# Element X can only LOG IN, not register, on servers without a managed
# account service — so accounts are created once via the client API with the
# registration token, then used in Element X like any other account.
#
# Usage:
#   ./create-account.sh https://matrix.example.ts.net alice
#   HOMESERVER=... USERNAME=... REGISTRATION_TOKEN=... ./create-account.sh   # non-interactive
#
# The token is read from REGISTRATION_TOKEN or prompted (not stored by this script).
set -euo pipefail

HS="${1:-${HOMESERVER:?usage: create-account.sh <homeserver-url> <username>}}"
USER="${2:-${USERNAME:?missing username}}"
TOKEN="${REGISTRATION_TOKEN:-}"

if [ -z "$TOKEN" ]; then
  read -r -s -p "registration token: " TOKEN
  echo
fi

PASSWORD="${PASSWORD:-}"
if [ -z "$PASSWORD" ]; then
  read -r -s -p "new password for @$USER: " PASSWORD
  echo
fi

resp=$(curl -sf -X POST "$HS/_matrix/client/v3/register" \
  -H 'Content-Type: application/json' \
  -d "$(cat <<EOF
{"username": "$USER", "password": "$PASSWORD", "inhibit_login": true,
 "auth": {"type": "m.login.registration_token", "token": "$TOKEN"}}
EOF
)")

echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("created user_id:", d.get("user_id", d))'
echo "Now log in with Element X: homeserver = $HS, username = $USER"
