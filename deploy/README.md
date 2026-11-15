# Deployment

## systemd unit

`toscanini.service` é uma cópia versionada do unit instalado em
`/etc/systemd/system/toscanini.service` no host (HermesTools WSL distro).

Valores marcados com `<REDACTED:NOME>` são secrets — substituir pelos
reais ao instalar (cofre pessoal, nunca commitar).

### Pré-requisitos no host

Gerenciados manualmente (instalação inicial, não cobertos pelo script):

- Erlang/Elixir via `asdf` em `/home/hermes/.asdf`
- Whisper venv em `/home/hermes/whisper-venv` (CUDA/cuDNN para GPU)
- `ffmpeg` no PATH (`apt install ffmpeg`)

Gerenciados pelo `setup-host.sh` (rodar como o usuário do serviço):

- `yt-dlp` em `~/.local/bin/yt-dlp` — atualizado a cada execução
- `deno` em `~/.deno/bin/deno` — runtime JS exigido pelo yt-dlp ≥ `2026.06`
  para extração do YouTube

```bash
bash deploy/setup-host.sh
```

Rodar de novo sempre que o yt-dlp quebrar (YouTube muda formatos com
frequência — sintomas: erros do tipo `Requested format is not available`
ou `n challenge solving failed` no collect step).

### Instalar / atualizar

```bash
# Como root na distro:
cp deploy/toscanini.service /etc/systemd/system/toscanini.service
# Editar para substituir <REDACTED:*> pelos secrets reais
$EDITOR /etc/systemd/system/toscanini.service
systemctl daemon-reload
systemctl enable --now toscanini
```

Após alterações no unit ou nas env vars:

```bash
systemctl daemon-reload
systemctl restart toscanini
systemctl status toscanini
```

## Publish Scholion (`POST /api/orchestrator/publish/scholion`)

O pipeline scholion escreve a nota composta em `content/notes/<slug>.md` de um
clone do **repo de conteúdo Scholion** e faz commit/push. Pré-requisitos de
infra (uma vez, como o usuário `hermes`):

1. **Deploy key com WRITE** para o repo de conteúdo Scholion no GitHub. As deploy
   keys são por-repo — a `scholion_deploy_key` existente é do repo `scholion-chat`,
   não serve. Gerar um par novo e adicionar a pública no repo com "Allow write access":
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/scholion_content -N "" -C "toscanini scholion-content"
   cat ~/.ssh/scholion_content.pub   # colar em GitHub → repo → Deploy keys (write)
   ```
2. **Host alias** em `~/.ssh/config`:
   ```
   Host github-scholion-content
     HostName github.com
     User git
     IdentityFile ~/.ssh/scholion_content
     IdentitiesOnly yes
   ```
3. **Clonar** o repo de conteúdo no path do `TOSCANINI_SCHOLION_DIR`:
   ```bash
   git clone git@github-scholion-content:thluiz/<repo-conteudo>.git /home/hermes/scholion
   git config --global --add safe.directory /home/hermes/scholion
   ```
4. Confirmar identidade de commit (já global: `Hermes <hermes@hermes-pt.local>`).
5. `TOSCANINI_SCHOLION_DIR` já está no unit (default `/home/hermes/scholion`);
   ajustar se o clone for para outro path. `daemon-reload` + `restart toscanini`.

O `vox-intelligence` precisa do preset `quote-note` (síntese) e do `ghost-audit`
(portão de voz) — ambos usam `OPENROUTER_API_KEY` (Perplexity para autoria +
modelos de composição). Nenhuma chave git vive no código do Toscanini: a auth é
resolvida pelo remote do clone via `~/.ssh/config`.

## Publish webclip (`POST /api/orchestrator/publish/webclip`)

The webclip flow calls the scholion-webclipper (`$HERMES_BASE_URL/api/webclip/`)
as its own principal. One-time setup:

1. In `/home/hermes/services/scholion-webclipper/acl.json`, add a `toscanini`
   principal with role `write` and a fresh key (`openssl rand -hex 24`). Never
   `admin`: the flow must not be able to force a save past a red ghost-audit.
2. Put the same key in the unit as `WEBCLIPPER_API_KEY`, then
   `systemctl daemon-reload && systemctl restart toscanini`.

Saves use `mode: "commit"`: the webclipper writes and pushes from its own
clone (`scholion-webclipper/vault`), not from `TOSCANINI_SCHOLION_DIR`.
Pipelines the server can't finish are `parked`; Claude Code on the author's
machine works the queue through the MCP tools `list_parked` /
`resume_parked` / `dismiss_parked`.
