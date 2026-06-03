#!/bin/bash

# ==========================================
# CONFIGURATION & DEFAULTS
# ==========================================
MASTER="origin/master"
DEVELOP="origin/develop"
QA="origin/qa"
OUTPUT="audit_report.html"
JSON_OUTPUT="audit_summary.json"
FETCH=true
STALE_THRESHOLD=30 # Days
STRICT_MODE=false
GENERATE_JSON=false

# Terminal Colors
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_NC='\033[0m'

# ==========================================
# CLI ARGUMENT PARSING
# ==========================================
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --no-fetch) FETCH=false; shift ;;
    --stale-days) STALE_THRESHOLD="$2"; shift 2 ;;
    --strict) STRICT_MODE=true; shift ;;
    --json) GENERATE_JSON=true; shift ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    -h|--help) 
      echo -e "${C_BLUE}Enterprise Git Branch Audit${C_NC}"
      echo "Usage: bash audit_report.sh [options]"
      echo "Options:"
      echo "  --no-fetch          Skip remote fetch (runs instantly)"
      echo "  --strict            Fails the script (exit 1) if violations are found (For CI/CD)"
      echo "  --json              Generate a machine-readable JSON summary alongside HTML"
      echo "  --stale-days <N>    Stale branch threshold in days (default: 30)"
      echo "  -o, --output <file> Specify custom HTML output filename"
      exit 0 
      ;;
    *) echo -e "${C_RED}Unknown parameter: $1${C_NC}"; exit 1 ;;
  esac
done

if ! command -v git &> /dev/null; then echo -e "${C_RED}❌ git not found.${C_NC}"; exit 1; fi
if ! git rev-parse --is-inside-work-tree &> /dev/null; then echo -e "${C_RED}❌ Must be run inside a git repository.${C_NC}"; exit 1; fi

REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" || echo "Repository")
REPORT_DATE=$(date +"%Y-%m-%d %H:%M:%S")
CURRENT_TS=$(date +%s)

if [ "$FETCH" = true ]; then
  echo -e "${C_BLUE}🔄 Fetching remote data...${C_NC}"
  git fetch --all --prune -q
fi

echo -e "${C_CYAN}🔍 Analyzing branches, diffs, and developer metrics...${C_NC}"

FEATURE_BRANCHES=$(git branch -r | grep -v "HEAD\|master\|develop\|qa\|release\|hotfix" | sed 's/^ *//')

VIOLATIONS=""
OK_BRANCHES=""
VIOLATION_COUNT=0
OK_COUNT=0
STALE_COUNT=0

# Track authors for Leaderboard
AUTHOR_OK_LIST=""
AUTHOR_VIOL_LIST=""

for BRANCH in $FEATURE_BRANCHES; do
  # 1. Fetch deep metadata
  META=$(git log $BRANCH --not $MASTER -1 --pretty=format:"%an|%ct" 2>/dev/null)
  CREATOR=$(echo "$META" | cut -d'|' -f1)
  COMMIT_TS=$(echo "$META" | cut -d'|' -f2)
  
  LAST_MSG=$(git log $BRANCH --not $MASTER -1 --pretty=format:"%s" 2>/dev/null)
  LAST_MSG=$(echo "$LAST_MSG" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | cut -c 1-45)
  [ ${#LAST_MSG} -ge 45 ] && LAST_MSG="${LAST_MSG}..."
  
  # 2. Extract Ticket ID
  TICKET=$(echo "$BRANCH" | grep -ioE '[a-z]+-[0-9]+' | tr 'a-z' 'A-Z' | head -1)
  TICKET_BADGE=$([ -n "$TICKET" ] && echo "<span class='ticket-badge'>${TICKET}</span>" || echo "")

  # 3. Calculate Age & Stale Status
  DAYS_INACTIVE=$([ -n "$COMMIT_TS" ] && echo $(( (CURRENT_TS - COMMIT_TS) / 86400 )) || echo 0)
  STALE_BADGE="<div style=\"color:#6c757d; font-size:12px; margin-top:2px;\">${DAYS_INACTIVE} days ago</div>"
  
  if [ "$DAYS_INACTIVE" -gt "$STALE_THRESHOLD" ]; then
    STALE_BADGE="<div class=\"badge purple\" style=\"margin-top:4px;\">Stale (${DAYS_INACTIVE}d)</div>"
    STALE_COUNT=$((STALE_COUNT + 1))
  fi

  # 4. Determine Branch Origin
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
  
  # 5. Calculate Diff Size & Risk Assessment
  DIFF_STAT=$(git diff --shortstat ${FORK_SHA}..${BRANCH} 2>/dev/null)
  INS=$(echo "$DIFF_STAT" | grep -oE '[0-9]+ insertion' | awk '{print $1}')
  DEL=$(echo "$DIFF_STAT" | grep -oE '[0-9]+ deletion' | awk '{print $1}')
  [ -z "$INS" ] && INS=0
  [ -z "$DEL" ] && DEL=0
  
  TOTAL_DIFF=$((INS + DEL))
  RISK_BADGE=""
  if [ "$TOTAL_DIFF" -gt 1000 ]; then
    RISK_BADGE="<div class='badge red' style='margin-top:4px;'>⚠️ High Risk Size</div>"
  fi

  DIFF_HTML="<span class='add'>+${INS}</span> <span class='del'>-${DEL}</span><br>${RISK_BADGE}"

  # HTML Row Building
  ROW="
    <tr>
      <td>
        <div style='font-weight:600; color:#212529;'>${BRANCH##origin/}</div>
        ${TICKET_BADGE}
      </td>
      <td><span class=\"badge $([ "$ON_MASTER" -eq 0 ] && echo 'red' || echo 'blue')\">${SOURCE}</span></td>
      <td><span style='font-weight:600;'>${CREATOR}</span><br>${STALE_BADGE}</td>
      <td style='font-family:monospace; line-height: 1.4;'>${DIFF_HTML}</td>
      <td style='color:#495057;'>${LAST_MSG}</td>
      <td><code>${FORK_SHA}</code></td>
    </tr>"

  # Populate lists and metrics
  if [ "$ON_MASTER" -eq "0" ]; then
    VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
    VIOLATIONS="${VIOLATIONS}${ROW}"
    AUTHOR_VIOL_LIST="${AUTHOR_VIOL_LIST}${CREATOR}\n"
  else
    OK_COUNT=$((OK_COUNT + 1))
    OK_BRANCHES="${OK_BRANCHES}${ROW}"
    AUTHOR_OK_LIST="${AUTHOR_OK_LIST}${CREATOR}\n"
  fi
done

# ==========================================
# DIRECT PUSHES & HOUSEKEEPING
# ==========================================
DIRECT_DEV=$(git log $DEVELOP --not $MASTER --first-parent --no-merges --pretty=format:"<tr><td><span class=\"badge amber\">develop</span></td><td><span style='font-weight:600;'>%an</span></td><td>%ad</td><td>%s</td><td><code>%h</code></td></tr>" --date=short)
DIRECT_QA=$(git log $QA --not $MASTER --first-parent --no-merges --pretty=format:"<tr><td><span class=\"badge amber\">qa</span></td><td><span style='font-weight:600;'>%an</span></td><td>%ad</td><td>%s</td><td><code>%h</code></td></tr>" --date=short)

DEV_COUNT=$( [ -z "$DIRECT_DEV" ] && echo 0 || echo "$DIRECT_DEV" | wc -l | tr -d ' ' )
QA_COUNT=$( [ -z "$DIRECT_QA" ] && echo 0 || echo "$DIRECT_QA" | wc -l | tr -d ' ' )
DIRECT_COUNT=$((DEV_COUNT + QA_COUNT))

MERGED_RAW=$(git branch -r --merged $MASTER | grep -v "HEAD\|master\|develop\|qa\|release\|hotfix" | sed 's/^ *//')
MERGED_ROWS=""
MERGED_COUNT=0
for MB in $MERGED_RAW; do
  MERGED_COUNT=$((MERGED_COUNT + 1))
  MERGED_ROWS="${MERGED_ROWS}<tr><td><span style='text-decoration:line-through; color:#adb5bd;'>${MB##origin/}</span></td><td style='color:#198754; font-weight:600;'>✓ Fully Merged (Safe to delete)</td></tr>"
done

# ==========================================
# GENERATE AUTHOR LEADERBOARD
# ==========================================
LEADERBOARD_HTML=""
ALL_AUTHORS=$(echo -e "${AUTHOR_OK_LIST}${AUTHOR_VIOL_LIST}" | sort | uniq | grep -v '^$')

while IFS= read -r author; do
  [ -z "$author" ] && continue
  O_COUNT=$(echo -e "$AUTHOR_OK_LIST" | grep -c "^${author}$")
  V_COUNT=$(echo -e "$AUTHOR_VIOL_LIST" | grep -c "^${author}$")
  
  if [ "$V_COUNT" -gt 0 ]; then
    HEALTH_BADGE="<span class='badge red'>Needs Alignment</span>"
  elif [ "$O_COUNT" -gt 0 ]; then
    HEALTH_BADGE="<span class='badge green'>Perfect</span>"
  else
    HEALTH_BADGE="<span class='badge'>Inactive</span>"
  fi

  LEADERBOARD_HTML="${LEADERBOARD_HTML}
  <tr>
    <td style='font-weight:600;'>${author}</td>
    <td style='color:#198754; font-weight:700;'>${O_COUNT}</td>
    <td style='color:#dc3545; font-weight:700;'>${V_COUNT}</td>
    <td>${HEALTH_BADGE}</td>
  </tr>"
done <<< "$ALL_AUTHORS"

# ==========================================
# HTML RENDERING
# ==========================================
[ -z "$VIOLATIONS" ] && VIOLATIONS="<tr><td colspan='6' style='text-align:center; padding:30px; color:#198754; font-weight:600;'>🎉 No violations found. Workflow is clean!</td></tr>"
[ -z "$OK_BRANCHES" ] && OK_BRANCHES="<tr><td colspan='6' style='text-align:center; padding:30px; color:#888;'>No standard feature branches found.</td></tr>"
[ -z "$MERGED_ROWS" ] && MERGED_ROWS="<tr><td colspan='2' style='text-align:center; padding:20px; color:#888;'>No ghost branches found. Repo is tidy!</td></tr>"
[ -z "$LEADERBOARD_HTML" ] && LEADERBOARD_HTML="<tr><td colspan='4' style='text-align:center; padding:20px; color:#888;'>No author data available.</td></tr>"

if [ "$DIRECT_COUNT" -eq 0 ]; then
  DIRECT_ROWS="<tr><td colspan='5' style='text-align:center; padding:30px; color:#198754; font-weight:600;'>🎉 No direct pushes detected!</td></tr>"
else
  DIRECT_ROWS="${DIRECT_DEV}\n${DIRECT_QA}"
fi

TOTAL_BRANCHES=$(( VIOLATION_COUNT + OK_COUNT ))
TOTAL_ISSUES=$(( VIOLATION_COUNT + DIRECT_COUNT ))

cat > "$OUTPUT" << HTMLEOF
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Enterprise Audit — ${REPO_NAME}</title>
  <style>
    :root { --bg: #f8f9fa; --card: #ffffff; --text: #212529; --border: #e9ecef; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; max-width: 1200px; margin: 40px auto; padding: 0 24px; background: var(--bg); color: var(--text); font-size: 13px; }
    h1 { font-size: 26px; font-weight: 800; margin-bottom: 4px; letter-spacing: -0.5px; }
    .meta { color: #6c757d; font-size: 13px; margin-bottom: 32px; font-weight: 500; }
    .summary { display: grid; grid-template-columns: repeat(6, 1fr); gap: 12px; margin-bottom: 40px; }
    .metric { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 16px; text-align: center; box-shadow: 0 2px 4px rgba(0,0,0,0.02); }
    .metric .val { font-size: 32px; font-weight: 700; letter-spacing: -1px; }
    .metric .lbl { font-size: 11px; color: #6c757d; margin-top: 6px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px;}
    .red-val { color: #dc3545; } .green-val { color: #198754; } .amber-val { color: #fd7e14; } .purple-val { color: #6f42c1; } .blue-val { color: #0d6efd; }
    section { margin-bottom: 40px; }
    h2 { font-size: 18px; font-weight: 700; margin-bottom: 12px; border-bottom: 2px solid var(--border); padding-bottom: 8px;}
    table { width: 100%; border-collapse: collapse; background: var(--card); border: 1px solid var(--border); border-radius: 10px; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.02); }
    th { text-align: left; padding: 12px 16px; background: #f1f3f5; font-size: 11px; color: #495057; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; border-bottom: 1px solid #dee2e6;}
    td { padding: 12px 16px; border-bottom: 1px solid var(--border); vertical-align: middle; }
    tr:last-child td { border-bottom: none; }
    tr:hover td { background-color: #f8f9fa; }
    .badge { display: inline-flex; padding: 3px 8px; border-radius: 6px; font-size: 11px; font-weight: 700; letter-spacing: 0.3px;}
    .badge.red { background: #f8d7da; color: #842029; } .badge.green { background: #d1e7dd; color: #0f5132; }
    .badge.amber { background: #fff3cd; color: #664d03; } .badge.purple { background: #e0cffc; color: #3d1a87; }
    .badge.blue { background: #cfe2ff; color: #084298; }
    .ticket-badge { display: inline-block; background: #e2e3e5; color: #383d41; font-size: 10px; padding: 2px 6px; border-radius: 4px; font-weight: 700; margin-top: 6px; }
    .add { color: #198754; font-weight: 700; } .del { color: #dc3545; font-weight: 700; }
    code { font-family: 'SFMono-Regular', Consolas, monospace; font-size: 12px; background: #f1f3f5; padding: 2px 6px; border-radius: 4px; color: #d63384; font-weight: 600;}
  </style>
</head>
<body>

<h1>Enterprise Branch Audit — ${REPO_NAME}</h1>
<div class="meta">Generated: ${REPORT_DATE}  ·  Threshold: > ${STALE_THRESHOLD} days</div>

<div class="summary">
  <div class="metric"><div class="val $([ "$VIOLATION_COUNT" -gt 0 ] && echo "red-val" || echo "green-val")">${VIOLATION_COUNT}</div><div class="lbl">Violations</div></div>
  <div class="metric"><div class="val $([ "$DIRECT_COUNT" -gt 0 ] && echo "amber-val" || echo "green-val")">${DIRECT_COUNT}</div><div class="lbl">Direct Pushes</div></div>
  <div class="metric"><div class="val $([ "$STALE_COUNT" -gt 0 ] && echo "purple-val" || echo "green-val")">${STALE_COUNT}</div><div class="lbl">Stale Branches</div></div>
  <div class="metric"><div class="val $([ "$MERGED_COUNT" -gt 0 ] && echo "blue-val" || echo "green-val")">${MERGED_COUNT}</div><div class="lbl">Ghost Branches</div></div>
  <div class="metric"><div class="val green-val">${OK_COUNT}</div><div class="lbl">Clean Flow</div></div>
  <div class="metric"><div class="val">${TOTAL_BRANCHES}</div><div class="lbl">Total Branches</div></div>
</div>

<div style="display: grid; grid-template-columns: 2fr 1fr; gap: 24px; margin-bottom: 40px;">
  <section style="margin-bottom: 0;">
    <h2>🏆 Author Leaderboard</h2>
    <table>
      <tr><th>Developer</th><th>Clean Branches</th><th>Violations</th><th>Health</th></tr>
      ${LEADERBOARD_HTML}
    </table>
  </section>
  <section style="margin-bottom: 0;">
    <h2>🧹 Ghost Branches</h2>
    <div style="font-size:12px; color:#6c757d; margin-bottom:10px;">Merged safely to master. Ready for deletion.</div>
    <table>
      ${MERGED_ROWS}
    </table>
  </section>
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

</body>
</html>
HTMLEOF

# ==========================================
# GENERATE JSON EXPORT
# ==========================================
if [ "$GENERATE_JSON" = true ]; then
  cat > "$JSON_OUTPUT" << JSONEOF
{
  "repository": "${REPO_NAME}",
  "generated_at": "${REPORT_DATE}",
  "metrics": {
    "total_branches": ${TOTAL_BRANCHES},
    "clean_branches": ${OK_COUNT},
    "violations": ${VIOLATION_COUNT},
    "direct_pushes": ${DIRECT_COUNT},
    "stale_branches": ${STALE_COUNT},
    "ghost_branches": ${MERGED_COUNT}
  },
  "status": "$([ "$TOTAL_ISSUES" -gt 0 ] && echo "FAIL" || echo "PASS")"
}
JSONEOF
fi

# ==========================================
# TERMINAL OUTPUT & CI/CD ENFORCEMENT
# ==========================================
echo ""
echo -e "${C_GREEN}✓ Report saved: ${OUTPUT}${C_NC}"
[ "$GENERATE_JSON" = true ] && echo -e "${C_GREEN}✓ JSON Data saved: ${JSON_OUTPUT}${C_NC}"
echo "-------------------------------------"
echo -e "  Violations     : $([ "$VIOLATION_COUNT" -gt 0 ] && echo "${C_RED}${VIOLATION_COUNT}${C_NC}" || echo "${C_GREEN}0${C_NC}")"
echo -e "  Direct Pushes  : $([ "$DIRECT_COUNT" -gt 0 ] && echo "${C_YELLOW}${DIRECT_COUNT}${C_NC}" || echo "${C_GREEN}0${C_NC}")"
echo -e "  Ghost Branches : $([ "$MERGED_COUNT" -gt 0 ] && echo "${C_BLUE}${MERGED_COUNT}${C_NC}" || echo "${C_GREEN}0${C_NC}")"
echo "-------------------------------------"

if [ "$STRICT_MODE" = true ]; then
  if [ "$TOTAL_ISSUES" -gt 0 ]; then
    echo -e "${C_RED}🚨 STRICT MODE: Failed! Found ${TOTAL_ISSUES} workflow issues.${C_NC}"
    exit 1
  else
    echo -e "${C_GREEN}✅ STRICT MODE: Passed! Repository is clean.${C_NC}"
    exit 0
  fi
fi