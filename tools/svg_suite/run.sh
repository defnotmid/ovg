#!/usr/bin/env bash
# Renders the curated resvg tests in tests/ with the software backend and
# compares them with their reference PNGs (see main.odin). Exits non-zero
# when a test fails. Extra arguments go to the runner, e.g. -v or -tol:16;
# point it at a full resvg checkout (crates/resvg/tests/tests, with
# -fonts:crates/resvg/tests/fonts for the text tests) for the whole suite.
set -euo pipefail
cd "$(dirname "$0")"
out="${TMPDIR:-/tmp}/ovg_svg_suite"
odin build . -o:speed -out:"$out"
status=0
timeout 600 "$out" "$@" tests | tee "$out.log" || status=$?
rm -f "$out"
if grep -q '^FAIL' "$out.log"; then
	rm -f "$out.log"
	exit 1
fi
rm -f "$out.log"
exit $status
