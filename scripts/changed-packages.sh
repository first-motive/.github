#!/usr/bin/env bash
# Name the colcon packages a pull request touched, for a changed-only build.
#
# Called by .github/workflows/ros2-build-test.yml from inside the checked-out
# repo, whose HEAD is the pull request's merge commit: HEAD^1 is the base it
# merges into, so the diff between them is exactly the pull request.
#
#   PACKAGE_LIST="$(colcon list --base-paths .)" ./changed-packages.sh
#
# Env:
#   PACKAGE_LIST  `colcon list` output, run from the repo root (name<TAB>path<TAB>type)
#
# Prints the selected package names, space-separated, or nothing when the whole
# workspace must build: no changed files, or a file outside every package — a
# .repos manifest, a workflow — which can reach any package. The reason for a
# full build goes to stderr.
set -euo pipefail

PACKAGE_LIST="${PACKAGE_LIST:-}"

# The names reach colcon's argv unquoted, so anything beyond a plain identifier
# fails here rather than turning into extra arguments. An empty line is let
# through: it names no package, so it can only force a full build. The C locale
# keeps the ranges ASCII.
unsafe="$(cut -f1 <<<"$PACKAGE_LIST" | LC_ALL=C grep -vE '^([A-Za-z][A-Za-z0-9_]*)?$' || true)"
if [ -n "$unsafe" ]; then
  echo "FAIL: unsafe package name: $unsafe" >&2
  exit 1
fi

# --no-renames: a moved file must select the package it left as well as the one
# it entered. quotePath off: a non-ASCII path stays matchable instead of quoted.
files="$(git -c core.quotePath=false diff --no-renames --name-only HEAD^1 HEAD)"
if [ -z "$files" ]; then
  echo "no changed files: building everything" >&2
  exit 0
fi

# Each file maps to the deepest package directory holding it; a package at the
# repo root (".") holds every file, at the lowest depth.
# tradeoff: every file scans every package, fine to a few hundred packages.
awk '
  BEGIN {
    n = split(ENVIRON["PACKAGE_LIST"], line, "\n")
    for (i = 1; i <= n; i++) if (split(line[i], f, "\t") >= 2) dir[f[1]] = f[2]
  }
  {
    best = ""; bestlen = -1
    for (name in dir) {
      if (dir[name] == ".") len = 0
      else if (index($0, dir[name] "/") == 1) len = length(dir[name])
      else continue
      if (len > bestlen) { best = name; bestlen = len }
    }
    if (best == "") { print "outside every package: " $0 > "/dev/stderr"; outside = 1 }
    else hit[best] = 1
  }
  END { if (!outside) for (name in hit) print name }
' <<<"$files" | sort | paste -sd ' ' -
