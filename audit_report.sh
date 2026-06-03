#!/bin/bash

# ==========================================
# CONFIGURATION & DEFAULTS
# ==========================================
MASTER="origin/master"
DEVELOP="origin/develop"
QA="origin/qa"
OUTPUT="audit_report.html"
FETCH=true
STALE_THRESHOLD=30 # Days

# Terminal Colors
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_NC='\033[0m'

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --no-fetch) FETCH=false; shift ;;
    --stale-days) STALE_THRESHOLD="$2"; shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    -h|--help) 
      echo -e "${C_BLUE}Enterprise Git Branch Audit${C_NC}"
      echo "Usage: bash audit_report.sh [options]"
      echo "  --no-fetch          Skip remote fetch"
      echo "  --stale-days <N>    Stale branch threshold (default: 30)"
      exit 0 
      ;;
    *) echo -e "${C_RED}Unknown parameter: $1${C_NC}"; exit 1 ;;
  esac
done

if ! command -v git &> /dev/null; then echo -e "${C_RED}❌ git not found.${C_NC}"; exit 1; fi
if ! git rev-parse --is-inside-work-tree &> /dev/null; then echo -e "${C_RED}❌ Must be run in a git repo.${C_NC}"; exit 1; fi

REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" || echo "Repository")
REPORT_DATE=$(date +"%Y-%m-%d %H:%M:%S")
CURRENT_TS=$(date +%s)

if [ "$FETCH" = true ]; then
  echo -e "${C_BLUE}🔄 Fetching remote data...${C_NC}"
  git fetch --all --prune -q
fi

echo -e "${C_CYAN}🔍 Analyzing branches, diffs, and history...${C_NC}"

FEATURE_BRANCHES=$(git branch -r | grep -v "HEAD\|master\|develop\|qa\|release\|hotfix" | sed 's/^ *//')

VIOLATIONS=""
OK_BRANCHES=""
VIOLATION_COUNT=0
OK_COUNT=0
STALE_COUNT=0

for BRANCH in $FEATURE_BRANCHES; do
  # 1. Fetch deep metadata
  META=$(git log $BRANCH --not $MASTER -1 --pretty=format:"%an|%ct" 2>/dev/null)
  CREATOR=$(echo "$META" | cut -d'|' -f1)
  COMMIT_TS=$(echo "$META" | cut -d'|' -f2)
  
  LAST_MSG=$(git log $BRANCH --not $MASTER -1 --pretty=format:"%s" 2>/dev/null)
  # Clean message for HTML
  LAST_MSG=$(echo "$LAST_MSG" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | cut -c 1-45)
  [ ${#LAST_MSG} -eq 45 ] && LAST_MSG="${LAST_MSG}..."
  
  # 2. Extract Ticket ID (e.g. PROJ-123)
  TICKET=$(echo "$BRANCH" | grep -ioE '[a-z]+-[0-9]+' | tr 'a-z' 'A-Z' | head -1)
  TICKET_BADGE=""
  if [ -n "$TICKET" ]; then
    TICKET_BADGE="<span class='ticket-badge'>${TICKET}</span>"
  fi

  # 3. Calculate Age
  if [ -n "$COMMIT_TS" ]; then
    DAYS_INACTIVE=$(( (CURRENT_TS - COMMIT_TS) / 86400 ))
  else
    DAYS_INACTIVE=0
  fi

  STALE_BADGE="<div style=\"color:#6c757d; font-size:12px; margin-top:2px;\">${DAYS_INACTIVE} days ago</div>"
  if [ "$DAYS_INACTIVE" -gt "$STALE_THRESHOLD" ]; then
    STALE_BADGE="<div class=\"badge purple\" style=\"margin-top:4px;\">Stale (${DAYS_INACTIVE}d)</div>"
    STALE_COUNT=$((STALE_COUNT + 1))
  fi

  # 4. Determine Origin (Master vs Develop vs QA)
  TIP=$(git rev-parse $BRANCH 2>/dev/null)
  MB_MASTER=$(git merge-base $MASTER $BRANCH 2>/dev/null)
  MB_DEV=$(git merge-base origin/develop $BRANCH 2>/dev/null)
  MB_QA=$(git merge-base origin/qa $BRANCH 2>/dev/null)

  ON_MASTER=1
  SOURCE="master"
  FORK_SHA=${MB_MASTER:0:7}

  if [ -n "$MB_DEV" ] && [ "$MB_DEV" != "$MB_MASTER" ]; then
      if [ "$MB_DEV" != "$TIP" ]; then
          ON_MASTER=0; SOURCE="develop"; FORK_SHA=${MB_DEV:0:7}
      else
          FIRST_COMMIT=$(git rev-list --reverse ${MB_MASTER}..${BRANCH} 2>/dev/null | head -n 1)
          if [ -n "$FIRST_COMMIT" ] && git log --first-parent --format="%H" origin/develop 2>/dev/null | grep -q "^${FIRST_COMMIT}$"; then
              ON_MASTER=0; SOURCE="develop"; FORK_SHA=${FIRST_COMMIT:0:7}
          fi
      fi
  fi

  if [ "$ON_MASTER" -eq 1 ] && [ -n "$MB_QA" ] && [ "$MB_QA" != "$MB_MASTER" ]; then
      if [ "$MB_QA" != "$TIP" ]; then
          ON_MASTER=0; SOURCE="qa"; FORK_SHA=${MB_QA:0:7}
      else
          FIRST_COMMIT=$(git rev-list --reverse ${MB_MASTER}..${BRANCH} 2>/dev/null | head -n 1)
          if [ -n "$FIRST_COMMIT" ] && git log --first-parent --format="%H" origin/qa 2>/dev/null | grep -q "^${FIRST_COMMIT}$"; then
              ON_MASTER=0; SOURCE="qa"; FORK_SHA=${FIRST_COMMIT:0:7}
          fi
      fi
  fi
  
  # 5. Calculate Diff Size (+/-) based on merge base
  DIFF_STAT=$(git diff --shortstat ${FORK_SHA}..${BRANCH} 2>/dev/null)
  INS=$(echo "$DIFF_STAT" | grep -oE '[0-9]+ insertion' | awk '{print $1}')
  DEL=$(echo "$DIFF_STAT" | grep -oE '[0-9]+ deletion' | awk '{print $1}')
  [ -z "$INS" ] && INS=0
  [ -z "$DEL" ] && DEL=0
  DIFF_HTML="<span class='add'>+${INS}</span> <span class='del'>-${DEL}</span>"

  # HTML Row Building
  ROW="
    <tr>
      <td>
        <div style='font-weight:600; color:#212529;'>${BRANCH##origin/}</div>
        ${TICKET_BADGE}
      </td>
      <td><span class=\"badge $([ "$ON_MASTER" -eq 0 ] && echo 'red' || echo 'blue')\">${SOURCE}</span></td>
      <td>${CREATOR}<br>${STALE_BADGE}</td>
      <td style='font-family:monospace;'>${DIFF_HTML}</td>
      <td style='color:#495057;'>${LAST_MSG}</td>
      <td><code>${FORK_SHA}</code></td>
    </tr>"

  if [ "$ON_MASTER" -eq "0" ]; then
    VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
    VIOLATIONS="${VIOLATIONS}${ROW}"
  else
    OK_COUNT=$((OK_COUNT + 1))
    OK_BRANCHES="${OK_BRANCHES}${ROW}"
  fi
done

# ==========================================
# DIRECT PUSHES & HOUSEKEEPING
# ==========================================
DIRECT_DEV=$(git log $DEVELOP --not $MASTER --first-parent --no-merges --pretty=format:"<tr><td><span class=\"badge amber\">develop</span></td><td>%an</td><td>%ad</td><td>%s</td><td><code>%h</code></td></tr>" --date=short)
DIRECT_QA=$(git log $QA --not $MASTER --first-parent --no-merges --pretty=format:"<tr><td><span class=\"badge amber\">qa</span></td><td>%an</td><td>%ad</td><td>%s</td><td><code>%h</code></td></tr>" --date=short)

DEV_COUNT=$( [ -z "$DIRECT_DEV" ] && echo 0 || echo "$DIRECT_DEV" | wc -l | tr -d ' ' )
QA_COUNT=$( [ -z "$DIRECT_QA" ] && echo 0 || echo "$DIRECT_QA" | wc -l | tr -d ' ' )
DIRECT_COUNT=$((DEV_COUNT + QA_COUNT))

# Find branches already merged into master
MERGED_RAW=$(git branch -r --merged $MASTER | grep -v "HEAD\|master\|develop\|qa\|release\|hotfix" | sed 's/^ *//')
MERGED_ROWS=""
MERGED_COUNT=0
for MB in $MERGED_RAW; do
  MERGED_COUNT=$((MERGED_COUNT + 1))
  MERGED_ROWS="${MERGED_ROWS}<tr><td><span style='text-decoration:line-through; color:#adb5bd;'>${MB##origin/}</span></td><td style='color:#198754;'>✓ Fully Merged (Safe to delete)</td></tr>"
done

# ==========================================
# HTML RENDERING
# ==========================================
[ -z "$VIOLATIONS" ] && VIOLATIONS="<tr><td colspan='6' style='text-align:center; padding:30px; color:#888;'>🎉 No violations found. Workflow is clean!</td></tr>"
[ -z "$OK_BRANCHES" ] && OK_BRANCHES="<tr><td colspan='6' style='text-align:center; padding:30px; color:#888;'>No standard feature branches found.</td></tr>"
[ -z "$MERGED_ROWS" ] && MERGED_ROWS="<tr><td colspan='2' style='text-align:center; padding:20px; color:#888;'>No ghost branches found. Repo is tidy!</td></tr>"

if [ "$DIRECT_COUNT" -eq 0 ]; then
  DIRECT_ROWS="<tr><td colspan='5' style='text-align:center; padding:30px; color:#888;'>🎉 No direct pushes detected!</td></tr>"
else
  DIRECT_ROWS="${DIRECT_DEV}\n${DIRECT_QA}"
fi

TOTAL_BRANCHES=$(( VIOLATION_COUNT + OK_COUNT ))

cat > "$OUTPUT" << HTMLEOF
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Audit Report — ${REPO_NAME}</title>
  <style>
    :root { --bg: #f8f9fa; --card: #ffffff; --text: #212529; --border: #e9ecef; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
           max-width: 1200px; margin: 40px auto; padding: 0 24px; background: var(--bg); color: var(--text); font-size: 13px; }
    h1 { font-size: 24px; font-weight: 700; margin-bottom: 4px; letter-spacing: -0.5px; }
    .meta { color: #6c757d; font-size: 13px; margin-bottom: 32px; }
    .summary { display: grid; grid-template-columns: repeat(6, 1fr); gap: 12px; margin-bottom: 40px; }
    .metric { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 16px; text-align: center; }
    .metric .val { font-size: 32px; font-weight: 700; letter-spacing: -1px; }
    .metric .lbl { font-size: 11px; color: #6c757d; margin-top: 6px; font-weight: 600; text-transform: uppercase; }
    .red-val { color: #dc3545; } .green-val { color: #198754; } .amber-val { color: #fd7e14; } .purple-val { color: #6f42c1; } .blue-val { color: #0d6efd; }
    section { margin-bottom: 40px; }
    h2 { font-size: 16px; font-weight: 600; margin-bottom: 12px; }
    table { width: 100%; border-collapse: collapse; background: var(--card); border: 1px solid var(--border); border-radius: 10px; overflow: hidden; box-shadow: 0 1px 2px rgba(0,0,0,0.02); }
    th { text-align: left; padding: 12px 16px; background: #f1f3f5; font-size: 11px; color: #495057; font-weight: 600; text-transform: uppercase; }
    td { padding: 12px 16px; border-top: 1px solid var(--border); vertical-align: middle; }
    tr:hover td { background-color: #f8f9fa; }
    .badge { display: inline-flex; padding: 3px 8px; border-radius: 6px; font-size: 11px; font-weight: 600; }
    .badge.red { background: #f8d7da; color: #842029; } .badge.green { background: #d1e7dd; color: #0f5132; }
    .badge.amber { background: #ffe5d0; color: #9a4700; } .badge.purple { background: #e0cffc; color: #3d1a87; }
    .badge.blue { background: #cfe2ff; color: #084298; }
    .ticket-badge { display: inline-block; background: #e9ecef; color: #495057; font-size: 10px; padding: 2px 6px; border-radius: 4px; font-weight: 600; margin-top: 4px; }
    .add { color: #198754; font-weight: 600; } .del { color: #dc3545; font-weight: 600; }
    code { font-family: monospace; font-size: 12px; background: #f1f3f5; padding: 2px 5px; border-radius: 4px; color: #d63384; }
  </style>
</head>
<body>

<h1>Branch Audit Report — ${REPO_NAME}</h1>
<div class="meta">Generated: ${REPORT_DATE}  ·  Threshold: > ${STALE_THRESHOLD} days</div>

<div class="summary">
  <div class="metric"><div class="val $([ "$VIOLATION_COUNT" -gt 0 ] && echo "red-val" || echo "green-val")">${VIOLATION_COUNT}</div><div class="lbl">Violations</div></div>
  <div class="metric"><div class="val $([ "$DIRECT_COUNT" -gt 0 ] && echo "amber-val" || echo "green-val")">${DIRECT_COUNT}</div><div class="lbl">Direct Pushes</div></div>
  <div class="metric"><div class="val $([ "$STALE_COUNT" -gt 0 ] && echo "purple-val" || echo "green-val")">${STALE_COUNT}</div><div class="lbl">Stale Branches</div></div>
  <div class="metric"><div class="val $([ "$MERGED_COUNT" -gt 0 ] && echo "blue-val" || echo "green-val")">${MERGED_COUNT}</div><div class="lbl">Ghost Branches</div></div>
  <div class="metric"><div class="val green-val">${OK_COUNT}</div><div class="lbl">Clean Flow</div></div>
  <div class="metric"><div class="val">${TOTAL_BRANCHES}</div><div class="lbl">Total Branches</div></div>
</div>

<section>
  <h2>❌ Violations (Branched incorrectly)</h2>
  <table>
    <tr><th>Branch / Ticket</th><th>Source Base</th><th>Author & Status</th><th>Diff Size</th><th>Latest Commit</th><th>Fork SHA</th></tr>
    ${VIOLATIONS}
  </table>
</section>

<section>
  <h2>⚠️ Direct Pushes (Bypassed feature branches)</h2>
  <table>
    <tr><th>Target</th><th>Author</th><th>Date</th><th>Commit Message</th><th>SHA</th></tr>
    ${DIRECT_ROWS}
  </table>
</section>

<section>
  <h2>✅ Correct Workflow (Branched from master)</h2>
  <table>
    <tr><th>Branch / Ticket</th><th>Source Base</th><th>Author & Status</th><th>Diff Size</th><th>Latest Commit</th><th>Fork SHA</th></tr>
    ${OK_BRANCHES}
  </table>
</section>

<section>
  <h2>🧹 Housekeeping (Ghost Branches)</h2>
  <div style="font-size:12px; color:#6c757d; margin-bottom:10px;">These branches are fully merged into master but still exist on the remote. They should be deleted.</div>
  <table style="width:50%;">
    ${MERGED_ROWS}
  </table>
</section>

</body>
</html>
HTMLEOF

echo ""
echo -e "${C_GREEN}✓ Report saved: ${OUTPUT}${C_NC}"
echo "-------------------------------------"
echo -e "  Violations     : $([ "$VIOLATION_COUNT" -gt 0 ] && echo "${C_RED}${VIOLATION_COUNT}${C_NC}" || echo "${C_GREEN}0${C_NC}")"
echo -e "  Ghost Branches : $([ "$MERGED_COUNT" -gt 0 ] && echo "${C_BLUE}${MERGED_COUNT}${C_NC}" || echo "${C_GREEN}0${C_NC}")"
echo "-------------------------------------"