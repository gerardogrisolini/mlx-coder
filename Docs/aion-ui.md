# Aion UI

`mlx-server` non configura Aion UI automaticamente. Aion UI può eseguire
gli agent locali tramite ACP stdio usando dei Custom Agent manuali.

## Custom Agent: `mlx-coder`

In Aion UI, apri *Edit Custom Agent* e imposta:

- **Display Name**: `mlx-coder`
- **Command**: `mlx-coder`
- **Arguments**: `--acp`
- **Environment Variables**: nessuna

## Custom Agent: `mlx-server` (modalità coder)

In Aion UI, apri *Edit Custom Agent* e imposta:

- **Display Name**: `mlx-server`
- **Command**: `mlx-server`
- **Arguments**: `--coder --acp`
- **Environment Variables**: nessuna
