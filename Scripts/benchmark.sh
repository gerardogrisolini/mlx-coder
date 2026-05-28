#!/usr/bin/env bash
set -euo pipefail

PROMPT="${PROMPT:-Ciao}"
MAX_TOKENS="${MAX_TOKENS:-256}"

MODEL_ARGUMENTS=()
if [[ -n "${MODEL:-}" ]]; then
  MODEL_ARGUMENTS=(--model "$MODEL")
fi

swift run -c release mlx-server \
  --chat "$PROMPT" \
  "${MODEL_ARGUMENTS[@]}" \
  --max-tokens "$MAX_TOKENS" \
  --quiet
