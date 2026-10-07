#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
odin build src/cli/kvist -o:speed
python3 tests/integration/references/test_references.py
if command -v emacs >/dev/null 2>&1; then
    KVIST_REFERENCE_CLI="$ROOT/kvist" emacs -Q --batch -L emacs \
        -l tests/integration/references/kvist-references-test.el \
        -f ert-run-tests-batch-and-exit
fi
