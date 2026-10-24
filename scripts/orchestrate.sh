#!/usr/bin/env bash
# QuotaPulse orchestration: Claude (lead) wrote the architecture + core; this script hands the
# Mac-only work to codex and agy, phase by phase. Progress -> .orchestration/ (Claude polls it).
#
#   ./scripts/orchestrate.sh            # run all phases
#   ./scripts/orchestrate.sh 2          # start from phase 2
#   ONLY=AGY-02 ./scripts/orchestrate.sh  # run a single task
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/.orchestration"
mkdir -p "$OUT"
START_PHASE="${1:-1}"

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $*" | tee -a "$OUT/status.log"; }

CODEX="$(command -v codex || true)"
AGY="$(command -v agy || echo "$HOME/.local/bin/agy")"
[[ -x "$CODEX" ]] || { log "ERROR codex not found on PATH"; exit 1; }
[[ -x "$AGY" ]] || { log "WARN agy not found – AGY tasks will be given to codex"; AGY=""; }

if [[ ! -d .git ]]; then
  git init -q && git add -A && git commit -qm "QuotaPulse: architecture + core by Claude (lead)" && log "git baseline committed"
fi

run_task() {   # run_task <agent> <TASK-ID>
  local agent="$1" id="$2" brief="$ROOT/tasks/$2.md" logf="$OUT/$2.log"
  [[ -n "${ONLY:-}" && "$ONLY" != "$id" ]] && return 0
  local prompt
  prompt="$(cat "$ROOT/AGENTS.md")

---- YOUR TASK ($id) ----
$(cat "$brief")

When finished, write a short report to .orchestration/$id.report.md (what you changed, build/test result, open issues)."
  log "START $id ($agent)"
  local rc
  if [[ "$agent" == "agy" && -n "$AGY" ]]; then
    "$AGY" -p "$prompt" --dangerously-skip-permissions --print-timeout 45m >"$logf" 2>&1; rc=$?
  else
    "$CODEX" exec --dangerously-bypass-approvals-and-sandbox -C "$ROOT" "$prompt" >"$logf" 2>&1; rc=$?
  fi
  log "END $id rc=$rc"
  git add -A && git commit -qm "$id ($agent)" >/dev/null 2>&1 && log "committed $id" || true
  return 0
}

if (( START_PHASE <= 1 )); then
  log "PHASE 1: build & fix on macOS"
  run_task codex CODEX-01-build-fix
fi
if (( START_PHASE <= 2 )); then
  log "PHASE 2: providers + widget (parallel)"
  run_task codex CODEX-02-claude-codex-live &
  run_task agy AGY-01-google-providers &
  wait
  run_task agy AGY-02-widgetkit
fi
if (( START_PHASE <= 3 )); then
  log "PHASE 3: review, install"
  run_task codex CODEX-03-review-install
fi
log "ALL DONE"
