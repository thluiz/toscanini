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
