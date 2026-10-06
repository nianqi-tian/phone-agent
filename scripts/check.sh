#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 ]]; then
  echo "Usage: bash scripts/check.sh [path/to/PhoneAgent.app]" >&2
  exit 2
fi
bash "$project_dir/Tests/run.sh"
bash "$project_dir/Tests/ProductState/run.sh"
if [[ $# -eq 1 ]]; then
  bash "$project_dir/Tests/Skills/run.sh" "$1"
fi
