# mlx-server

`mlx-server` is a Swift Package with two closely related executables and one important local-first workflow:

- **`mlx-server --coder`**: the recommended fully local coding-agent mode. It runs the `mlx-coder` agent directly on `MLXServerRuntime`, using the local MLX model catalog without HTTP.
- **`mlx-coder`**: the standalone autonomous coding agent for the terminal and ACP-compatible clients.
- **`mlx-server`**: the local MLX inference server that exposes downloaded MLX models through OpenAI-compatible, Responses-compatible, and Anthropic-compatible HTTP APIs.

The project is designed for local-first AI development on Apple Silicon: keep models on your Mac, configure them explicitly, expose them to existing agent clients, and run a coding agent that can work directly inside your projects.

## Start Here

### Homebrew (recommended)

Install the latest release through the Homebrew tap:

```bash
brew tap gerardogrisolini/tap
brew install mlx-server
```

Then set up configuration and models:

```bash
mlx-server --setup
mlx-server --setup-models
mlx-server --coder --cwd /path/to/project
```

Upgrade with:

```bash
brew upgrade mlx-server
```

Requires macOS 26 (Tahoe) on Apple Silicon.

### Manual Prebuilt Binary

If you do not want to use Homebrew, install the latest release with the installer script:

```bash
curl -sL https://raw.githubusercontent.com/gerardogrisolini/mlx-server/main/Scripts/install.sh | bash
```

Or download a specific release from [GitHub Releases](https://github.com/gerardogrisolini/mlx-server/releases) and extract manually:

```bash
tar xzf mlx-server-v0.1.1-macos-arm64.tar.gz
sudo cp mlx-server mlx-coder /usr/local/bin/
```

### Build from Source

If your goal is **local coding assistance with MLX models**, start with **`mlx-server --coder`**:

```bash
swift run -c release mlx-server --setup
swift run -c release mlx-server --setup-models
swift run -c release mlx-server --coder --cwd /path/to/project
```

This is the most direct local workflow: one process runs the agent and the MLX runtime together, with no HTTP hop and no external model provider required.

If you want the standalone agent configuration, use **`mlx-coder`**:

```bash
swift run -c release mlx-coder --setup
swift run -c release mlx-coder --setup-agents
swift run -c release mlx-coder --cwd /path/to/project
```

If your goal is serving local MLX models over HTTP, start with **`mlx-server`**:

```bash
swift run -c release mlx-server --setup
swift run -c release mlx-server --setup-models
swift run -c release mlx-server
```

Detailed guides:

- [mlx-coder guide](Docs/mlx-coder.md): standalone/ACP agent setup, profiles, tools, skills, sessions, memory, and dynamic features.
- [mlx-server guide](Docs/mlx-server.md): setup, model catalog, HTTP APIs, metrics, benchmarking, and direct coder mode.

## Why `mlx-server --coder`

`mlx-server --coder` is the bridge between the two parts of the package: it starts the coding agent, but the model backend is the local `mlx-server` runtime instead of a remote provider or an HTTP client.

That means:

- the agent uses the same explicit `~/.mlx-server/models.json` catalog used by the server;
- model loading, generation defaults, thinking settings, KV cache, and disk cache stay in the server runtime path;
- there is no HTTP serialization layer between the agent and the model;
- the TUI still has agent profiles, tools, skills, attachments, saved sessions, memory, `/changes`, `/undo`, sub-agents, and Dynamic Swift Features;
- `--acp` can expose the same direct local runtime to ACP-compatible apps.

Examples:

```bash
swift run -c release mlx-server --coder --cwd /path/to/project
swift run -c release mlx-server --coder --agent Feature --model qwen3-mlx --cwd /path/to/project
swift run -c release mlx-server --coder --acp --cwd /path/to/project
```

## mlx-coder Overview

`mlx-coder` is the agent layer. It provides a terminal coding assistant and an ACP stdio runtime for apps that want to host the UI themselves.

Use it when you want an agent that can:

- work in a specific project directory with `--cwd`;
- use named agent profiles such as `Default`, `Bugfix`, `Feature`, `Review`, `Research`, and `Refactor`;
- select models and tools interactively;
- read, search, edit, and review project files through enabled tools;
- use prompt skills for repeatable workflows;
- attach image/video context when supported by the selected model/provider;
- save, refresh, and restore project sessions with `/sessions`;
- track file changes with `/changes` and revert recent agent edits with `/undo`;
- delegate work to sub-agents;
- create reusable Dynamic Swift Features through the Builder agent.

Common commands:

```bash
swift run -c release mlx-coder --setup
swift run -c release mlx-coder --setup-agents
swift run -c release mlx-coder --agent Feature --cwd /path/to/project
swift run -c release mlx-coder --acp --cwd /path/to/project
```

Useful TUI commands:

```text
/help        Show available commands
/models      Select a model
/agents      Select an agent profile
/tools       Select tool groups
/skills      Select or install prompt skills
/sessions    Save, refresh, load, or delete session snapshots
/changes     Review the latest tracked file changes
/undo        Revert the latest tracked agent changes
/feature     Manage generated Swift features with the Builder agent
/exit        Close the session
```

`mlx-coder` stores its standalone configuration in `~/.mlx-coder/`:

- `settings.json`: providers, models, and selected model.
- `agents.json`: agent profiles and defaults.
- `AGENTS.md`: global operating guidance.
- `MEMORY.md`: lightweight global resume index.
- `sessions/`: saved per-project session snapshots.
- `features/`: generated Swift feature packages.

For a fully local model backend, prefer the `mlx-server --coder` workflow described above.

## mlx-server Overview

`mlx-server` is the inference layer. It loads MLX models through [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm), keeps model/runtime configuration explicit, and exposes local models through familiar HTTP protocols.

Use it when you want:

- a local API server for MLX models;
- `/v1/chat/completions` for OpenAI Chat Completions clients;
- `/v1/responses` for OpenAI Responses clients;
- `/v1/messages` for Anthropic Messages clients;
- `GET /v1/models` backed only by explicit `models.json` entries;
- JSON and Server-Sent Events streaming responses;
- protocol-native thinking/reasoning fields instead of raw `<think>` text;
- tool definition and tool-call payload compatibility;
- throughput metrics in responses and optional JSONL logs;
- disk KV cache reuse and configurable model retention.

Runtime configuration lives in `~/.mlx-server/`:

- `settings.json`: host, port, optional API key, TLS, HTTP/2, metrics log, KV cache, disk KV cache, Hugging Face cache access, and model retention.
- `models.json`: exposed model ids, Hugging Face repositories, generation defaults, and thinking configuration.
- `KVCaches/`: default disk KV cache directory.

The server does not discover models implicitly from cache folders at request time. If a model is not in `models.json`, it is not served.

## HTTP API

Start the server:

```bash
swift run -c release mlx-server
```

Supported routes:

- `GET /health`
- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/responses`
- `POST /v1/messages`

Quick checks:

```bash
curl -s http://127.0.0.1:8080/health
curl -s http://127.0.0.1:8080/v1/models
```

Chat Completions example:

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Authorization: Bearer <api_key>' \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Ciao"}],"max_tokens":128}'
```

If `api_key` is set in `settings.json`, all routes except `GET /health` require either:

```text
Authorization: Bearer <api_key>
X-API-Key: <api_key>
```

## Local Chat and Benchmarking

`mlx-server` also has a lightweight chat path for testing model behavior and tok/s without starting HTTP:

```bash
swift run -c release mlx-server --chat --max-tokens 256
swift run -c release mlx-server --chat Ciao --max-tokens 256 --quiet
./Scripts/benchmark.sh
```

Each turn reports prompt tokens, generation tokens, prefill tok/s, and generation tok/s.

## Agent Client Integrations

Configure external clients with:

```bash
swift run -c release mlx-server --setup-agents
```

The setup can enable or disable owned entries for:

- Codex CLI;
- Codex App;
- Codex in Xcode;
- Claude Code in Xcode.

When disabling an integration, setup removes only the entries it owns.

## Layout

- `Sources/MLXCoderCore`: reusable coder agent runtime, TUI, tools, skills, ACP, prompt/config logic, memory, sessions, and feature management.
- `Sources/MLXCoderSetup`: interactive setup for standalone `mlx-coder`.
- `Sources/mlx-coder`: standalone `mlx-coder` executable.
- `Sources/MLXServerCore`: reusable MLX server runtime, settings, model catalog, loading, generation gate, and disk KV cache.
- `Sources/MLXServerHTTP`: HTTP server, protocol adapters, SSE streaming, and metrics logging.
- `Sources/MLXServerSetup`: server, model, and agent integration setup.
- `Sources/mlx-server`: `mlx-server` executable, chat mode, reset commands, and direct `--coder` mode.
- `Sources/Features`: bundled Dynamic Swift Feature executables.
- `Tests`: SwiftPM test targets.
- `Docs`: detailed guides and feature documentation.
- `Scripts/benchmark.sh`: repeatable local performance benchmark.

## Dependencies

- [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) on `main`.
- `MLXServerCore` links `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`, and `MLXVLM`.
- `MLXServerHTTP` uses SwiftNIO, NIO HTTP/2, and NIO SSL.
- `HuggingFace` and `Tokenizers` are used for model download/import and tokenizer support.
- `MLXCoderCore` uses Swift Crypto and Swift Markdown.

## Common Commands

```bash
swift test
swift build -c release --product mlx-coder
swift build -c release --product mlx-server

swift run -c release mlx-coder --help
swift run -c release mlx-coder --setup
swift run -c release mlx-coder --setup-agents
swift run -c release mlx-coder --cwd /path/to/project
swift run -c release mlx-coder --acp --cwd /path/to/project

swift run -c release mlx-server --help
swift run -c release mlx-server --setup
swift run -c release mlx-server --setup-models
swift run -c release mlx-server --setup-agents
swift run -c release mlx-server
swift run -c release mlx-server --chat
swift run -c release mlx-server --coder --cwd /path/to/project
swift run -c release mlx-server --reset
swift run -c release mlx-server --reset-disk-cache
```

## Reset

```bash
swift run -c release mlx-server --reset
swift run -c release mlx-server --reset-disk-cache
```

`--reset` deletes managed configuration files in `~/.mlx-server/` and `~/.mlx-coder/`: `settings.json`, `models.json`, `agents.json`, `AGENTS.md`, and `MEMORY.md`.

`--reset-disk-cache` empties the configured disk KV cache directory. If `settings.json` is missing, it uses the default `~/.mlx-server/KVCaches` location.
