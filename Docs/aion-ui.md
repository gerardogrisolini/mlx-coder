# Aion UI Manual Setup

`mlx-server` does not configure Aion UI automatically. Aion UI can still run the local agents manually through ACP stdio.

## Prerequisites

Install and open Aion UI using its own installation instructions.

Install or build `mlx-server` and `mlx-coder`, then run the normal project setup:

```bash
mlx-server --setup
mlx-server --setup-models
mlx-coder --setup
mlx-coder --setup-agents
```

If you are running from source, build the release executables first:

```bash
swift build -c release --product mlx-server
swift build -c release --product mlx-coder
```

## Option 1: Standalone `mlx-coder`

Use this when you want Aion UI to launch the standalone coding agent with the providers and profiles from `~/.mlx-coder`.

In Aion UI, create a custom ACP or stdio agent with:

```text
Command: /path/to/mlx-coder
Arguments: --acp --cwd /path/to/project
Working directory: /path/to/project
```

With a Homebrew or manual binary install, find the command path with:

```bash
which mlx-coder
```

From a source build, the command is usually:

```text
/path/to/mlx-server/.build/release/mlx-coder
```

Optional arguments:

```text
--agent Feature
--model <model-id>
--skills all
```

## Option 2: Direct Local MLX Runtime

Use this when you want Aion UI to launch `mlx-coder` through `mlx-server --coder`, using the local `~/.mlx-server/models.json` catalog and `MLXServerRuntime` directly.

In Aion UI, create a custom ACP or stdio agent with:

```text
Command: /path/to/mlx-server
Arguments: --coder --acp --cwd /path/to/project
Working directory: /path/to/project
```

With a Homebrew or manual binary install, find the command path with:

```bash
which mlx-server
```

From a source build, the command is usually:

```text
/path/to/mlx-server/.build/release/mlx-server
```

Optional arguments:

```text
--agent Feature
--model <model-id>
--max-output-tokens 4096
```

## Notes

`mlx-server --setup-agents` only manages Codex CLI, Codex App, Codex in Xcode, and Claude Code in Xcode entries. It does not read, write, register, update, or remove Aion UI configuration.

To update Aion UI later, edit the custom agent command and arguments in Aion UI manually.
