#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
if pkill -x PomodoroBlocker; then
    while pgrep -x PomodoroBlocker >/dev/null; do sleep 0.1; done
fi
open .build/PomodoroBlocker.app
