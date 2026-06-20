#!/usr/bin/env bash
# Render the org-profile architecture diagram to an SVG sidecar.
# Source of truth: architecture.d2. Output: ../assets/architecture.svg.
set -euo pipefail
cd "$(dirname "$0")"

FONT="fonts/GeistMono-VF.ttf"

d2 --layout elk \
  --font-regular "$FONT" \
  --font-bold "$FONT" \
  --font-italic "$FONT" \
  architecture.d2 ../assets/architecture.svg
