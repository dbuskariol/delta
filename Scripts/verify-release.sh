#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Kept as the familiar verification entry point; the release graph itself has
# one implementation and one shared invariant library.
MODE="${1:-prepare}"
exec "$ROOT_DIR/Scripts/release.sh" "$MODE"
