#!/bin/zsh
# Run the RhythmCore unit tests on the Mac (fast; no simulator needed).
set -euo pipefail
cd "$(dirname "$0")/../RhythmCore"
swift test "$@"
