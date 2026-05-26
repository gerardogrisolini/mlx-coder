# mlx-server

`mlx-server` is a standalone Swift Package that runs local MLX language models behind API-compatible HTTP endpoints.

It is meant to be the local inference engine used by agent clients such as Codex, Claude Code, Xcode integrations, command line tools, and any app that can speak OpenAI-compatible, Responses-compatible, or Anthropic-compatible APIs. The server keeps model loading, prompt execution, protocol adaptation, streaming, thinking blocks, tool calls, and performance metrics in one small runtime path.

The goal is simple: expose downloaded MLX models as a fast local server without UI state, app sandbox assumptions, hidden model discovery, or duplicated protocol logic.

## What It Does

- Loads MLX models through [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm).
- Serves local models over HTTP using OpenAI Chat Completions, OpenAI Responses, and Anthropic Messages style endpoints.
- Supports regular JSON responses and Server-Sent Events streaming.
- Maps model thinking/reasoning into protocol-native response fields instead of returning raw `<think>` text.
- Supports tool definitions and tool-call output for the three generation protocols.
- Reads runtime settings from `settings.json` and model definitions from `models.json`.
- Downloads and imports MLX models from Hugging Face through an interactive setup.
- Configures agent clients with an explicit setup for Codex CLI, Codex App, Xcode Codex App, and Xcode Claude Code.
- Can keep multiple models loaded, or unload the previous model before loading another one.
- Records throughput metrics so regressions in tok/s are visible.
- Provides a terminal chat mode that keeps session context alive and reports tok/s per turn.

## What It Is For

Use `mlx-server` when you want a local MLX model to behave like a small API server:

- Xcode or Claude Code can call `/v1/messages`.
- Codex-style clients can call `/v1/chat/completions`.
- OpenAI Responses clients can call `/v1/responses`.
- Local tooling can query `/v1/models` and select only models explicitly configured in `models.json`.

The server is not a desktop app and does not own UI settings. It is the runtime/service layer that the apps can depend on.

## Layout

- `Sources/MLXServerCore`: reusable server core.
- `Sources/MLXServerHTTP`: HTTP server, protocol adapters, SSE streaming, and metrics logging.
- `Sources/mlx-server`: command line executable.
- `Tests/MLXServerCoreTests`: core tests.
- `Tests/MLXServerHTTPTests`: end-to-end HTTP tests for the supported protocols.
- `Scripts/benchmark.sh`: repeatable local performance benchmark.

## Dependencies

- [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) on `main`.
- `MLXServerCore` currently links `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`, and `MLXVLM`.
- `MLXServerHTTP` uses SwiftNIO, NIO HTTP/2, and NIO SSL.
- `HuggingFace` and `Tokenizers` are linked directly for the MLX Hugging Face downloader/tokenizer macros.

## Configuration Files

The server uses two explicit files. There is no fallback list and no cache-folder scan at request time.

- `settings.json`: host, port, TLS, HTTP/2, metrics log, disk KV cache, and model retention policy.
- `models.json`: the exposed model ids, Hugging Face repositories, generation defaults, and thinking configuration.

Run setup once:

```bash
swift run -c release mlx-server --setup
```

The setup writes `settings.json` next to the executable for standalone builds and then asks whether to configure models too. If accepted, it starts model setup and writes `models.json`.

## Model Loading

Models are configured through `models.json`, created by the interactive model setup:

```bash
swift run -c release mlx-server --setup-models
```

The setup searches Hugging Face with the MLX filter, downloads the selected repository into the Hugging Face cache, imports the context window from `config.json`, generation defaults from `generation_config.json`, and thinking metadata from the model metadata/template files when available, then writes the model record to `models.json`.

For each model the setup asks for the exposed model id, generation defaults, and the thinking configuration used by the API adapters: whether thinking is supported, whether effort levels are supported, the available levels, and the default level.

On the first run, if `models.json` does not exist yet, the setup also offers to import model snapshots that are already present in the Hugging Face cache. Each imported model still goes through the same generation parameter prompts before it is written to `models.json`.

When run directly, model setup also asks whether the server should keep only one model loaded at a time. That setting is stored in `settings.json`; when enabled, the runtime unloads the current model before loading a different one.

`models.json` is the only source used by `/v1/models` and by request model resolution. The server does not scan cache folders or keep a hardcoded fallback model list.

## Agent Integrations

Agent integrations are configured through a dedicated setup:

```bash
swift run -c release mlx-server --setup-agents
```

The setup reads the current external configuration files as the source of truth, shows what is already active, then lets you enable or disable:

- Codex CLI through the `mlx-server` profile in `~/.codex/config.toml`.
- Codex App through the `mlx-server-codex-app` profile in `~/.codex/config.toml`.
- Codex App in Xcode through `~/Library/Developer/Xcode/CodingAssistant/codex/config.toml`.
- Claude Code in Xcode through `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json`.

When a Codex integration is enabled, setup writes the local `mlx-server` model provider, the dedicated profile, and a small `mlx-server-codex-models.json` catalog pointing at the selected model. When it is disabled, setup removes only the profile it owns; the shared provider and catalog are removed only when no remaining `mlx-server` profile references them.

Claude Code in Xcode is intentionally simpler: enabled means the dedicated Xcode Claude settings file exists and points at the local Anthropic-compatible server; disabled means that file is removed.

## Runtime

The runtime follows the shape of Apple's `MLXChatExample`: model descriptors, a loader/cache layer, message mapping to `UserInput(chat:)`, then `ModelContainer.prepare(input:)` and `ModelContainer.generate(input:parameters:)`.

Server usage should go through `MLXServerRuntime`:

```swift
let runtime = MLXServerRuntime()
let catalog = try MLXServerModelsManifestStore.loadRequired().catalog
let stream = try await runtime.generate(
    request: MLXServerGenerationRequest(
        model: try catalog.resolve(id: nil),
        messages: [
            .system("You are a helpful assistant."),
            .user("ciao")
        ]
    )
)
```

`MLXServerRuntime` is an actor and has no UI isolation. Concurrent requests for the same unloaded model share a single load task instead of starting duplicate downloads. Generation is gated to one active request at a time so concurrent API calls do not split GPU throughput and drop per-request tok/s.

## HTTP API

The server reads runtime settings only from `settings.json`; command line flags do not change host, port, TLS, HTTP/2, metrics logging, model retention, or disk KV cache behavior.

Run the optimized server:

```bash
swift run -c release mlx-server
```

Supported routes:

- `GET /health`
- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/responses`
- `POST /v1/messages`

The three generation endpoints support non-stream JSON responses and SSE streaming with `stream: true`.

Protocol mapping is handled inside the HTTP layer:

- Chat Completions returns `message.content`, `message.reasoning_content`, and `tool_calls`.
- Responses returns `message`, `reasoning`, and `function_call` output items.
- Anthropic Messages returns `text`, `thinking`, and `tool_use` content blocks.

Non-stream responses include `mlx_metrics` with the internal MLX `GenerateCompletionInfo` rates:

```json
{
  "mlx_metrics": {
    "prompt_tokens_per_second": 53.0,
    "generation_tokens_per_second": 29.0
  }
}
```

The executable prepares `mlx.metallib` automatically from the checked-out `mlx-swift` package when SwiftPM has not copied it next to the binary yet. It also enables `MLX_METAL_FAST_SYNCH=1` by default unless the environment already defines it.

## Terminal Chat

The chat path runs the same session runtime used by the server, but without starting HTTP. It keeps the conversation alive until stdin closes; in an interactive terminal, press `Ctrl+D` to exit:

```bash
swift run -c release mlx-server \
  --chat \
  --max-tokens 256 \
  --min-generation-tokens-per-second 29
```

You can also pass the first message directly. After that first answer, the process keeps reading more turns until EOF:

```bash
swift run -c release mlx-server --chat Ciao --max-tokens 256
```

Each turn prints prompt/generation token counts and tok/s. If a turn falls below `--min-generation-tokens-per-second`, the command exits with an error. This is useful before changing the runtime, protocol adapters, cache behavior, or model loading code.

The helper script wraps the same command:

```bash
./Scripts/benchmark.sh
```

## Commands

```bash
swift test
swift build -c release --product mlx-server
swift run -c release mlx-server --help
swift run -c release mlx-server --setup
swift run -c release mlx-server --setup-models
swift run -c release mlx-server --setup-agents
swift run -c release mlx-server --chat
swift run -c release mlx-server --chat Ciao --max-tokens 256 --min-generation-tokens-per-second 29 --quiet
./Scripts/benchmark.sh
```

Quick checks:

```bash
curl -s http://127.0.0.1:8080/health

curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Ciao"}],"max_tokens":128}'
```
