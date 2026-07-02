#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if rg -n "fatalError|preconditionFailure|assertionFailure\\(" Sources; then
  printf "Production sources contain crash-only markers. Replace them with recoverable error handling before release.\n" >&2
  exit 1
fi

printf "Crash-only marker scan passed.\n"
