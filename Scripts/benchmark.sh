#!/usr/bin/env bash
set -euo pipefail

PROMPT="${PROMPT:-Ciao}"
MAX_TOKENS="${MAX_TOKENS:-256}"
MIN_GENERATION_TOKENS_PER_SECOND="${MIN_GENERATION_TOKENS_PER_SECOND:-29}"

MODEL_ARGUMENTS=()
if [[ -n "${MODEL:-}" ]]; then
  MODEL_ARGUMENTS=(--model "$MODEL")
fi

swift run -c release mlx-server \
  --chat "$PROMPT" \
  "${MODEL_ARGUMENTS[@]}" \
  --max-tokens "$MAX_TOKENS" \
  --min-generation-tokens-per-second "$MIN_GENERATION_TOKENS_PER_SECOND" \
  --quiet
