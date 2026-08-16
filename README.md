# .github

Organization-level defaults for the [First Motive](https://github.com/first-motive) org:
the landing page, the community health files every repo inherits, and the CI
workflows repos call by reference instead of copying.

```
.github/
├── profile/README.md           org landing page (github.com/first-motive)
├── CONTRIBUTING.md             inherited by every repo without its own
├── CODE_OF_CONDUCT.md          inherited by every repo without its own
├── SECURITY.md                 inherited by every repo without its own
└── .github/
    ├── PULL_REQUEST_TEMPLATE.md
    ├── ISSUE_TEMPLATE/         bug, feature, security contact link
    └── workflows/              reusable workflows (workflow_call)
```

A repo that ships its own CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, or templates
overrides the org copy. A repo that ships none inherits these — so a new repo is
governed from its first commit.

## Reusable Workflows

Logic that more than one repo runs lives here once. A consumer calls it by
reference; there is no copy to drift.

| Workflow                 | What it proves                                                       |
| ------------------------ | -------------------------------------------------------------------- |
| `bootstrap-selftest.yml` | The curl\|bash front door still resolves, on a bare runner            |
| `ros2-build-test.yml`    | The colcon workspace imports, builds, and passes its own tests        |
| `drift-check.yml`        | No rendered artifact in the repo was edited in place                  |

```yaml
jobs:
  selftest:
    uses: first-motive/.github/.github/workflows/bootstrap-selftest.yml@main
    with:
      scripts: install.sh run.sh
      parse-globs: scripts/install/*.sh scripts/run/*.sh

  build-test:
    uses: first-motive/.github/.github/workflows/ros2-build-test.yml@main
    with:
      repos-file: fm-robot.repos
      build-externals: openarm_description unitree_ros2
      apt-packages: ros-humble-rosidl-generator-dds-idl ros-humble-cyclonedds

  drift:
    uses: first-motive/.github/.github/workflows/drift-check.yml@main
```

`runs-on` is JSON, so a job can land on the self-hosted fleet:
`runs-on: '["self-hosted","Linux","ARM64","fm-ci"]'`.

Each workflow's inputs are documented in its own header. Read that file before
adding an input — a repo-specific need usually belongs in the calling repo, not
in a new knob here.

## Action Pinning

Every `uses:` in this repo pins a third-party action to a full commit SHA with
the human-readable version in a trailing comment:

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

A tag is mutable — the author can move `v7` to any commit, including one added
after review. A SHA cannot move. This is the one pinning policy for the org, and
it applies to consumer workflows too.

Bump a pin by resolving the tag again:

```bash
gh api repos/actions/checkout/tags --jq '.[] | .name + " " + .commit.sha'
```
