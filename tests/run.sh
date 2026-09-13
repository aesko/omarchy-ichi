#!/usr/bin/env bash
# Runs every test suite that has a runtime available.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

status=0
if command -v lua >/dev/null; then
  lua tests/ichi_test.lua || status=1
else
  echo "skip: lua not installed (ichi_test.lua)"
fi
if command -v node >/dev/null; then
  node tests/model.test.mjs || status=1
else
  echo "skip: node not installed (model.test.mjs)"
fi
tests/loader_install_test.sh || status=1
exit $status
