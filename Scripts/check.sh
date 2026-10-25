#!/bin/bash
set -euo pipefail
LEAN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LEAN_ROOT"
swift build -c release --product LeanDockChecks
LEAN_BIN_DIR="$(swift build -c release --show-bin-path)"
"$LEAN_BIN_DIR/LeanDockChecks"
