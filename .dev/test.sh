#!/usr/bin/env bash
# End-to-end tests for postgres17-standalone in a guest. Run via
# `.dev/vm test [os...]`, which builds and copies the binaries first and sets
# VM and VM_OS. The tests themselves are in .dev/pgtest, which runs in the
# guest next to the binary.
set -uo pipefail

: "${VM:?run via .dev/vm test}" "${VM_OS:?run via .dev/vm test}"
"$VM" _run "$VM_OS" pgtest "$@" </dev/null 2>&1 | tr -d '\r'
