#!/usr/bin/env bash
# model-profile.sh: switch the OpenClaw (Claudinho) model chain.
#
#   model-profile.sh sync [--restart]      apply the cases claudinho/agent (C1) and claudinho/image (C2)
#                                          of Toscanini's active profile (the normal way)
#   model-profile.sh <profile> [--restart] apply a built-in profile (use when Toscanini is down)
#   model-profile.sh status                show the active chain and which profile it matches
#   model-profile.sh list                  show the built-in profiles
#
# Toscanini owns the table (GET /api/orchestrator/model-routing). The built-in profiles
# below are a copy of it, kept as the backup: anthropic, third-party, no-anthropic
# (byok and default are accepted as old names of anthropic and third-party).
# The full switch, Toscanini included, is C:\scripts\Set-ModelProfile.ps1 on Windows.
#
# Every write copies openclaw.json to openclaw.json.bak-<timestamp>-profile-<name> first.
# Restore: cp <backup> ~/.openclaw/openclaw.json && systemctl --user restart openclaw-gateway
# The gateway only picks up the change after a restart (--restart does it).
#
# Installed copy. Canonical: toscanini repo, deploy/model-routing/ (edit there, then
# run Install-ModelRouting.ps1 on Windows).
set -euo pipefail

OC="$HOME/.npm-global/bin/openclaw"
CFG="$HOME/.openclaw/openclaw.json"
ROUTING_URL="${MODEL_ROUTING_URL:-http://localhost:8080/api/orchestrator/model-routing/resolved}"

LOCAL='"ollama/geral","ollama/codigo","ollama/phi4:14b","ollama/openclaw-fast","ollama/openclaw-reason","ollama/openclaw-heavy"'
IMAGE='"openrouter/anthropic/claude-haiku-5.5","openrouter/google/gemini-2.5-flash-lite","openrouter/openai/gpt-5.2"'

profile_json() {
  case "$1" in
    anthropic|byok) cat <<EOF
{"agent":["openrouter/anthropic/claude-sonnet-5.5","openrouter/deepseek/deepseek-v4-pro",$LOCAL,"openrouter/deepseek/deepseek-v3.2","openrouter/openai/gpt-5.2"],
 "image":[$IMAGE]}
EOF
    ;;
    third-party|default) cat <<EOF
{"agent":["openrouter/deepseek/deepseek-v4-pro",$LOCAL,"openrouter/deepseek/deepseek-v3.2","openrouter/openai/gpt-5.2"],
 "image":[$IMAGE]}
EOF
    ;;
    no-anthropic) cat <<EOF
{"agent":["openrouter/deepseek/deepseek-v4-pro",$LOCAL,"openrouter/deepseek/deepseek-v3.2","openrouter/openai/gpt-5.2"],
 "image":["openrouter/google/gemini-2.5-flash-lite","openrouter/openai/gpt-5.2"]}
EOF
    ;;
    *) return 1 ;;
  esac
}

PROFILES="anthropic third-party no-anthropic"

current() {
  python3 - "$CFG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["agents"]["defaults"]
print(json.dumps({"agent": [d["model"]["primary"]] + d["model"].get("fallbacks", []),
                  "image": [d["imageModel"]["primary"]] + d["imageModel"].get("fallbacks", [])}))
PY
}

same() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]) == json.loads(sys.argv[2]))' "$1" "$2"; }

from_toscanini() {
  local body
  body=$(curl -sf -m 5 "$ROUTING_URL") || { echo "Toscanini unreachable at $ROUTING_URL; use a built-in profile: $PROFILES" >&2; return 1; }
  python3 -c '
import json, sys
d = json.loads(sys.argv[1]); c = d.get("chains", {})
agent, image = c.get("claudinho/agent"), c.get("claudinho/image")
if not agent or not image:
    sys.exit("Toscanini has no claudinho/agent or claudinho/image chain")
print(d.get("profile")); print(json.dumps({"agent": agent, "image": image}))
' "$body"
}

apply() {
  local name="$1" json="$2" restart="${3:-}"
  local bak="$CFG.bak-$(date +%Y%m%d-%H%M%S)-profile-$name"
  if [ "$(same "$(current)" "$json")" = True ]; then
    echo "already on $name, nothing written"
  else
    cp "$CFG" "$bak"
    echo "backup: $bak"
    pick() { python3 -c 'import json,sys; v=json.loads(sys.argv[1])[sys.argv[2]]; print(v[0] if sys.argv[3]=="head" else json.dumps(v[1:]))' "$json" "$1" "$2"; }
    "$OC" config set agents.defaults.model.primary "$(pick agent head)" >/dev/null
    "$OC" config set --json agents.defaults.model.fallbacks "$(pick agent tail)" >/dev/null
    "$OC" config set agents.defaults.imageModel.primary "$(pick image head)" >/dev/null
    "$OC" config set --json agents.defaults.imageModel.fallbacks "$(pick image tail)" >/dev/null
    [ "$(same "$(current)" "$json")" = True ] || { echo "verification failed, restore $bak" >&2; exit 1; }
    echo "profile $name written"
  fi
  if [ "$restart" = "--restart" ]; then
    systemctl --user restart openclaw-gateway
    echo "gateway restarted"
  else
    echo "restart the gateway to apply: systemctl --user restart openclaw-gateway"
  fi
}

case "${1:-status}" in
  status)
    cur=$(current)
    echo "$cur" | python3 -m json.tool
    for p in $PROFILES; do
      [ "$(same "$cur" "$(profile_json "$p")")" = True ] && { echo "profile: $p"; exit 0; }
    done
    echo "profile: (none of the built-in ones)"
    ;;
  list)
    for p in $PROFILES; do echo "== $p"; profile_json "$p" | python3 -m json.tool; done
    ;;
  sync)
    out=$(from_toscanini) || exit 1
    name=$(echo "$out" | head -1)
    json=$(echo "$out" | tail -1)
    echo "Toscanini profile: $name"
    apply "$name" "$json" "${2:-}"
    ;;
  *)
    json=$(profile_json "$1") || { echo "unknown profile: $1 (use: sync, $PROFILES)" >&2; exit 2; }
    apply "$1" "$json" "${2:-}"
    ;;
esac
