#!/usr/bin/env bash
# serve-paths.sh — publish the Matrix endpoints through `tailscale serve`.
#
# Run AFTER the homeserver answers on 127.0.0.1:8008 and the well-known
# file server answers on 127.0.0.1:9111.
#
#   443  /_matrix      -> 127.0.0.1:8008/_matrix      (client API)
#   443  /.well-known  -> 127.0.0.1:9111/.well-known  (homeserver discovery)
#
# Clients then use https://<your-host.ts.net> as the homeserver URL.
#
# NOTE: re-run the status check after every change — successive `serve --bg`
# calls can race, and a lost path is re-added by simply running this script again.
set -euo pipefail

TS="${TS:-tailscale}"
command -v "$TS" >/dev/null || TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale

"$TS" serve --bg --https=443 --set-path=/_matrix http://127.0.0.1:8008/_matrix
sleep 2
"$TS" serve --bg --https=443 --set-path=/.well-known http://127.0.0.1:9111/.well-known
sleep 2

echo "--- current serve status ---"
"$TS" serve status

echo "--- verify ---"
curl -sf -m 8 https://localhost/_matrix/client/versions >/dev/null && echo "443 /_matrix: OK" || echo "443 /_matrix: FAIL (check ACL: other tailnet devices need tcp:443 to this host)"
curl -sf -m 8 https://localhost/.well-known/matrix/client && echo
