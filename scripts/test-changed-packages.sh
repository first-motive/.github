#!/usr/bin/env bash
# Fixture test for changed-packages.sh.
#
# A wrong selection does not fail a build, it silently skips one, so each case
# here is a pull request built for real: a change on a branch, merged with
# --no-ff into main, so HEAD^1 is the base exactly as on a pull_request checkout.
# The colcon list is a fixture; colcon itself is not needed.
#
#   bash scripts/test-changed-packages.sh
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/changed-packages.sh"
repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
cd "$repo"

git() { command git -c user.name=test -c user.email=test@example.com "$@"; }
git init -q -b main
mkdir -p fm_a/src fm_a/sub/fm_nested fm_ab docs
for f in fm_a/src/a.cpp fm_a/sub/fm_nested/n.py fm_ab/b.cpp docs/x.md; do
  echo "content of $f" > "$f"
done
git add -A
git commit -qm base

list=$'fm_a\tfm_a\t(ros.ament_cmake)\nfm_nested\tfm_a/sub/fm_nested\t(ros.ament_python)'
root_list=$'fm_root\t.\t(ros.ament_cmake)\n'"$list"
fails=0

# The working-tree change made before the call becomes the pull request.
expect() {
  local name="$1" want="$2" packages="${3:-$list}" got
  git switch -qc pr
  git add -A
  git commit -qm change --allow-empty
  git switch -q main
  git merge -q --no-ff pr -m merge
  got="$(PACKAGE_LIST="$packages" bash "$script" 2>/dev/null)" || got="<failed>"
  if [ "$got" = "$want" ]; then
    echo "ok    $name"
  else
    echo "FAIL  $name: want '$want', got '$got'"
    fails=$((fails + 1))
  fi
  git reset -q --hard HEAD^1
  git branch -qD pr
}

echo x >> fm_a/src/a.cpp
expect "file in a package" "fm_a"

echo x > fm_a/src/café.cpp
expect "non-ASCII path stays matchable" "fm_a"

echo x >> fm_a/sub/fm_nested/n.py
expect "nested package wins over its parent" "fm_nested"

echo x >> fm_a/src/a.cpp
echo x >> fm_a/sub/fm_nested/n.py
expect "two packages" "fm_a fm_nested"

echo x >> docs/x.md
expect "root package holds any file" "fm_root" "$root_list"

echo x >> fm_a/src/a.cpp
expect "deeper package wins over root" "fm_a" "$root_list"

echo x >> docs/x.md
echo x >> fm_a/src/a.cpp
expect "file outside every package: full build" ""

echo x >> fm_ab/b.cpp
expect "name prefix is not a directory: full build" ""

expect "empty diff: full build" ""

git mv fm_a/src/a.cpp fm_a/sub/fm_nested/a.cpp
expect "rename selects the package it left" "fm_a fm_nested"

echo x >> fm_a/src/a.cpp
expect "unsafe package name fails" "<failed>" $'fm_a;rm\tfm_a\t(ros.ament_cmake)'

[ "$fails" -eq 0 ] || { echo "$fails case(s) failed"; exit 1; }
echo "all cases passed"
