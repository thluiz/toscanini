<#
.SYNOPSIS
  Install the model-routing switch scripts from the Toscanini repo to where they run.

.DESCRIPTION
  Canonical copies live in the Toscanini repo (HermesTools,
  /home/hermes/services/toscanini/deploy/model-routing/). This copies them, byte for
  byte, to:
    - C:\scripts\Set-ModelProfile.ps1                       (Windows)
    - ClaudinhoSandbox ~/.openclaw/scripts/model-profile.sh (user sandbox)
  and checks the SHA-256 of each installed copy against the repo.

  Files go through base64, so there is no CRLF and no pwsh -> wsl -> bash quoting.

.EXAMPLE
  # The installer itself lives in WSL; fetch it, then run it:
  wsl -d HermesTools -u hermes -- base64 -w0 /home/hermes/services/toscanini/deploy/model-routing/Install-ModelRouting.ps1 |
    ForEach-Object { [IO.File]::WriteAllBytes("$env:TEMP\Install-ModelRouting.ps1", [Convert]::FromBase64String($_)) }
  pwsh -NoProfile -File "$env:TEMP\Install-ModelRouting.ps1"
#>
$ErrorActionPreference = "Stop"
$repo = "/home/hermes/services/toscanini/deploy/model-routing"

function Get-RepoFile([string]$name) {
  $b64 = (wsl -d HermesTools -u hermes -- base64 -w0 "$repo/$name") -join ""
  if ($LASTEXITCODE -ne 0 -or -not $b64) { throw "could not read $repo/$name from HermesTools" }
  return $b64
}

function Get-Sha([byte[]]$bytes) {
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLower()
}

# Windows: Set-ModelProfile.ps1
$b64 = Get-RepoFile "Set-ModelProfile.ps1"
$bytes = [Convert]::FromBase64String($b64)
New-Item -ItemType Directory -Force C:\scripts | Out-Null
[IO.File]::WriteAllBytes("C:\scripts\Set-ModelProfile.ps1", $bytes)
$ok = (Get-Sha ([IO.File]::ReadAllBytes("C:\scripts\Set-ModelProfile.ps1"))) -eq (Get-Sha $bytes)
Write-Output ("C:\scripts\Set-ModelProfile.ps1            " + ($(if ($ok) { "ok" } else { "HASH MISMATCH" })))

# ClaudinhoSandbox: model-profile.sh
$b64 = Get-RepoFile "model-profile.sh"
$want = Get-Sha ([Convert]::FromBase64String($b64))
$got = (wsl -d ClaudinhoSandbox -u sandbox -- bash -c "mkdir -p ~/.openclaw/scripts && echo $b64 | base64 -d > ~/.openclaw/scripts/model-profile.sh && chmod +x ~/.openclaw/scripts/model-profile.sh && sha256sum ~/.openclaw/scripts/model-profile.sh | cut -d' ' -f1") -join ""
Write-Output ("ClaudinhoSandbox ~/.openclaw/scripts/model-profile.sh " + ($(if ($got -eq $want) { "ok" } else { "HASH MISMATCH" })))
