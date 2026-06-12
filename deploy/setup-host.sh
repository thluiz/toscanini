#!/usr/bin/env bash
# Install / upgrade host-side dependencies for the toscanini service.
# Idempotent — safe to re-run. Runs as the unprivileged service user
# (no sudo); installs to $HOME.
#
# Run again whenever yt-dlp breaks (YouTube format changes are frequent).
set -euo pipefail

YTDLP_BIN="${YTDLP_BIN:-$HOME/.local/bin/yt-dlp}"
DENO_BIN="${DENO_BIN:-$HOME/.deno/bin/deno}"

say() { printf '[setup-host] %s\n' "$*"; }

# --- yt-dlp: always upgrade to latest, YouTube extraction breaks often
say "Upgrading yt-dlp (pip3 --user)..."
pip3 install --user --upgrade --quiet yt-dlp

if [[ ! -x "$YTDLP_BIN" ]]; then
  say "ERROR: yt-dlp not found at $YTDLP_BIN after install" >&2
  exit 1
fi

# --- deno: required JS runtime for yt-dlp 2026.06+ YouTube extraction
if [[ -x "$DENO_BIN" ]]; then
  say "deno already installed at $DENO_BIN (skipping)"
else
  say "Installing deno..."
  curl -fsSL https://deno.land/install.sh | sh
fi

# --- ffmpeg: yt-dlp uses it for audio extraction / format conversion
if ! command -v ffmpeg >/dev/null 2>&1; then
  say "WARNING: ffmpeg not on PATH — yt-dlp may fail on some formats" >&2
fi

say "---"
say "yt-dlp: $("$YTDLP_BIN" --version)"
say "deno:   $("$DENO_BIN" --version | head -1)"
say "ffmpeg: $(command -v ffmpeg || echo 'NOT FOUND')"
say "Done."
