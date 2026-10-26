#!/usr/bin/env python3
"""serve-wellknown.py — serve /.well-known/matrix/client for homeserver discovery.

Element X asks the HOSTNAME YOU TYPED for /.well-known/matrix/client. If it
gets a valid homeserver base_url there, login works; without it, some clients
fall back to the hostname itself (which also works with tailscale serve),
but serving the file explicitly is the reliable path.

Layout:
    wellknown-root/matrix/client     <- JSON file (contents below)

Then serve the directory on 127.0.0.1:9111 (any static file server works):

    python3 serve-wellknown.py --root ./wellknown-root --port 9111

and point `tailscale serve` at it:
    tailscale serve --bg --https=443 --set-path=/.well-known http://127.0.0.1:9111/.well-known
"""
import argparse
import http.server
import json
import os

class CORSHandler(http.server.SimpleHTTPRequestHandler):
    """Matrix spec: well-known responses SHOULD carry CORS headers."""
    def end_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="./wellknown-root")
    ap.add_argument("--port", type=int, default=9111)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--homeserver-url", required=True,
                    help="public base URL clients should use, e.g. https://matrix.example.ts.net")
    args = ap.parse_args()

    client_dir = os.path.join(args.root, "matrix")
    os.makedirs(client_dir, exist_ok=True)
    payload = {"m.homeserver": {"base_url": args.homeserver_url}}
    with open(os.path.join(client_dir, "client"), "w") as f:
        json.dump(payload, f)
    print(f"serving {args.root} on {args.bind}:{args.port} (base_url={args.homeserver_url})")
    http.server.ThreadingHTTPServer(
        (args.bind, args.port), lambda *a, **kw: CORSHandler(*a, directory=args.root, **kw)
    ).serve_forever()

if __name__ == "__main__":
    main()
