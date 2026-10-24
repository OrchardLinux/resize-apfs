#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -j 2 --product resize-mock
exec .build/debug/resize-mock --state "$PWD/.mock/state.json" "$@"
