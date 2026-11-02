#!/usr/bin/env bash
# Fixture test for diagram-gate.sh.
#
# The gate reads only the pull request's file list from the API, so each case
# serves that list from a local stub and runs the real script against it. The
# stub is stdlib Python, so neither a token nor the network is needed.
#
#   bash scripts/test-diagram-gate.sh
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/diagram-gate.sh"
dir="$(mktemp -d)"

# Page 1 serves the current case's files; every later page is empty, which is
# where the script stops paginating. Port 0 lets the OS pick a free port.
python3 -I - "$dir" <<'PY' &
import http.server, json, pathlib, sys, urllib.parse
root = pathlib.Path(sys.argv[1])
class Stub(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        page = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)["page"][0]
        names = (root / "files").read_text().split() if page == "1" else []
        body = json.dumps([{"filename": n} for n in names]).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Stub)
(root / "port.tmp").write_text(str(server.server_port))
(root / "port.tmp").rename(root / "port")
server.serve_forever()
PY
stub=$!
# Disowned so its kill at exit prints no job notice.
disown "$stub"
trap 'kill "$stub" 2>/dev/null; rm -rf "$dir"' EXIT
for _ in $(seq 50); do [ -f "$dir/port" ] && break; sleep 0.1; done
api="http://127.0.0.1:$(cat "$dir/port")"
fails=0

# want is "pass" or "fail"; a failing case must also print the given message.
expect() {
  local name="$1" want="$2" files="$3" body="${4:-}" message="${5:-}" out got
  echo "$files" > "$dir/files"
  if out="$(GH_TOKEN=x REPO=o/r PR_NUMBER=1 GITHUB_API_URL="$api" PR_BODY="$body" \
    bash "$script" 2>&1)"; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ] && [[ "$out" == *"$message"* ]]; then
    echo "ok    $name"
  else
    echo "FAIL  $name: want $want${message:+ with \"$message\"}, got $got:"
    echo "      ${out//$'\n'/$'\n'      }"
    fails=$((fails + 1))
  fi
}

ticked='- [x] Architecture unchanged, or the diagrams moved with it <!-- diagram-gate -->'
unticked='- [ ] Architecture unchanged, or the diagrams moved with it <!-- diagram-gate -->'

expect "architecture + .tldr passes" pass "docs/ARCHITECTURE.md docs/diagrams/system.tldr"
expect "architecture + .d2 passes" pass "docs/ARCHITECTURE.md docs/diagrams/system.d2"
expect "architecture + .svg, waiver unticked, fails" fail \
  "docs/ARCHITECTURE.md docs/diagrams/system.svg" "$unticked" "no .d2 or .tldr source changed"
expect "architecture, waiver ticked, passes" pass "docs/ARCHITECTURE.md" "$ticked"
expect "no architecture file passes" pass "README.md docs/diagrams/system.svg"

[ "$fails" -eq 0 ] || { echo "$fails case(s) failed"; exit 1; }
echo "all cases passed"
