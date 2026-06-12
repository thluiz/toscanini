# Deployment

## systemd unit

`toscanini.service` é uma cópia versionada do unit instalado em
`/etc/systemd/system/toscanini.service` no host (HermesTools WSL distro).

Valores marcados com `<REDACTED:NOME>` são secrets — substituir pelos
reais ao instalar (cofre pessoal, nunca commitar).

### Pré-requisitos no host

- Erlang/Elixir via `asdf` em `/home/hermes/.asdf`
- Whisper venv em `/home/hermes/whisper-venv` (CUDA/cuDNN para GPU)
- `yt-dlp` em `/home/hermes/.local/bin/yt-dlp` (atualizar via `pip3
  install --user --upgrade yt-dlp`)
- `deno` em `/home/hermes/.deno/bin/deno` — runtime JS exigido pelo
  yt-dlp ≥ `2026.06` para extração do YouTube
  ```bash
  curl -fsSL https://deno.land/install.sh | sh
  ```

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
