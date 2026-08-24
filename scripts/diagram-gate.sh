#!/usr/bin/env bash
# Notice a pull request that changes the architecture and leaves the pictures behind.
#
# Called by .github/workflows/diagram-gate.yml on pull_request. Reads only the
# API — the caller's tree is never checked out.
#
# Required environment:
#   GH_TOKEN    a token with pull-requests:read on $REPO
#   REPO        owner/name
#   PR_NUMBER   the pull request being graded
# Optional:
#   PR_BODY     the pull request body, which carries the waiver checkbox
#   ARCH_GLOBS  newline-separated fnmatch patterns naming architecture files
#
# The test: this PR touched a file that describes the system's shape, and no
# `.d2` moved with it. A diagram that stops matching the system is worse than no
# diagram — it reads as current — and the moment it goes stale is the moment
# nobody is looking. So the check is here, not in a reviewer's memory.
#
# The escape is the last checkbox of the rendered pull request template, marked
# `<!-- diagram-gate -->`. Ticking it is the author saying the shape did not
# actually change, in writing, on the PR. Docs, wording, and a dependency bump
# in a launch file are all real cases; the box is how they pass.
#
# curl and python3, not gh: this runs on the self-hosted fleet as well as on
# hosted runners, and the fleet image ships neither gh nor jq.
set -euo pipefail

: "${GH_TOKEN:?}" "${REPO:?}" "${PR_NUMBER:?}"
API="${GITHUB_API_URL:-https://api.github.com}"

api_get() {
  curl -fsSL \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$API/$1"
}

# The file list is paginated. A PR wide enough to exceed this is already past
# the "one logical change" rule, and the first 300 files are enough to decide.
files=""
for page in 1 2 3; do
  batch="$(api_get "repos/$REPO/pulls/$PR_NUMBER/files?per_page=100&page=$page" \
    | python3 -c 'import json,sys; print("\n".join(f["filename"] for f in json.load(sys.stdin)))')"
  [ -n "$batch" ] || break
  files="$files$batch"$'\n'
done

FILES="$files" python3 <<'PY'
import fnmatch
import os
import sys

DEFAULT_GLOBS = """
*ARCHITECTURE.md
*docs/adr/*.md
*.launch.py
*/launch/*.py
*docker-compose*.yml
"""

# fnmatch's `*` crosses directory separators, so one leading `*` is enough to
# reach a file at any depth. Patterns are one per line; a repo widens the set by
# passing its own through the workflow input.
globs = [line.strip() for line in (os.environ.get("ARCH_GLOBS") or DEFAULT_GLOBS).splitlines() if line.strip()]
files = [line.strip() for line in os.environ["FILES"].splitlines() if line.strip()]
body = os.environ.get("PR_BODY") or ""

architecture = sorted({f for f in files for g in globs if fnmatch.fnmatch(f, g)})
diagrams = sorted(f for f in files if f.endswith(".d2"))

if not architecture:
    print("ok: no architecture file changed")
    sys.exit(0)

print("architecture files in this pull request:")
for one in architecture:
    print(f"  {one}")

if diagrams:
    print("\nok: a diagram source moved with them:")
    for one in diagrams:
        print(f"  {one}")
    sys.exit(0)

waived = any(
    "<!-- diagram-gate -->" in line and "- [x]" in line.lower()
    for line in body.splitlines()
)
if waived:
    print("\nok: the author ticked the diagram waiver — the shape did not change")
    sys.exit(0)

print(
    "\nno .d2 source changed, and the diagram checkbox in the pull request body"
    "\nis not ticked.\n"
    "\nEither update the diagram that covers this change and re-render it:\n"
    "\n    ./docs/diagrams/render.sh\n"
    "\nor tick the last checklist box to say the architecture did not move.",
    file=sys.stderr,
)
sys.exit(1)
PY
