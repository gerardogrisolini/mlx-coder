# mlx-coder

`mlx-coder` is a Swift Package centered on a local-first coding agent for Apple Silicon.

- **`mlx-coder`** runs the standalone terminal and ACP coding agent with configured providers.
- **`mlx-coder --mlx`** runs the same agent on the local MLX runtime directly, with no HTTP server and no remote provider required.

The old `mlx-server` executable and HTTP API surface have been removed. Local MLX model setup, model catalog management, reset, and runtime launch now live under `mlx-coder --mlx`.

## Install

### Homebrew

```bash
brew tap gerardogrisolini/tap
brew install mlx-coder
```

Upgrade with:

```bash
brew upgrade mlx-coder
```

Requires macOS 26 (Tahoe) on Apple Silicon.

### Installer Script

```bash
curl -sL https://raw.githubusercontent.com/gerardogrisolini/mlx-coder/main/Scripts/install.sh | bash
```

### Build From Source

```bash
swift build -c release --product mlx-coder
```

## Quick Start

Set up the standalone agent:

```bash
mlx-coder --setup
mlx-coder --cwd /path/to/project
```

Set up and run the local MLX runtime:

```bash
mlx-coder --mlx --setup
mlx-coder --mlx --setup-models
mlx-coder --mlx --cwd /path/to/project
```

Run ACP over stdio with the local MLX runtime:

```bash
mlx-coder --mlx --acp --cwd /path/to/project
```

## Local MLX Mode

`mlx-coder --mlx` starts the `mlx-coder` agent with `MLXServerRuntime` embedded in the same process. It does not start a webserver and does not serialize model calls over HTTP.

Useful commands:

```bash
mlx-coder --mlx --help
mlx-coder --mlx --setup
mlx-coder --mlx --setup-models
mlx-coder --mlx --agent Feature --model qwen3-mlx --cwd /path/to/project
mlx-coder --mlx --reset
mlx-coder --mlx --reset-disk-cache
```

Local MLX configuration lives in:

```text
~/.mlx-coder/mlx/settings.json
~/.mlx-coder/mlx/models.json
~/.mlx-coder/mlx/KVCaches/
```

On first use, `mlx-coder --mlx` can import legacy `settings.json` and `models.json` from `~/.mlx-server/` when the new files do not exist.

## TUI Commands

```text
/help        Show available commands
/models      Select a model
/agents      Select an agent profile
/tools       Select tool groups
/skills      Select or install prompt skills
/sessions    Save, refresh, load, or delete session snapshots
/changes     Review the latest tracked file changes
/undo        Revert the latest tracked agent changes
/features    Enable or disable feature packages with the Builder agent
/feature     Create and manage Swift features with the Builder agent
/telegram    Turn Telegram remote control on/off when paired in setup
/voice       Record a voice prompt when local voice tools are enabled in setup
/speak       Play the last assistant response aloud when local voice tools are enabled
/exit        Close the session
```

## Layout

- `Sources/MLXCoderCore`: reusable agent runtime, TUI, tools, skills, ACP, config, memory, sessions, and feature management.
- `Sources/MLXCoderSetup`: interactive setup for standalone `mlx-coder`.
- `Sources/mlx-coder`: `mlx-coder` executable, `--mlx` runtime entrypoint, reset commands, and Metal bootstrap.
- `Sources/MLXServerCore`: reusable local MLX runtime, model catalog, loading, generation gate, and disk KV cache.
- `Sources/MLXServerSetup`: local MLX runtime and model setup used by `mlx-coder --mlx`.
- `Sources/Features`: bundled Dynamic Swift Feature executables.
- `Tests`: SwiftPM test targets.
- `Docs`: detailed guides and feature documentation.

## Common Commands

```bash
swift test
swift build -c release --product mlx-coder

swift run -c release mlx-coder --help
swift run -c release mlx-coder --setup
swift run -c release mlx-coder --cwd /path/to/project
swift run -c release mlx-coder --acp --cwd /path/to/project
swift run -c release mlx-coder --reset

swift run -c release mlx-coder --mlx --help
swift run -c release mlx-coder --mlx --setup
swift run -c release mlx-coder --mlx --setup-models
swift run -c release mlx-coder --mlx --cwd /path/to/project
swift run -c release mlx-coder --mlx --acp --cwd /path/to/project
swift run -c release mlx-coder --mlx --reset
swift run -c release mlx-coder --mlx --reset-disk-cache
```

## More Docs

- [mlx-coder guide](Docs/mlx-coder.md)
- [Local MLX runtime guide](Docs/mlx-runtime.md)
- [Builder agent guide](Docs/builder.md)
- [Aion UI manual setup](Docs/aion-ui.md)
