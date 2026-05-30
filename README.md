# mlx-server

`mlx-server` is a standalone Swift Package that runs local MLX language models behind API-compatible HTTP endpoints and includes the `mlx-coder` agent runtime.

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
- Provides `mlx-coder` as a separate executable backed by the same package sources, plus a direct `mlx-server --coder` mode that runs it against the local MLX runtime without HTTP or ACP.

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
- `Sources/MLXServerSetup`: server, model, and agent integration setup.
- `Sources/MLXCoderCore`: reusable coder agent runtime, TUI, tools, skills, ACP, and shared prompt/config logic.
- `Sources/MLXCoderSetup`: interactive setup for standalone `mlx-coder`.
- `Sources/mlx-server`: command line executable.
- `Sources/mlx-coder`: command line executable.
- `Tests/MLXServerCoreTests`: core tests.
- `Tests/MLXServerHTTPTests`: end-to-end HTTP tests for the supported protocols.
- `Scripts/benchmark.sh`: repeatable local performance benchmark.

## Dependencies

- [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) on `main`.
- `MLXServerCore` currently links `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`, and `MLXVLM`.
- `MLXServerHTTP` uses SwiftNIO, NIO HTTP/2, and NIO SSL.
- `HuggingFace` and `Tokenizers` are linked directly for the MLX Hugging Face downloader/tokenizer macros.
- `MLXCoderCore` uses Swift Crypto for local token and auth support.

## Configuration Files

The server uses two explicit files under `~/.mlx-server/`. There is no fallback list and no cache-folder scan at request time.

- `~/.mlx-server/settings.json`: host, port, TLS, HTTP/2, metrics log, disk KV cache, and model retention policy.
- `~/.mlx-server/models.json`: the exposed model ids, Hugging Face repositories, generation defaults, and thinking configuration.

Run setup once:

```bash
swift run -c release mlx-server --setup
```

The setup writes `settings.json` under `~/.mlx-server/` and then asks whether to configure models too. If accepted, it starts model setup and writes `models.json` in the same directory.

## Model Loading

Models are configured through `models.json`, created by the interactive model setup:

```bash
swift run -c release mlx-server --setup-models
```

The setup searches Hugging Face with the MLX filter, downloads the selected repository into the Hugging Face cache, imports the context window from `config.json`, generation defaults from `generation_config.json`, and thinking metadata from the model metadata/template files when available, then writes the model record to `models.json`.

For each model the setup shows the detected parameters and asks whether to edit them. If accepted, it lets you set the exposed model id, context window, `max_output_tokens`, sampling defaults, repetition penalty, and presence/frequency penalties. Thinking support, effort levels, and preserve-thinking support are detected automatically from the model metadata/template instead of being entered by hand.

On the first run, if `models.json` does not exist yet, the setup also offers to import model snapshots that are already present in the Hugging Face cache. Each imported model still goes through the same generation parameter prompts before it is written to `models.json`.

When run directly, model setup also asks whether the server should keep only one model loaded at a time. That setting is stored in `settings.json`; when enabled, the runtime unloads the current model before loading a different one.

`models.json` is the only source used by `/v1/models` and by request model resolution. The server does not scan cache folders or keep a hardcoded fallback model list.

## Agent Profiles

`mlx-coder` agent profiles are configured through `agents.json`:

```bash
swift run -c release mlx-coder --setup-agents
```

The setup can create the six recommended profiles (`Default`, `Bugfix`, `Feature`, `Review`, `Research`, `Refactor`) or a custom list. It also lets you edit tools, skills, model overrides, symbols, and instructions before saving.

## Reset

Two maintenance commands are available when you want to start over:

```bash
swift run -c release mlx-server --reset
swift run -c release mlx-server --reset-disk-cache
```

`--reset` deletes the managed configuration files in `~/.mlx-server/` and `~/.mlx-coder/`: `settings.json`, `models.json`, `agents.json`, `AGENTS.md`, and `MEMORY.md`.

`--reset-disk-cache` empties the configured disk KV cache directory. If `settings.json` is missing, it uses the default `~/.mlx-server/KVCaches` location.

## Agent Integrations

External agent integrations are configured through a dedicated setup:

```bash
swift run -c release mlx-server --setup-agents
```

The setup reads the current external configuration files as the source of truth, shows what is already active, then lets you enable or disable:

- Codex CLI through the `mlx-server` profile in `~/.codex/config.toml`.
- Codex App through the `mlx-server-codex-app` profile in `~/.codex/config.toml`.
- Codex in Xcode through `~/Library/Developer/Xcode/CodingAssistant/codex/config.toml`.
- Claude Code in Xcode through `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json`.

When a Codex CLI or Codex App integration is enabled, setup writes the local `mlx-server` model provider, the dedicated profile, and a small `mlx-server-codex-models.json` catalog pointing at the selected model. Codex in Xcode uses the same local provider but writes the active top-level model settings in Xcode's dedicated Codex config, because Xcode runs Codex through that CLI configuration. When an integration is disabled, setup removes only the entries it owns.

Claude Code in Xcode is intentionally simpler: enabled means the dedicated Xcode Claude settings file exists and points at the local Anthropic-compatible server; disabled means that file is removed.

## mlx-coder

The package also builds `mlx-coder`:

```bash
swift run -c release mlx-coder --setup
swift run -c release mlx-coder
```

`mlx-coder` keeps its own setup files under `~/.mlx-coder/` (`AGENTS.md`, `MEMORY.md`, `agents.json`, and `settings.json`) and can still run as a standalone terminal agent. The server executable can also host the same coder runtime directly:

```bash
swift run -c release mlx-server --coder --cwd /path/to/project
```

In direct mode, `mlx-coder` uses the configured `mlx-server` model catalog and local MLX runtime without going through HTTP or ACP.

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

The server reads runtime settings only from `~/.mlx-server/settings.json`; command line flags do not change host, port, TLS, HTTP/2, metrics logging, model retention, or disk KV cache behavior.

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
  --max-tokens 256
```

You can also pass the first message directly. After that first answer, the process keeps reading more turns until EOF:

```bash
swift run -c release mlx-server --chat Ciao --max-tokens 256
```

Each turn prints prompt/generation token counts and tok/s, which is useful before changing the runtime, protocol adapters, cache behavior, or model loading code.

The helper script wraps the same command:

```bash
./Scripts/benchmark.sh
```

## Commands

```bash
swift test
swift build -c release --product mlx-server
swift build -c release --product mlx-coder
swift run -c release mlx-server --help
swift run -c release mlx-server --setup
swift run -c release mlx-server --setup-models
swift run -c release mlx-server --setup-agents
swift run -c release mlx-server --reset
swift run -c release mlx-server --reset-disk-cache
swift run -c release mlx-coder --setup
swift run -c release mlx-coder --setup-agents
swift run -c release mlx-server --chat
swift run -c release mlx-server --coder --cwd /path/to/project
swift run -c release mlx-server --chat Ciao --max-tokens 256 --quiet
./Scripts/benchmark.sh
```

Quick checks:

```bash
curl -s http://127.0.0.1:8080/health

curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Ciao"}],"max_tokens":128}'
```
