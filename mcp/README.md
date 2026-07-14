# toscanini-mcp

Servidor MCP (Bun/TypeScript) que expõe as operações do orquestrador Toscanini
como tools para o Claude Code. É um proxy fino sobre a API HTTP do Toscanini
(`/api/orchestrator/*`).

## Tools

`submit_job`, `submit_batch`, `get_job`, `get_batch`, `wait_job`, `wait_batch`,
`find_job_by_url`, `prioritize_job`, `publish_podcast`, `get_scheduler_config`,
`set_scheduler_config`, `subscribe_feed`, `list_feeds`, `check_feed_now`,
`unsubscribe_feed`, `get_feeds_config`, `set_feeds_config`.

## Rodar

```
PORT=8006 TOSCANINI_URL=http://localhost:8080/api/orchestrator bun run server.ts
```

## Deploy (HermesTools)

O serviço roda como `toscanini-mcp.service`, hoje a partir de
`/home/hermes/services/toscanini-mcp/`. Esta pasta no repo é a **fonte
versionada**; sincronizar o dir do serviço com ela ao publicar mudanças, depois
`systemctl restart toscanini-mcp`.
