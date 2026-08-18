# ADR 0001 — Branch protection deferred; compensating controls instead

- **Status**: accepted
- **Date**: 2026-08-16, controls landed 2026-08-18
- **Deciders**: First Motive maintainers
- **Supersedes**: nothing. **Revisit triggers**: see below.

## Context

A wave-1 audit found no branch protection on any private First Motive repo, nor
on `fm-setup`. CI was advisory exactly where the deepest test suites run. Several
strong jobs were not required checks, and the Actions token could approve pull
requests on the public repos.

The direct fix is server-side: required checks and a protected default branch.
On GitHub that is a paid feature for private repositories — the free plan returns
403 for the protection API and offers no org rulesets. This organisation is on
the free plan, and the cost of upgrading is real against a team of its current
size.

The gap is not theoretical. Twice in two weeks work was believed shipped while it
sat unpushed on a laptop, because the only thing between "committed" and "on
main" was somebody remembering the flow. And the fleet does not ride `main` at
all: rigs pin themselves to the newest `v*` tag and converge there on a timer, so
a tag is the moment work reaches hardware — and a tag can be cut from any laptop,
against any commit, with no gate whatsoever.

## Decision

**Defer the plan upgrade.** Accept that private repos have no server-side
protection for now, and close the gap with controls that work on the free plan.

Four controls, chosen so that each one covers a different failure of the others:

1. **`fm release` gates tags on green CI.** The release verb resolves the commit
   a tag would land on — the *remote's* default-branch tip, not local `HEAD` —
   reads the check runs on it, and refuses to cut unless every one passed.
   `pending` and `unknown` are refusals: a commit nothing has checked is the
   state this exists to catch. This covers the moment that actually reaches the
   fleet.
2. **A pre-push hook refuses direct pushes to the default branch.** It is
   rendered into every repo by the render plane as `.fm/hooks/pre-push`, so it
   is one source with a drift check rather than sixteen copies. A checkout
   enables it with `git config core.hooksPath .fm/hooks`; the workspace
   installer does it for every checkout it finds, and `fm doctor` reports a repo
   where it is off. `FM_ALLOW_MAIN_PUSH=1` is a deliberate, loud, one-command
   escape.
3. **A direct-push tripwire notices what the hook cannot refuse.** A reusable
   workflow on push-to-default asks GitHub whether the pushed commit belongs to
   a merged pull request. If it does not, it opens a labelled issue naming the
   commit, the pusher, and the run. This is the half that still works for a
   fresh clone that never ran an installer, or for a push that took the escape
   hatch.
4. **Opening repositories where we can.** A public repo gets branch protection
   free, so every repo that opens leaves the ungated set. Two are already
   scheduled to open; which ones, and what remains after them, is tracked in the
   private operations notes rather than here.

## Consequences

**What this buys.** Every path from a keystroke to a rig now passes something: a
push to `main` is refused locally and reported centrally if it happens anyway, and
a tag — the thing rigs actually follow — cannot be cut onto red CI through the
supported flow.

**What it does not buy.** None of this is enforcement. Each control lives on the
client or reacts after the fact:

- the hook is local config, and a fresh clone has it off until an installer runs;
- the escape hatch is one environment variable;
- the tripwire reports a direct push, it cannot prevent one;
- `fm release` gates the supported flow, and `git tag && git push --tags` still
  works for anyone who types it.

That is the honest shape of a client-side control, and it is why this is a
deferral rather than a decision that protection is unnecessary.

**Cost.** Four moving parts to maintain instead of a settings page, and one more
reason for every repo to consume the render plane and the org workflows.

## Revisit triggers

Reopen this decision on any of:

- **Headcount.** A third regular committer. Two people can hold a convention in
  their heads; three cannot.
- **A first incident.** Any direct push the tripwire reports that turns out to
  have broken something, or any tag cut onto a red commit.
- **Repos opening.** If the remaining private repos go public, protection is free
  and this ADR is moot.
- **A paid plan for another reason.** If the org upgrades for org secrets, CI
  minutes, or anything else, protection comes with it — turn it on the same day.

## Required checks, per repo

What each repo would require if protection were on today. This is the list to
apply on the day the trigger fires, and it is why the checks are worth keeping
green in the meantime.

| Repo | Required checks |
| --- | --- |
| `fm-ros2` | `ci-smoke`, `build-test`, `workflows`, `drift`, `image-deps` |
| `fm-app` | `build-test`, `smoke`, `image`, `drift` |
| `fm-robot` | `build-test`, `smoke`, `image`, `drift` |
| `fm-sim` | `build-test`, `smoke`, `image`, `drift` |
| `fm-teleop` | `build-test`, `smoke`, `image`, `drift` |
| `fm-docker` | `shellcheck`, `tag refs`, `curl-smoke`, `image`, `drift` |
| `fm-setup` | `rehearse`, `drift` |
| `fm-tools` | its pytest job, `drift` |
| `fm-comms` | its own CI job, `drift` |

Every repo consuming the render plane requires `drift` — that is the check that
holds a rendered file to its source, and a repo can pass everything else while
quietly editing one in place.

The private repos have the same rule and their own list, kept with the rest of
the private operations notes: this file is public, and the set of private repos
is not something a public document should enumerate.

Also on that day: disable Actions' ability to approve pull requests, and promote
or delete every check still marked optional.
