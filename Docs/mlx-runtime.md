# Local MLX Runtime

`mlx-coder --mlx` runs the coding agent with the local MLX runtime embedded in the same process. It does not start an HTTP server.

## Setup

```bash
mlx-coder --mlx --setup
mlx-coder --mlx --setup-models
```

The setup writes:

```text
~/.mlx-coder/mlx/settings.json
~/.mlx-coder/mlx/models.json
~/.mlx-coder/mlx/KVCaches/
```

If the new files do not exist, legacy `settings.json` and `models.json` can be imported automatically from `~/.mlx-server/`.

## Run

```bash
mlx-coder --mlx --cwd /path/to/project
mlx-coder --mlx --agent Feature --model qwen3-mlx --cwd /path/to/project
mlx-coder --mlx --acp --cwd /path/to/project
```

## KV Cache Persistence

The local MLX runtime keeps a per-session KV cache so a continued conversation
does not re-prefill the whole transcript on every turn. The live cache lives in
memory during a session and is persisted to disk in `~/.mlx-coder/mlx/KVCaches/`.

Persistence behavior:

- The disk cache is written when a session is closed (ACP `session/close`) or
  when the runtime shuts down, not after every request.
- On reconnect, the cache is restored from disk through `session/load`,
  `session/resume`, and `session/new` when the request carries transcript
  history.
- Cache lookup is keyed by session identity. When an ACP client provides a
  `sessionKey`/`cacheKey`, that key is used. When no key is provided, the
  runtime derives a stable key from the conversation opening (system prompt and
  first user message), so stateless clients that resend their transcript still
  reuse the cache across reconnections, even without a `session_id`.
- A restore only succeeds when the model, cache layout, tools, and the stored
  transcript prefix match the incoming request; otherwise the runtime falls
  back to a normal prefill.

Empty the disk cache with:

```bash
mlx-coder --mlx --reset-disk-cache
```

## Reset

```bash
mlx-coder --mlx --reset
mlx-coder --mlx --reset-disk-cache
```

`--reset` removes managed MLX settings and model catalog files from both the new `~/.mlx-coder/mlx/` location and the legacy `~/.mlx-server/` location.
