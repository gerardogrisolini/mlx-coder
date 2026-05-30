# Dynamic Swift Features

Dynamic features are small Swift executables launched by the mlx-coder kernel.
They are discovered from:

- bundled feature binaries next to the `mlx-coder` executable;
- generated feature packages under `~/.mlx-coder/features`.

Generated features are intentionally plain Swift 6.3 packages. The kernel never
loads feature code in-process: it starts the compiled executable, sends JSON on
stdin, and expects a JSON response on stdout.

## Package Layout

Use this layout for agent-generated features:

```text
~/.mlx-coder/features/<feature-id>/
  feature.json
  Package.swift
  Sources/<FeatureTarget>/main.swift
  .build/release/<feature-binary>
```

The executable should use `MLXFeatureKit` and support:

```text
<feature-binary> --list-tools
<feature-binary> --invoke <tool-name> --working-directory <path>
```

`MLXFeatureRunner.run(...)` already implements that process protocol for bundled
features. Agent-generated scaffolds may also implement the same small protocol
directly to stay dependency-free. Every generated `Package.swift` must start
with:

```swift
// swift-tools-version: 6.3
```

## Manifest

`feature.json` is the kernel contract. The current schema is version 1 and is
backward compatible with the original minimal manifest.

```json
{
  "schemaVersion": 1,
  "id": "example-feature",
  "displayName": "Example Feature",
  "description": "Short human-readable summary.",
  "enabled": true,
  "executable": ".build/release/example-feature",
  "discoversToolsAtRuntime": false,
  "toolNamePrefixes": ["example."],
  "toolNameAliases": [],
  "build": {
    "system": "swiftpm",
    "packagePath": ".",
    "product": "example-feature",
    "configuration": "release",
    "executablePath": ".build/release/example-feature"
  },
  "generated": {
    "by": "mlx-coder",
    "prompt": "Original user or agent request.",
    "createdAt": "2026-05-30T12:00:00Z"
  },
  "tools": [
    {
      "name": "example.echo",
      "description": "Echoes text.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "text": { "type": "string" }
        },
        "required": ["text"]
      }
    }
  ]
}
```

Required fields:

- `id`: stable feature identifier.
- `enabled`: whether the kernel should load the feature.
- `executable`: path to the executable, relative to `feature.json` unless absolute.
- `tools`: static tool descriptors. Use an empty array when the feature discovers tools dynamically.

Optional fields:

- `schemaVersion`: schema version; omit for legacy manifests.
- `displayName`, `description`: shown by `feature.list`.
- `discoversToolsAtRuntime`: when true, the kernel calls `--list-tools` only when the feature is relevant to the selected tools.
- `toolNamePrefixes`: prefixes used to route dynamic tools before the kernel has listed them.
- `toolNameAliases`: exact non-prefixed tool names accepted by the feature.
- `build`: SwiftPM build metadata for future rebuild/install commands.
- `generated`: provenance metadata from the agent.

## Runtime Rules

- `local.exec`, `local.*` file tools, and `text.*` tools are always core and
  must not be implemented by a feature.
- Bundled features are enabled or disabled through `~/.mlx-coder/feature-state.json`.
- Generated features are enabled or disabled by updating their own `feature.json`.
- `feature.reload` reloads manifests and clears runtime-discovered tool caches.
- `feature.scaffold` creates a dependency-free Swift 6.3 SwiftPM package.
- `feature.validate` checks manifest shape, reserved tool names, duplicate names,
  executable state, and SwiftPM tools version.
- `feature.build` runs `swift build -c release --product <product>` for SwiftPM
  feature packages and reloads the runtime when the executable is produced.
- `feature.install` copies a generated feature package into
  `~/.mlx-coder/features/<feature-id>`, skips transient folders such as `.build`,
  validates it, builds it by default, and enables it by default when the build
  succeeds.
- The `features` tool group exposes `feature.*` commands plus the internal
  `feature.tools` token, which allows generated feature tools without enabling
  unrelated bundled groups such as `git.*`, `web.*`, or `search.*`.

## Agent Workflow

Agents should create generated features only for reusable missing capabilities,
not for one-off shell commands or simple file edits. When a generated feature is
appropriate, the lifecycle is:

1. Call `feature.scaffold` with a stable feature id and tool name.
2. Edit the generated Swift package under `~/.mlx-coder/features/<feature-id>`.
3. Run `feature.validate` to catch manifest, naming, executable, and SwiftPM
   tools-version issues.
4. Run `feature.build`.
5. Call `feature.enable` for a new disabled feature, or `feature.reload` after
   rebuilding an already enabled one.

If the package was generated or staged outside `~/.mlx-coder/features`, call
`feature.install` with the source `path` instead. It performs the copy/build/
enable flow and leaves the source package untouched.

Generated tool names must stay out of the reserved `feature.*` namespace and
must never shadow core tools such as `local.exec`, `local.readFile`, or
`text.wc`.
