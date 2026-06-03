# mlx-server Guide

`mlx-server` is the local MLX inference service included in this Swift package. It loads explicitly configured MLX models through `mlx-swift-lm` and exposes them through API-compatible HTTP endpoints for OpenAI Chat Completions, OpenAI Responses, and Anthropic Messages clients.

Use this guide when you want to install the server, configure models, run it as an HTTP service, benchmark it, or use the direct `mlx-server --coder` mode.

## Requirements

- macOS supported by the package platform declaration.
- Swift 6.3 toolchain.
- Apple Silicon with Metal support for practical MLX inference.
- Network access for the first Hugging Face model download, unless the model is already present in the Hugging Face cache.

Build or test from the repository root:

```bash
swift build -c release --product mlx-server
swift test
```

## Runtime Files

`mlx-server` uses explicit files under `~/.mlx-server/`:

- `settings.json`: host, port, API key, TLS, HTTP/2, metrics, model retention, Hugging Face cache access, memory KV cache, and disk KV cache settings.
- `models.json`: enabled model catalog, default model, Hugging Face repositories, generation defaults, and thinking/reasoning metadata.
- `KVCaches/`: default disk KV cache directory when disk caching is enabled and no custom directory is configured.

The server does not scan arbitrary cache directories at request time. `/v1/models` and model resolution use only `models.json`.

## First Setup

Create the server settings:

```bash
swift run -c release mlx-server --setup
```

Then configure models:

```bash
swift run -c release mlx-server --setup-models
```

Model setup searches Hugging Face with the MLX filter, downloads the selected repository, imports context and generation defaults from model metadata, detects thinking support when possible, and writes the model entry to `~/.mlx-server/models.json`.

On the first run, if `models.json` does not exist, setup can also import model snapshots already present in the Hugging Face cache. Imported models still go through the generation parameter prompts before being saved.

## settings.json

The setup command writes a validated `settings.json`. Important fields are:

```json
{
  "host": "127.0.0.1",
  "port": 8080,
  "web_server_threads": 2,
  "load_one_model_at_a_time": true,
  "http2_prior_knowledge": false,
  "api_key": null,
  "tls_certificate_path": null,
  "tls_private_key_path": null,
  "metrics_log_path": null,
  "kv_cache": {
    "mode": "standard",
    "quantized_bits": 4,
    "quantized_group_size": 64,
    "quantized_start": 1024
  },
  "disk_kv_cache": {
    "enabled": true,
    "directory_path": null,
    "limit_gb": 100
  },
  "huggingface_cache": {
    "directory_path": null,
    "bookmark": null
  }
}
```

Notes:

- `host` and `port` define the HTTP bind address.
- `web_server_threads` defaults to `2` and is validated in the range `1...256`.
- `load_one_model_at_a_time: true` unloads the previous model before another model is loaded. Set it to `false` only when memory allows multiple loaded models.
- `api_key`, when present, protects every route except `GET /health`.
- TLS requires both `tls_certificate_path` and `tls_private_key_path`.
- `http2_prior_knowledge` enables prior-knowledge HTTP/2 transport when the client expects it.
- `metrics_log_path` writes JSONL metrics to a file; when absent, metrics go to stderr.
- `kv_cache.mode` can be `standard` or `quantized`. Quantized values are clamped by the runtime.
- `disk_kv_cache.enabled` controls persisted KV cache reuse. `limit_gb` defaults to `100` and must be between `0` and `1,000,000`.
- `huggingface_cache` is managed by setup so the runtime can find/import model snapshots consistently.

## models.json

A typical `models.json` shape is:

```json
{
  "defaultModelID": "qwen3-mlx",
  "models": [
    {
      "id": "qwen3-mlx",
      "display_name": "Qwen3 MLX",
      "repository_id": "mlx-community/Qwen3-...-MLX",
      "revision": "main",
      "runtime_kind": "llm",
      "enabled": true,
      "generation_defaults": {
        "context_window": 32768,
        "max_output_tokens": 4096,
        "temperature": 0.6,
        "top_p": 0.95,
        "top_k": 20,
        "repetition_penalty": 1.0,
        "presence_penalty": 0.0,
        "frequency_penalty": 0.0
      },
      "thinking": {
        "supports_thinking": true,
        "supports_reasoning_effort": true,
        "supports_preserve_thinking": false,
        "available_selections": ["off", "minimal", "low", "medium", "high"],
        "default_selection": "medium"
      }
    }
  ]
}
```

Prefer `--setup-models` over hand editing. If you do edit manually:

- `id` must be unique and non-empty.
- `repository_id` must point to an MLX-compatible Hugging Face repository.
- `enabled: false` keeps a record in the file but removes it from the served catalog.
- `defaultModelID` must match an enabled model; otherwise validation fails.
- Thinking selections may include `off`, `enabled`, `minimal`, `low`, `medium`, `high`, and `xhigh` depending on model support.

## Run the HTTP Server

Start the optimized server:

```bash
swift run -c release mlx-server
```

The executable reads `settings.json` and `models.json`, prepares `mlx.metallib` if SwiftPM has not copied it next to the binary yet, and sets `MLX_METAL_FAST_SYNCH=1` by default unless your environment already defines it.

Check health and model catalog:

```bash
curl -s http://127.0.0.1:8080/health
curl -s http://127.0.0.1:8080/v1/models
```

If `api_key` is configured, use either header:

```bash
-H 'Authorization: Bearer <api_key>'
-H 'X-API-Key: <api_key>'
```

## HTTP Endpoints

Supported routes:

- `GET /health`
- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/responses`
- `POST /v1/messages`

All generation endpoints support regular JSON and Server-Sent Events streaming with `stream: true`.

### OpenAI Chat Completions

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <api_key>' \
  -d '{
    "model": "qwen3-mlx",
    "messages": [
      {"role": "system", "content": "You are a concise assistant."},
      {"role": "user", "content": "Ciao"}
    ],
    "max_tokens": 128
  }'
```

The response maps assistant text to `message.content`, reasoning to `message.reasoning_content`, and tools to `tool_calls`.

### OpenAI Responses

```bash
curl -s http://127.0.0.1:8080/v1/responses \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <api_key>' \
  -d '{
    "model": "qwen3-mlx",
    "input": "Explain MLX in one paragraph.",
    "max_output_tokens": 160
  }'
```

The response uses Responses-style output items such as `message`, `reasoning`, and `function_call`.

### Anthropic Messages

```bash
curl -s http://127.0.0.1:8080/v1/messages \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <api_key>' \
  -d '{
    "model": "qwen3-mlx",
    "max_tokens": 128,
    "messages": [
      {"role": "user", "content": "Summarize local inference."}
    ]
  }'
```

The response maps text to `text`, reasoning to `thinking`, and tool calls to `tool_use` content blocks.

## Metrics

Non-stream generation responses include `mlx_metrics`:

```json
{
  "mlx_metrics": {
    "prompt_tokens_per_second": 53.0,
    "generation_tokens_per_second": 29.0
  }
}
```

When `metrics_log_path` is set, the server writes request metrics as JSON lines. Use this when comparing models, cache changes, prompt formats, or protocol adapters.

## Terminal Chat and Benchmarking

Run the local chat path without starting HTTP:

```bash
swift run -c release mlx-server --chat --max-tokens 256
```

Pass the first message directly:

```bash
swift run -c release mlx-server --chat Ciao --max-tokens 256
```

Useful flags:

- `--model <id>` selects a configured model.
- `--max-tokens <count>` overrides output tokens for chat turns.
- `--quiet` suppresses assistant text and keeps metrics output.

Each turn prints prompt tokens, generation tokens, prefill tok/s, and generation tok/s. The helper script wraps the same path:

```bash
./Scripts/benchmark.sh
```

## Direct mlx-coder Mode

`mlx-server` can host the same `mlx-coder` runtime directly, using the configured local MLX model catalog without HTTP:

```bash
swift run -c release mlx-server --coder --cwd /path/to/project
```

Useful flags:

- `--model <id>` chooses a model from `models.json`.
- `--agent <name>` chooses an agent profile from `~/.mlx-coder/agents.json`.
- `--skills <list>` selects initial prompt skills.
- `--max-output-tokens <count>` overrides model output tokens.
- `--max-tool-rounds <count>` limits model/tool loop rounds.
- `--verbose` prints status/tool progress on stderr.
- `--acp` exposes the direct local runtime over ACP stdio for clients that speak ACP.

Direct mode ensures a project `AGENTS.md` exists in the working directory before starting the TUI.

## Agent Client Integrations

Configure external clients with:

```bash
swift run -c release mlx-server --setup-agents
```

The setup can enable or disable owned entries for:

- Codex CLI in `~/.codex/config.toml`.
- Codex App in `~/.codex/config.toml`.
- Codex in Xcode in `~/Library/Developer/Xcode/CodingAssistant/codex/config.toml`.
- Claude Code in Xcode in `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json`.

The setup reads existing files as the source of truth and removes only entries it owns when disabling an integration.

## Maintenance Commands

```bash
swift run -c release mlx-server --help
swift run -c release mlx-server --version
swift run -c release mlx-server --setup
swift run -c release mlx-server --setup-models
swift run -c release mlx-server --setup-agents
swift run -c release mlx-server --reset
swift run -c release mlx-server --reset-disk-cache
```

`--reset` deletes managed files in `~/.mlx-server/` and `~/.mlx-coder/`: `settings.json`, `models.json`, `agents.json`, `AGENTS.md`, and `MEMORY.md`.

`--reset-disk-cache` empties the configured disk KV cache directory. If settings are missing, it uses `~/.mlx-server/KVCaches`.

## Troubleshooting

- `settings.json not found`: run `swift run -c release mlx-server --setup`.
- `models.json` missing or empty: run `swift run -c release mlx-server --setup-models`.
- 401 responses: add the configured bearer token or `X-API-Key` header.
- TLS validation error: configure both certificate and private key paths.
- Low tok/s: test with `--chat --quiet`, compare metrics logs, and check whether another request is already generating.
- Out-of-memory when switching models: keep `load_one_model_at_a_time` enabled or use a smaller/quantized model.
