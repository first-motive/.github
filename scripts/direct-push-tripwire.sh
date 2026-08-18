#!/usr/bin/env bash
# Notice a commit that reached the default branch without a pull request.
#
# Called by .github/workflows/direct-push-tripwire.yml on push to the default
# branch. Reads only the API — the caller's tree is never checked out.
#
# Required environment:
#   GH_TOKEN  a token with issues:write and pull-requests:read on $REPO
#   REPO      owner/name
#   SHA       the pushed commit
#   ACTOR     who pushed (for the issue body)
#   LABEL     label to apply to the issue
#   RUN_URL   this workflow run, so the issue links back to its evidence
#
# A merge commit belongs to exactly one merged pull request. A direct push
# belongs to none — that is the whole test. A commit that belongs to an *open*
# PR is also a direct push: the branch was pushed to main before anyone merged
# it, which is the case a naive "has a PR" check would let through.
#
# curl and python3, not gh: this has to run on the self-hosted fleet as well as
# on hosted runners, and the fleet image ships neither gh nor jq. A tripwire that
# dies with "command not found" reports nothing, and reports it as a red check,
# which is the worst of both — it looks like a finding and contains none.
set -euo pipefail

: "${GH_TOKEN:?}" "${REPO:?}" "${SHA:?}" "${LABEL:?}"
ACTOR="${ACTOR:-unknown}"
RUN_URL="${RUN_URL:-}"
API="${GITHUB_API_URL:-https://api.github.com}"

short="${SHA:0:12}"

# GET one API path. Fails loudly: a tripwire that cannot read must not read as
# "nothing to report".
api_get() {
  curl -fsSL \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$API/$1"
}

# POST a JSON body from stdin, printing the response. Non-fatal by choice at the
# call site, never here.
api_post() {
  curl -fsSL -X POST \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "$API/$1"
}

merged="$(
  api_get "repos/$REPO/commits/$SHA/pulls" \
    | python3 -c 'import json,sys; print(sum(1 for pr in json.load(sys.stdin) if pr.get("merged_at")))'
)"

if [ "$merged" -gt 0 ]; then
  echo "ok: $short arrived through a merged pull request"
  exit 0
fi

echo "direct push detected: $short is in no merged pull request" >&2

title="direct push to the default branch: $short"

# One issue per commit. A re-run of the same workflow must not open a second.
existing="$(
  api_get "repos/$REPO/issues?state=all&labels=$LABEL&per_page=100" \
    | TITLE="$title" python3 -c '
import json, os, sys
want = os.environ["TITLE"]
print(sum(1 for issue in json.load(sys.stdin) if issue.get("title") == want))'
)"
if [ "$existing" -gt 0 ]; then
  echo "an issue for $short already exists; not opening another"
  exit 1
fi

# The label may not exist yet in a repo the tripwire is new to. Creating it is
# best-effort — a failure here must not swallow the finding.
printf '{"name":"%s","color":"B60205","description":"a commit reached the default branch without a pull request"}' \
  "$LABEL" | api_post "repos/$REPO/labels" >/dev/null 2>&1 || true

body="$(cat <<EOF
\`$short\` reached the default branch of \`$REPO\` without a merged pull request.

- commit: $SHA
- pushed by: $ACTOR
- workflow run: $RUN_URL

This org has no server-side branch protection, so nothing refused the push. Two
things follow from that:

1. **Review the commit now**, out of band. Nothing gated it — no required check
   ran against it before it became what the fleet builds from.
2. **Enable the local guard** if it is off. The render plane ships
   \`.fm/hooks/pre-push\`, which refuses a direct push. A checkout turns it on
   with \`git config core.hooksPath .fm/hooks\`, and the workspace installer
   does it for every checkout it finds.

Close this once the commit has been reviewed. A deliberate push is fine — say so
here, because the record of why is the part worth keeping.
EOF
)"

# Build the request with json.dumps rather than string-pasting: the body is
# multi-line Markdown with backticks and quotes in it.
TITLE="$title" BODY="$body" LABEL="$LABEL" python3 -c '
import json, os, sys
json.dump({"title": os.environ["TITLE"], "body": os.environ["BODY"], "labels": [os.environ["LABEL"]]}, sys.stdout)' \
  | api_post "repos/$REPO/issues" \
  | python3 -c 'import json,sys; print("opened", json.load(sys.stdin)["html_url"])'

exit 1
