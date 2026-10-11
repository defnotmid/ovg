#!/usr/bin/env bash
# Renders the curated Lottie files in tests/ with the software backend and
# compares them with their lottie-web reference PNGs (see main.odin and
# tests/README.md). Exits non-zero when a frame fails. Extra arguments go
# to the runner, e.g. -v or -tol:16.
set -euo pipefail
cd "$(dirname "$0")"
out="${TMPDIR:-/tmp}/ovg_lottie_suite"
odin build . -o:speed -out:"$out"
status=0
timeout 600 "$out" "$@" tests || status=$?
rm -f "$out"
exit $status
