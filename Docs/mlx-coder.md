# mlx-coder Guide

`mlx-coder` is the autonomous coding agent runtime included in this repository. It can run as a standalone terminal agent, as an ACP stdio agent for compatible clients, or through `mlx-server --coder` to use the local MLX runtime directly without HTTP.

Use this guide to set up providers, agent profiles, tools, skills, saved sessions, memory, and day-to-day terminal commands.

## Modes

`mlx-coder` supports three practical launch modes:

1. Standalone chat TUI:

   ```bash
   swift run -c release mlx-coder
   ```

2. ACP over stdio for compatible clients:

   ```bash
   swift run -c release mlx-coder --acp
   ```

3. Direct local MLX runtime through the server executable:

   ```bash
   swift run -c release mlx-server --coder --cwd /path/to/project
   ```

Standalone `mlx-coder` uses providers/models from `~/.mlx-coder/settings.json`. Direct `mlx-server --coder` uses the local `~/.mlx-server/models.json` catalog and `MLXServerRuntime` directly.

## First Setup

Create standalone support files and configure providers/models:

```bash
swift run -c release mlx-coder --setup
```

Create or update agent profiles (last section of `--setup`):

```bash
swift run -c release mlx-coder --setup
```

The first setup creates files under `~/.mlx-coder/`. During setup you can also
enable Telegram remote control, pair the bot once, enable local voice tools, and
store those settings in `settings.json`.

- `settings.json`: provider/model configuration, selected model, optional Telegram remote control token plus linked chat, and optional local voice tool settings.
- `permissions.json`: persistent runtime approvals such as allowed `local.exec` commands.
- `agents.json`: agent profiles, model overrides, tool selection, symbols, and instructions.
- `AGENTS.md`: global operating guidance for the agent.
- `MEMORY.md`: lightweight global resume index used only when a session does not start in a clear project.
- `sessions/`: saved session snapshots grouped by project.
- `features/`: generated Swift feature packages when the Builder agent creates reusable tools.

## Command Line Options

```text
mlx-coder [--setup] [--reset] [--acp] [--agent NAME] [--model MODEL_ID] [--cwd PATH] [--skills LIST]
```

Important options:

- `--setup`: create standalone support files and configure providers, models, and agents, then exit. The agent profiles are configured in the last section of the setup menu.
- `--reset`: delete managed files in `~/.mlx-coder/`, then exit.
- `--acp`: run ACP JSON-RPC over stdio instead of terminal chat.
- `--agent NAME`: select an agent profile from `agents.json`; defaults to `Default` when omitted.
- `--model MODEL_ID`: override the agent-selected model for this run. Accepted forms include a model id, `remoteapimodel:<uuid>`, or `remoteapi:<uuid>`.
- `--cwd PATH`: working directory for local tools. Defaults to the current directory, or home when launched from the executable directory.
- `--skills LIST`: initial skill selection by name/number, `all`, or `none`.
- `--max-tool-rounds N`: maximum model/tool loop rounds per prompt. The default is shown by `mlx-coder --help`.
- `--max-output-tokens N`: maximum generated tokens per model call. Default: model default.
- `--verbose`: show status/tool progress on stderr. Default chat output is quiet.

Environment variables mirror the main options:

- `MLX_CODER_AGENT_MODE`: `chat`, `acp`, or `auto`; auto resolves to chat.
- `MLX_CODER_AGENT_NAME`: agent profile name.
- `MLX_CODER_AGENT_MODEL`: model override.
- `MLX_CODER_AGENT_CWD`: working directory.
- `MLX_CODER_AGENT_SKILLS`: initial skill selection.
- `MLX_CODER_AGENT_VERBOSE`: `1` or `true` for verbose progress.
- `MLX_CODER_AGENT_BEARER_TOKEN`: fallback bearer token for configured remote providers.

Legacy `SWIFTMLX_AGENT_*` environment names are still accepted.

## Agent Profiles

Agent profiles live in `~/.mlx-coder/agents.json` and are managed in the Agents
section of the setup menu:

```bash
swift run -c release mlx-coder --setup
```

The setup can create the recommended profiles:

- `Default`: general coding assistant.
- `Bugfix`: focused debugging and regression fixes.
- `Feature`: implementation work for new functionality.
- `Review`: code review and risk analysis.
- `Research`: investigation and information gathering.
- `Refactor`: structure-preserving cleanup.

Profiles can define enabled tools, skills, model overrides, symbols, and extra instructions. In the TUI you can switch profiles without restarting:

```text
/agents
/agents list
/agents Bugfix
/agents 2
```

Switching profiles resets the active conversation so the new system prompt and tool set are cleanly applied.

## Terminal TUI Commands

Inside chat mode, type a prompt and press return. Commands start with `/`:

- `/help`: show command help.
- `/models`: show configured models and switch the current session model.
- `/agents [list|<agent name>|<number>]`: switch agent profile.
- `/tools [all|none|tool-name|package-name|tool-number]`: select which tool groups are exposed to the model.
- `/skills`: select installed prompt skills or install a skill from GitHub/local folder.
- `/sessions [session name]`: list/load sessions, or save a named session snapshot for the current project.
- `/sessions save`: refresh the currently active saved session. If no saved session is active yet, use `/sessions <session name>` first.
- `/sessions delete`: delete a saved session snapshot.
- `/attach <file> [file ...]`: attach image/video files to the next prompt.
- `/attachments`: list pending attachments.
- `/detach [all|number]`: remove pending attachments.
- `/retry`: rerun the most recent failed prompt.
- `/changes`: show the latest tracked file change summary.
- `/changes diff`: include patches in the change summary.
- `/undo`: revert the most recent tracked file changes created by the agent.
- `/subagents`: show delegated sub-agent status.
- `/subagents off`: hide automatic sub-agent status updates.
- `/telegram`: show Telegram status for the current TUI session.
- `/telegram on`: turn Telegram on for the current TUI session.
- `/telegram off`: turn Telegram off for the current TUI session.
  This command is available only after Telegram was enabled and paired during `mlx-coder --setup`; otherwise it is treated as unknown.
- `/voice`: start recording a voice prompt. Press `Enter` again to stop; the transcript becomes the prompt.
  This command is available only after local voice tools were enabled during `mlx-coder --setup`; otherwise it is treated as unknown.
- `/speak`: synthesize and play the last assistant response.
  This command is available only after local voice tools were enabled during `mlx-coder --setup`; otherwise it is treated as unknown.
  Long responses are shortened and stripped of code blocks before speech synthesis.
  Audio generation is macOS-only, so this command is hidden on Linux.
- `/clear`: reset the conversation.
- `/exit`: close the session.

Interactive terminals also support `Ctrl+T` to toggle compact/full tool output.

## Tool Selection

Tools are not just shell access. Depending on profile, mode, and environment, tool groups can include:

- local filesystem reads/writes;
- shell execution;
- text utilities;
- search tools;
- Git tools;
- memory tools;
- sub-agent delegation;
- Xcode tools when Xcode is running and exposed through MCP;
- Figma tools when the local Figma desktop MCP server exposes tools;
- generated Swift feature tools;
- bundled feature tools such as search, web, git, Xcode, Figma, or Jira integrations.

Use `/tools` to inspect and select the tool groups for the current session. ACP clients can pass the enabled tools to the runtime directly.

## Skills

Skills are prompt modules that can be selected per session. Use:

```text
/skills
```

The TUI can select installed skills or install a skill from GitHub or a local folder. Start with `--skills LIST` when you want a fixed initial selection for a run:

```bash
swift run -c release mlx-coder --skills all
swift run -c release mlx-coder --skills none
swift run -c release mlx-coder --skills "review,swift"
```

## Attachments

Use attachments for image or video context in models/providers that support it:

```text
/attach screenshot.png demo.mov
/attachments
/detach 1
/detach all
```

Attachments are applied to the next prompt, then the session continues with the normal conversation history.

## Local Voice Tools

When installed from Homebrew, `mlx-voice-transcriber` is installed alongside
`mlx-coder` and setup detects it automatically.

In a source checkout, setup can build the local Swift voice executable
automatically. You can also build it manually:

```bash
cd Tools/MLXVoiceTranscriber
swift build -c release
```

Then enable voice tools during:

```bash
swift run -c release mlx-coder --setup
```

The setup discovers the installed `mlx-voice-transcriber` path automatically. If
it is not installed but the source checkout is available, setup builds the local
voice package and stores the produced release executable path. It then stores the
selected speech-to-text model, language, and, on macOS, the selected system voice in
`settings.json`. No external API key is required. The default speech-to-text
model is `tiny` so the first run stays quick; `large-v3-v20240930_626MB` remains
available from setup when you want better multilingual accuracy and accept a
slower initial download and load.

In the TUI, run:

```text
/voice
```

Recording starts immediately. Press `Enter` to stop recording; `mlx-coder`
transcribes the audio and sends the transcript as the prompt. If Telegram remote
control is active, Telegram voice messages use the same transcription pipeline
and receive the final response as audio instead of text when `mlx-coder` is
running on macOS. On Linux, audio generation is not enabled and Telegram receives
the final response as text.

To play the latest assistant response locally:

```text
/speak
```

For faster playback, long responses are converted to a shorter spoken version
before synthesis. The full text remains visible in the TUI.

When used from Telegram on iOS, the audio is still generated by the Mac running
`mlx-coder` and uploaded to Telegram as an `.m4a` file.

The voice executable also supports text-to-speech:

```bash
mlx-voice-transcriber synthesize --text "Ciao" --output reply.m4a --language it --voice Alice
```

## Saved Sessions

Saved sessions are explicit snapshots under `~/.mlx-coder/sessions/` for the current project.

Save a named session:

```text
/sessions my-feature
```

Refresh the active saved session after more work:

```text
/sessions save
```

List and load sessions:

```text
/sessions
```

Delete a session:

```text
/sessions delete
```

Local MLX sessions save the runtime snapshot. Remote sessions save the local transcript, including tool calls and outputs, so a remote `mlx-server` can reuse disk KV cache when the restored prompt prefix matches.

When `/sessions <name>` saves a session, `mlx-coder` updates one active global resume pointer for that project while leaving pointers for other projects intact. `/sessions save` rewrites that active saved session; if no saved session is active yet, it asks for an explicit session name instead of creating a session named `save`.

## Memory and Project Context

`mlx-coder` separates durable context by responsibility:

- Project `MEMORY.md` in a workspace is the codebase journal. It should contain concise handoff entries with `Timestamp`, `Summary`, `State`, and `Next`.
- Global `~/.mlx-coder/MEMORY.md` is only a lightweight resume index for sessions that do not start inside a clear project.
- Operating rules, team conventions, and preferences belong in `AGENTS.md`, not in memory.

A good project memory entry records durable state, decisions, blockers, and next steps. It should not record every command, raw output, or facts obvious from the files.

## File Change Tracking

The terminal runtime tracks file edits made by the agent during a turn. Use:

```text
/changes
/changes diff
/undo
```

`/undo` targets the most recent tracked changes made by the agent. It is intended as a safety mechanism for agent edits, not as a general replacement for Git.

## Dynamic Swift Features

Generated features are reusable Swift tool packages managed by the Builder agent. Switch to the Builder profile, then use:

```text
/feature
/feature list
/feature enable <id|name|#>
/feature disable <id|name|#>
/feature build <id|name|#>
/feature validate <id|name|#>
/feature reload
/feature delete <id|name|#>
```

Features are discovered from bundled feature binaries and generated packages under `~/.mlx-coder/features`. Generated packages are plain Swift 6.3 packages and run out-of-process over a JSON stdin/stdout protocol.

See the [Builder agent guide](builder.md) for Builder usage and technical feature package notes.

## ACP Mode

ACP mode is for clients that manage the UI and communicate with the agent over stdio:

```bash
swift run -c release mlx-coder --acp --cwd /path/to/project
```

In ACP mode:

- stdout contains only ACP JSON-RPC messages;
- status or diagnostics should go to stderr when enabled;
- clients provide prompts, sessions, and tool exposure;
- `--agent`, `--model`, `--cwd`, `--skills`, and token environment variables still apply.

## Direct Local Runtime with mlx-server

For fully local MLX inference without HTTP, run:

```bash
swift run -c release mlx-server --coder --cwd /path/to/project
```

This mode:

- reads models from `~/.mlx-server/models.json`;
- uses `MLXServerRuntime` directly;
- respects server model generation defaults and disk KV cache settings;
- can run chat TUI or ACP with `--acp`;
- creates a default project `AGENTS.md` if one is missing.

Example with explicit model and profile:

```bash
swift run -c release mlx-server --coder \
  --cwd /path/to/project \
  --model qwen3-mlx \
  --agent Feature \
  --max-output-tokens 4096 \
  --verbose
```

## Recommended Workflow

1. Run setup once:

      ```bash
   swift run -c release mlx-coder --setup
   ```

2. Start in the target project:

   ```bash
   cd /path/to/project
   swift run -c release mlx-coder --agent Default
   ```

3. Select tools and skills:

   ```text
   /tools
   /skills
   ```

4. Ask the agent to inspect before editing.
5. Review changes with `/changes diff` and Git.
6. Save meaningful checkpoints with `/sessions name`, then refresh the active checkpoint with `/sessions save`.
7. Keep durable project status in project `MEMORY.md` when a session reaches a useful handoff point.

## Troubleshooting

- Setup starts automatically: required `~/.mlx-coder` files are missing; complete `--setup`.
- Model not found: run `/models` or check `~/.mlx-coder/settings.json`; in `mlx-server --coder` mode check `~/.mlx-server/models.json`.
- No tools available: use `/tools`, switch to a profile that permits tools, or check ACP client tool exposure.
- `/feature` unavailable: switch to the Builder agent with `/agents Builder`.
- Xcode tools missing: make sure Xcode is running and MCP bridge tooling can expose tools.
- Figma tools missing: make sure the Figma desktop MCP server is enabled.
- Resume picked the wrong project: start from the intended `--cwd` or project directory, then use `/sessions` for explicit snapshots.
