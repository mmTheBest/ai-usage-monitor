#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXECUTABLE="$PROJECT_DIR/.build/debug/AIUsageMonitor"

cd "$PROJECT_DIR"

"$PROJECT_DIR/Scripts/setup-accounts.command"
swift build --product AIUsageMonitor

if pgrep -x AIUsageMonitor >/dev/null 2>&1; then
  pkill -x AIUsageMonitor || true
  sleep 0.5
fi

"$EXECUTABLE"
