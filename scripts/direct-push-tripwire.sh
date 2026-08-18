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
set -euo pipefail

: "${GH_TOKEN:?}" "${REPO:?}" "${SHA:?}" "${LABEL:?}"
ACTOR="${ACTOR:-unknown}"
RUN_URL="${RUN_URL:-}"

short="${SHA:0:12}"

# `commits/{sha}/pulls` lists every PR the commit is part of, with its state.
merged="$(
  gh api "repos/$REPO/commits/$SHA/pulls" \
    --jq '[.[] | select(.merged_at != null)] | length'
)"

if [ "$merged" -gt 0 ]; then
  echo "ok: $short arrived through a merged pull request"
  exit 0
fi

echo "direct push detected: $short is in no merged pull request" >&2

title="direct push to the default branch: $short"

# One issue per commit. A re-run of the same workflow must not open a second.
existing="$(
  gh api "repos/$REPO/issues?state=all&labels=$LABEL&per_page=100" \
    --jq "[.[] | select(.title == \"$title\")] | length"
)"
if [ "$existing" -gt 0 ]; then
  echo "an issue for $short already exists; not opening another"
  exit 1
fi

# The label may not exist yet in a repo the tripwire is new to. Creating it is
# idempotent enough — a failure here must not swallow the finding.
gh label create "$LABEL" --repo "$REPO" \
  --color B60205 --description "a commit reached the default branch without a pull request" \
  >/dev/null 2>&1 || true

body_file="$(mktemp)"
cat > "$body_file" <<EOF
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

gh issue create --repo "$REPO" --title "$title" --label "$LABEL" --body-file "$body_file"
rm -f "$body_file"
exit 1
