#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
for script in "$ROOT"/*.sh; do
  echo "bash -n $script"
  bash -n "$script"
done
