<#
.SYNOPSIS
  Switch every LLM use case between the 'anthropic' and 'third-party' profiles.

.DESCRIPTION
  Toscanini owns the table of model chains per use case (C1..C16), with both profiles
  and the active one. This script:
    1. sets the active profile in Toscanini (PUT /api/orchestrator/model-routing/profile).
       Toscanini and vox-intelligence follow at once, no restart;
    2. syncs the Claudinho (OpenClaw), which only reads its own openclaw.json, and
       restarts its gateway (model-profile.sh sync --restart in ClaudinhoSandbox).

  Use 'anthropic' when there are Anthropic credits (BYOK on OpenRouter), 'third-party'
  otherwise. Without a profile it only shows the current state.
  Table and rationale: Obsidian, Claude/2026-11-16 Roteamento de modelos por caso de uso.md

  Installed copy. Canonical: toscanini repo, deploy/model-routing/ (edit there, then
  run Install-ModelRouting.ps1).

.EXAMPLE
  pwsh -NoProfile -File C:\scripts\Set-ModelProfile.ps1 anthropic
.EXAMPLE
  pwsh -NoProfile -File C:\scripts\Set-ModelProfile.ps1            # status only
.EXAMPLE
  pwsh -NoProfile -File C:\scripts\Set-ModelProfile.ps1 third-party -SkipClaudinho
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet("anthropic", "third-party")]
  [string]$ModelProfile,

  [switch]$SkipClaudinho
)

$ErrorActionPreference = "Stop"
$api = "http://localhost:8080/api/orchestrator/model-routing"

function Show-State {
  $r = Invoke-RestMethod -Uri "$api/resolved" -TimeoutSec 10
  Write-Output "Toscanini profile: $($r.profile)"
  foreach ($p in $r.chains.PSObject.Properties | Sort-Object Name) {
    Write-Output ("  {0,-34} {1}" -f $p.Name, ($p.Value -join " -> "))
  }
  $vi = Invoke-RestMethod -Uri "http://localhost:8080/api/vox-intelligence/routing" -TimeoutSec 10
  Write-Output "vox-intelligence: source=$($vi.source) profile=$($vi.profile)"
  $claudinho = wsl -d ClaudinhoSandbox -u sandbox -- bash -c "~/.openclaw/scripts/model-profile.sh status | tail -1"
  Write-Output "Claudinho: $claudinho"
}

if (-not $ModelProfile) { Show-State; exit 0 }

$body = @{ profile = $ModelProfile } | ConvertTo-Json
$res = Invoke-RestMethod -Method Put -Uri "$api/profile" -Body $body -ContentType "application/json" -TimeoutSec 30
Write-Output "Toscanini: active = $($res.active)"
foreach ($w in $res.warnings) { Write-Warning $w }

if (-not $SkipClaudinho) {
  wsl -d ClaudinhoSandbox -u sandbox -- bash -c "~/.openclaw/scripts/model-profile.sh sync --restart"
  if ($LASTEXITCODE -ne 0) { Write-Warning "Claudinho sync failed (exit $LASTEXITCODE)" }
}

Start-Sleep -Seconds 2
Show-State
