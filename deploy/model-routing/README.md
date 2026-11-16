# Model routing: switch scripts

The Toscanini owns the model chain of every LLM use case (`Toscanini.ModelRouting`,
`data/model_routing.json` over `priv/model_routing.default.json`), with two complete
profiles: `anthropic` (when there are Anthropic credits on the OpenRouter BYOK) and
`third-party` (GPT/DeepSeek). Toscanini and vox-intelligence follow the active profile
without restart. The Claudinho (OpenClaw) only reads its own `openclaw.json`, so it needs
a sync.

These files are the canonical copies. The ones that run are installed copies:

| File | Runs at | What it does |
|---|---|---|
| `Set-ModelProfile.ps1` | `C:\scripts\Set-ModelProfile.ps1` (Windows) | The full switch: sets the profile in Toscanini, syncs the Claudinho, shows the state of the three |
| `model-profile.sh` | `~/.openclaw/scripts/model-profile.sh` (ClaudinhoSandbox, user `sandbox`) | Applies the cases `claudinho/agent` and `claudinho/image` to `openclaw.json`, with a backup first. Has built-in profiles for when Toscanini is down |
| `Install-ModelRouting.ps1` | run once from Windows | Copies the two above to where they run and checks the SHA-256 |

Edit here, commit, then install:

```powershell
wsl -d HermesTools -u hermes -- base64 -w0 /home/hermes/services/toscanini/deploy/model-routing/Install-ModelRouting.ps1 |
  ForEach-Object { [IO.File]::WriteAllBytes("$env:TEMP\Install-ModelRouting.ps1", [Convert]::FromBase64String($_)) }
pwsh -NoProfile -File "$env:TEMP\Install-ModelRouting.ps1"
```

## Switching

```powershell
pwsh -NoProfile -File C:\scripts\Set-ModelProfile.ps1 anthropic     # Anthropic first
pwsh -NoProfile -File C:\scripts\Set-ModelProfile.ps1 third-party   # GPT/DeepSeek
pwsh -NoProfile -File C:\scripts\Set-ModelProfile.ps1               # state only
```

Without the script: MCP `set_model_profile` (Toscanini and vox-intelligence only), or
`PUT /api/orchestrator/model-routing/profile` with `{"profile": "anthropic"}`.

One case, one profile: MCP `set_model_chain`, or
`PUT /api/orchestrator/model-routing/cases/<key>` with `{"profile", "chain"}`.

## Restoring

- Routing table: every write keeps the previous file in `data/model_routing_backups/`
  (last 30). Copy one over `data/model_routing.json`. Deleting `data/model_routing.json`
  falls back to the seed in `priv/`.
- Claudinho: every write keeps `~/.openclaw/openclaw.json.bak-<timestamp>-profile-<name>`.
  `cp <backup> ~/.openclaw/openclaw.json && systemctl --user restart openclaw-gateway`.
- When Toscanini is unreachable, vox-intelligence keeps the last table it saw, or the
  constants in each preset (they mirror `third-party`), and `model-profile.sh` refuses
  `sync` and points to its built-in profiles.

The per-case table and the reasons behind each chain: Obsidian,
`Claude/2026-11-16 Roteamento de modelos por caso de uso.md`.
