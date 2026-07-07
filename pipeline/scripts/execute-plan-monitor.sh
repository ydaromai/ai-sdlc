#!/usr/bin/env bash
# execute-plan-monitor.sh — one-shot status dashboard for an execute-plan run
# (attended or unattended). Read-only: never writes to the repo or the run.
#
# Usage:
#   execute-plan-monitor.sh [--dir <repo-dir>] [--plan <plan.md>]
#   watch -n 30 /path/to/execute-plan-monitor.sh --dir <repo> --plan <plan>   # live view
#
# Defaults: --dir = cwd; --plan = auto-detect from the newest unattended
# console log, else the newest docs/dev_plans/*.md in --dir.
set -u

DIR="$(pwd)"; PLAN=""; BASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --plan) PLAN="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --help|-h) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 5 ;;
  esac
done

bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true)
grn=$(tput setaf 2 2>/dev/null || true); ylw=$(tput setaf 3 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true); rst=$(tput sgr0 2>/dev/null || true)

hr() { printf '%s\n' "────────────────────────────────────────────────────────────"; }

# ── locate the run ──
WRAPPER_PID="$(pgrep -f 'execute-plan-unattended.sh --plan' 2>/dev/null | head -1 || true)"
INNER_PID="$(pgrep -f 'scripts/execute-plan.sh --plan' 2>/dev/null | head -1 || true)"
STATE_DIR="$(ls -dt /tmp/execute-plan-unattended-*/ 2>/dev/null | while read -r d; do
  [[ -f "$d/wrapper.log" ]] && { echo "${d%/}"; break; }; done)"

# plan auto-detect: console log → newest dev plan in --dir
if [[ -z "$PLAN" ]]; then
  PLAN="$(grep -oE 'plan=[^ ]+\.md' /tmp/execute-plan-unattended-console.log 2>/dev/null | head -1 | cut -d= -f2- || true)"
fi
if [[ -z "$PLAN" || ! -f "$PLAN" ]]; then
  PLAN="$(ls -t "$DIR"/docs/dev_plans/*.md 2>/dev/null | head -1 || true)"
fi

printf '%s\n' "${bold}EXECUTE-PLAN MONITOR${rst}  $(date '+%Y-%m-%d %H:%M:%S')"
hr

# ── supervisor / orchestrator health ──
if [[ -n "$WRAPPER_PID" ]]; then
  printf 'Supervisor : %s (unattended wrapper, pid %s)\n' "${grn}RUNNING${rst}" "$WRAPPER_PID"
elif [[ -n "$INNER_PID" ]]; then
  printf 'Supervisor : %s (attended execute-plan.sh, pid %s)\n' "${grn}RUNNING${rst}" "$INNER_PID"
else
  printf 'Supervisor : %s (no execute-plan process)\n' "${red}NOT RUNNING${rst}"
fi
if [[ -n "$STATE_DIR" && -f "$STATE_DIR/wrapper.log" ]]; then
  printf 'State dir  : %s\n' "$STATE_DIR"
  printf 'Wrapper    : %s\n' "$(tail -1 "$STATE_DIR/wrapper.log")"
fi

# ── current inner activity ──
ILOG=""
if [[ -n "$STATE_DIR" ]]; then
  ILOG="$(ls -t "$STATE_DIR"/cycle-*.log 2>/dev/null | head -1 || true)"
fi
if [[ -n "$ILOG" && -f "$ILOG" ]]; then
  CUR_STORY="$(grep -E 'Executing Story [0-9]+' "$ILOG" | tail -1 | sed -E 's/.*Executing (Story [0-9]+).*/\1/')"
  CUR_TASK="$(grep -E '\[(Task [0-9.]+|Story [0-9]+)\] Starting ralph loop' "$ILOG" | tail -1 | grep -oE '\[(Task [0-9.]+|Story [0-9]+)\]' | tr -d '[]')"
  LAST_OUT="$(grep -E '\[(Task [0-9.]+|Story [0-9]+)\] (Done\.|FAILED:|Ralph loop produced changes|WARNING: No changes produced)|DA: (PASS|FAIL)' "$ILOG" | tail -1)"
  N_FAILED="$({ grep -cE 'FAILED:' "$ILOG" 2>/dev/null || echo 0; } | head -1)"
  AGENT_ETIME="$(pgrep -f 'claude -p /ralph-loop' 2>/dev/null | head -1 | xargs -I{} ps -o etime= -p {} 2>/dev/null | tr -d ' ' || true)"
  printf 'Working on : %s%s%s%s\n' "${bold}" "${CUR_TASK:-${CUR_STORY:-?}}" "${rst}" "${AGENT_ETIME:+  (agent up ${AGENT_ETIME})}"
  [[ -n "$LAST_OUT" ]] && printf 'Last event : %s\n' "${LAST_OUT#\[*\] }"
  [[ "${N_FAILED:-0}" -gt 0 ]] && printf 'FAILED this cycle: %s%s%s\n' "${ylw}" "$N_FAILED" "${rst}"
fi
hr

# ── per-story progress from the plan ──
if [[ -n "$PLAN" && -f "$PLAN" ]]; then
  printf '%s\n' "${bold}PLAN PROGRESS${rst}  ${dim}${PLAN##*/}${rst}"
  # Scope commit counting to THIS run: default base = first commit that touched
  # the plan file (unscoped history counts "Story N / TASK" commits from older
  # features on the same branch). Override with --base <ref>.
  if [[ -z "$BASE" ]]; then
    PLAN_REL="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$PLAN" "$DIR" 2>/dev/null)"
    BASE="$(git -C "$DIR" log --reverse --format=%H -- "$PLAN_REL" 2>/dev/null | head -1 || true)"
  fi
  if [[ -n "$BASE" ]]; then
    COMMITS="$(git -C "$DIR" log --format=%s "$BASE.." 2>/dev/null | grep -E 'Story [0-9]+ / TASK' || true)"
  else
    COMMITS="$(git -C "$DIR" log --format=%s 2>/dev/null | grep -E 'Story [0-9]+ / TASK' || true)"
  fi
  COMMITS="$COMMITS" python3 - "$PLAN" <<'PYEOF'
import os, re, sys
commits = os.environ.get('COMMITS', '')
txt = open(sys.argv[1], encoding='utf-8').read()
stories = list(re.finditer(r'^## STORY (\d+)\s*[:—]\s*(.*?)$(.*?)(?=^## STORY \d|\Z)',
                           txt, re.DOTALL | re.MULTILINE))
gt = gd = 0
for m in stories:
    sid, title, body = m.group(1), m.group(2).strip(), m.group(3)
    header = body.split('### TASK')[0]
    sdone = bool(re.search(r'\*\*Status:\*\*\s*✅\s*DONE', header))
    tasks = list(re.finditer(r'### TASK \d+\.\d+[:—](.*?)(?=### TASK |\Z)', body, re.DOTALL))
    done = sum(1 for t in tasks if re.search(r'\*\*Status:\*\*\s*✅\s*DONE', t.group(1)))
    total = len(tasks); gt += total
    ncmt = len(re.findall(rf'Story {sid} / TASK', commits))
    # single-domain stories don't task-mark the plan; commits are the ground truth
    shown = max(done, min(ncmt, total))
    bar = '█' * shown + '░' * (total - shown)
    flag = ' ✅' if (sdone or (total and shown == total)) else ''
    title = re.sub(r'\[[^\]]*\]\s*', '', title)[:40]
    gd += shown
    print(f'  S{sid:<2} {shown:>2}/{total:<2} {bar:<22} cmts:{ncmt:<3} {title}{flag}')
mins = (gt - gd) * 34
print(f'  {"-"*58}')
print(f'  TOTAL {gd}/{gt} tasks ({100*gd//max(gt,1)}%)  ~{mins//60}h{mins%60:02d}m of build left @34min/task')
PYEOF
else
  printf '%s\n' "${ylw}plan file not found — pass --plan${rst}"
fi
hr

# ── recent commits ──
printf '%s\n' "${bold}RECENT COMMITS${rst}  ${dim}$DIR${rst}"
git -C "$DIR" log --oneline -5 2>/dev/null | sed 's/^/  /' || printf '  (not a git repo)\n'
