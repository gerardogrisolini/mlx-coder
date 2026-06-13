# Aion UI

Aion UI può eseguire gli agent locali tramite ACP stdio usando dei Custom Agent
manuali.

## Custom Agent: `mlx-coder`

In Aion UI, apri *Edit Custom Agent* e imposta:

- **Display Name**: `mlx-coder`
- **Command**: `mlx-coder`
- **Arguments**: `--acp`
- **Environment Variables**: nessuna

## Custom Agent: `mlx-coder` con MLX locale

In Aion UI, apri *Edit Custom Agent* e imposta:

- **Display Name**: `mlx-coder MLX`
- **Command**: `mlx-coder`
- **Arguments**: `--mlx --acp`
- **Environment Variables**: nessuna
