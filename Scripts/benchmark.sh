#!/usr/bin/env bash
set -euo pipefail

PROMPT="${PROMPT:-Ciao}"
MAX_TOKENS="${MAX_TOKENS:-256}"
BENCHMARK_WARMUPS="${BENCHMARK_WARMUPS:-1}"
BENCHMARK_RUNS="${BENCHMARK_RUNS:-3}"
MIN_GENERATION_TOKENS_PER_SECOND="${MIN_GENERATION_TOKENS_PER_SECOND:-29}"

MODEL_ARGUMENTS=()
if [[ -n "${MODEL:-}" ]]; then
  MODEL_ARGUMENTS=(--model "$MODEL")
fi

swift run -c release mlx-server \
  --prompt "$PROMPT" \
  "${MODEL_ARGUMENTS[@]}" \
  --max-tokens "$MAX_TOKENS" \
  --benchmark-warmups "$BENCHMARK_WARMUPS" \
  --benchmark-runs "$BENCHMARK_RUNS" \
  --min-generation-tokens-per-second "$MIN_GENERATION_TOKENS_PER_SECOND" \
  --quiet
