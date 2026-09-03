# ADR 0002 — Coding agents merge their own pull requests

- **Status**: accepted
- **Date**: 2026-09-03
- **Deciders**: First Motive maintainers
- **Amends**: ADR 0001's "no owner / admin bypass" line in the branch-protection standard. Everything else in 0001 stands.

## Context

ADR 0001 fixed the path to `main`: branch, pull request, green checks, merge.
It also set the branch-protection standard to apply on the day a repo can be
protected, and that standard said `enforce_admins: true` — no bypass for
anyone.

Since then, coding agents have carried most of the day-to-day work in these
repos. For months the convention was that an agent commits and stops, and a
person pushes, opens the pull request, and merges. In practice the person
approved every one of those steps without change, then told the agent to do
them anyway. The handoff was a prompt that never caught anything, and it cost
a round trip on every change.

The one place the person was genuinely needed was the review rule. A required
code-owner review on a repo with one regular committer has no second reviewer
to satisfy. The owner's token can merge past it with `gh pr merge --admin`, but
ADR 0001's standard forbade exactly that.

## Decision

**Agents ship their own work end to end.** Push the branch, open the pull
request, watch the checks, merge, delete the branch. The path to `main` is
unchanged; who walks it is.

**`gh pr merge --admin` is allowed when a required review is the only
blocker.** The branch-protection standard becomes `enforce_admins: false`, so
the owner — and an agent running under the owner's token — can merge past the
review rule on a solo repo. Status checks still bind: the admin path is never
used on a red or pending check, and a force-push is never the answer to a
failed merge.

The change is rendered into every repo through the render plane
(`AGENTS.md` invariants, `CONTRIBUTING.md` workflow block) and into the
`fm-github` skill's governance section and `protect-main.sh` template.

## Consequences

**What this buys.** The commit gate — tests plus reviewer agents before every
commit — and CI on the pull request are the controls that catch mistakes. The
human prompt was not one of them, and removing it removes a round trip per
change without removing a check.

**What it costs.** A merge is outward-facing and effectively irreversible, and
the admin path skips a review that a second committer would otherwise give.
That is acceptable while the review rule has nobody to satisfy. It stops being
acceptable on the first revisit trigger below.

**Revisit triggers.** Reopen on any of:

- **A second regular committer on a repo.** The review rule then has a reviewer,
  and `--admin` should go back to being an emergency, not a path.
- **A merge that should not have happened.** Any admin merge that lands broken
  work on `main`, or any merge on a check that was not green.
- **ADR 0001's own triggers.** When protection turns on, apply the standard
  with `enforce_admins: false` and the required checks from 0001.
