# mlx-coder

Standalone Swift Package for the `mlx-coder` terminal agent and its shared
`MLXCoderCore` library.

`mlx-coder` can run as an interactive terminal UI, as an ACP JSON-RPC agent over
stdio, or as a library embedded by another Swift app.

## Requirements

- Swift 6.2 or newer
- macOS 14 or newer for the native macOS features
- Linux is supported by SwiftPM for the standalone package, with platform-specific
  features disabled when the required Apple frameworks are not available

## Package Products

- `MLXCoderCore`: shared library with the agent runtime, TUI, ACP bridge, tools,
  settings, profiles, support-file management, model configuration, and provider
  clients.
- `mlx-coder`: standalone executable target.

## Build

```bash
swift build
```

For a release binary:

```bash
swift build -c release
```

The release executable is created at:

```text
.build/release/mlx-coder
```

## First Setup

Run setup before the first standalone launch:

```bash
swift run mlx-coder --setup
```

or, after building a release binary:

```bash
.build/release/mlx-coder --setup
```

Setup creates and updates the standalone support files, configures providers and
models, then starts `mlx-coder`.

The required support files are:

- `AGENTS.md`
- `MEMORY.md`
- `agents.json`
- `settings.json`

By default, the standalone executable stores those files in the directory that
contains the `mlx-coder` binary. This keeps a copied standalone binary
self-contained. When `mlx-coder` is embedded in a macOS `.app` bundle, support
files are stored in the app's writable Application Support directory instead of
`Contents/MacOS`.

To force another support directory:

```bash
MLX_CODER_SUPPORT_DIRECTORY=/path/to/mlx-coder-data mlx-coder --setup
```

## Providers

The setup wizard supports:

- OpenAI-compatible providers, including `mlx-server`
- ChatGPT Subscription on macOS

For OpenAI-compatible providers, the wizard can load model metadata from the
provider `/models` endpoint. When available, context window, thinking support,
and generation parameter metadata are imported automatically.

For ChatGPT Subscription, `mlx-coder` checks for valid credentials first. If a
valid token exists, it is reused. If it is expired and refreshable, it is
refreshed. If credentials are missing or invalid, the wizard starts the Codex web
sign-in flow and stores the resulting credentials in Keychain.

## Run

Interactive terminal UI:

```bash
mlx-coder
```

Start from a specific workspace:

```bash
mlx-coder --cwd /path/to/project
```

Use a specific agent profile or model:

```bash
mlx-coder --agent Default --model gpt-5.5
```

Show help:

```bash
mlx-coder --help
```

## ACP Mode

ACP mode is intended for clients that speak ACP JSON-RPC over stdio:

```bash
mlx-coder --acp --cwd /path/to/project
```

In ACP mode, stdout is reserved for ACP JSON-RPC messages.

## Runtime Options

```text
--setup                Create support files, configure providers/models, then start.
--acp                  Run ACP JSON-RPC over stdio.
--app                  App-hosted behavior with quieter runtime output.
--agent NAME           Select an agent profile from agents.json.
--model MODEL_ID       Override the selected model for this run.
--cwd PATH             Working directory for local tools.
--skills LIST          Initial chat skill selection: name, number, all, or none.
--max-tool-rounds N    Maximum model/tool loop rounds per prompt. Default: 100.
--max-output-tokens N  Maximum generated tokens per model call.
--bearer-token TOKEN   Fallback bearer token for configured remote providers.
--verbose              Show status and tool progress on stderr.
--version              Print the version.
--help                 Print help.
```

Environment variables mirror the main runtime options:

```text
MLX_CODER_AGENT_MODE
MLX_CODER_AGENT_NAME
MLX_CODER_AGENT_MODEL
MLX_CODER_AGENT_CWD
MLX_CODER_AGENT_SKILLS
MLX_CODER_AGENT_VERBOSE
MLX_CODER_AGENT_APP
MLX_CODER_AGENT_BEARER_TOKEN
MLX_CODER_SUPPORT_DIRECTORY
```

Legacy `SWIFTMLX_AGENT_*` names are still accepted.

## Terminal Commands

In chat mode:

- `/agents` switches agent profiles without restarting.
- `/tools` enables or disables local, shell, search, git, memory, sub-agent,
  Xcode, and Figma tools.
- `/skills` changes the active prompt skills.

## Permissions

The standalone TUI asks for workspace trust before allowing local file, shell,
Git, and workspace-scoped tools to operate in a directory.

macOS may also show permission dialogs for operations that require system access.

## Library Usage

Add the package to another Swift package:

```swift
.package(url: "https://github.com/<owner>/mlx-coder.git", from: "0.1.0")
```

Then depend on `MLXCoderCore`:

```swift
.product(name: "MLXCoderCore", package: "mlx-coder")
```

Minimal command-line embedding:

```swift
import MLXCoderCore

@main
struct MyCoderHost {
    static func main() async {
        await MLXCoderCommandLineRunner.main(arguments: CommandLine.arguments)
    }
}
```

Apps can also use the lower-level runtime types in `MLXCoderCore`, including
`AgentCoreSessionRunner`, `AgentCoreSessionConfiguration`,
`AgentSettingsManifestStore`, `AgentProfileStore`, and
`MLXCoderSupportFileService`.

## Development

Build the package:

```bash
swift build
```

Run the executable from source:

```bash
swift run mlx-coder
```

Run setup from source:

```bash
swift run mlx-coder --setup
```

## License

See `LICENSE`.
