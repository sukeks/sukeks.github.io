#!/bin/bash

MASTER="origin/master"
DEVELOP="origin/develop"
QA="origin/qa"
OUTPUT="audit_report.html"

# Fix: Added quotes around the command substitution to handle paths with spaces safely
REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" || echo "Repository")
REPORT_DATE=$(date +"%Y-%m-%d %H:%M:%S")

echo "Fetching from remote..."
git fetch --all --prune -q

FEATURE_BRANCHES=$(git branch -r | grep -v "HEAD\|master\|develop\|qa\|release\|hotfix" | sed 's/^ *//')

VIOLATIONS=""
OK_BRANCHES=""
VIOLATION_COUNT=0
OK_COUNT=0

for BRANCH in $FEATURE_BRANCHES; do
  FORK=$(git merge-base $MASTER $BRANCH 2>/dev/null)
  [ -z "$FORK" ] && continue

  ON_MASTER=$(git branch -r --contains $FORK 2>/dev/null | grep "origin/master" | wc -l | tr -d ' ')
  CREATOR=$(git log $BRANCH --not $MASTER --pretty=format:"%an" --date=short | tail -1)
  EMAIL=$(git log $BRANCH --not $MASTER --pretty=format:"%ae" --date=short | tail -1)
  DATE=$(git log $BRANCH --not $MASTER --pretty=format:"%ad" --date=short | tail -1)
  COMMITS=$(git log $BRANCH --not $MASTER --oneline | wc -l | tr -d ' ')

  if [ "$ON_MASTER" -eq "0" ]; then
    VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
    
    ON_DEV=$(git branch -r --contains $FORK 2>/dev/null | grep "origin/develop" | wc -l | tr -d ' ')
    
    # Violation Type 1 & 2: branched from develop or qa instead of master
    [ "$ON_DEV" -gt "0" ] && SOURCE="develop" || SOURCE="qa"

    VIOLATIONS="${VIOLATIONS}
    <tr class=\"violation\">
      <td><span class=\"badge red\">${BRANCH##origin/}</span></td>
      <td>from ${SOURCE}</td>
      <td>${CREATOR}</td>
      <td>${EMAIL}</td>
      <td>${DATE}</td>
      <td>${COMMITS}</td>
      <td><code>${FORK:0:7}</code></td>
    </tr>"
  else
    OK_COUNT=$((OK_COUNT + 1))
    
    # Correct flow: branched from master
    OK_BRANCHES="${OK_BRANCHES}
    <tr class=\"ok\">
      <td><span class=\"badge green\">${BRANCH##origin/}</span></td>
      <td>from master</td>
      <td>${CREATOR}</td>
      <td>${EMAIL}</td>
      <td>${DATE}</td>
      <td>${COMMITS}</td>
      <td><code>${FORK:0:7}</code></td>
    </tr>"
  fi
done

# Violation Type 3: Direct pushes to develop or qa (ignoring merged branches via --first-parent)
DIRECT_DEV=$(git log $DEVELOP --not $MASTER --first-parent --no-merges \
  --pretty=format:"<tr class=\"direct\"><td><span class=\"badge amber\">develop</span></td><td>%an</td><td>%ae</td><td>%ad</td><td>%s</td><td><code>%h</code></td></tr>" \
  --date=short)

DIRECT_QA=$(git log $QA --not $MASTER --first-parent --no-merges \
  --pretty=format:"<tr class=\"direct\"><td><span class=\"badge amber\">qa</span></td><td>%an</td><td>%ae</td><td>%ad</td><td>%s</td><td><code>%h</code></td></tr>" \
  --date=short)

# Fix: Search for `<tr` instead of `<tr>` to accurately count rows with CSS classes
DIRECT_COUNT=$(echo -e "${DIRECT_DEV}\n${DIRECT_QA}" | grep -c "<tr")

cat > "$OUTPUT" << HTMLEOF
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Branch Audit — ${REPO_NAME}</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
           max-width: 1100px; margin: 40px auto; padding: 0 24px;
           background: #f8f8f6; color: #1a1a18; font-size: 14px; }
    h1 { font-size: 22px; font-weight: 600; margin-bottom: 4px; }
    .meta { color: #888; font-size: 13px; margin-bottom: 28px; }
    .summary { display: grid; grid-template-columns: repeat(4,1fr); gap: 12px; margin-bottom: 32px; }
    .metric { background: #fff; border: 1px solid #e8e8e4; border-radius: 10px;
              padding: 16px; text-align: center; }
    .metric .val { font-size: 32px; font-weight: 600; }
    .metric .lbl { font-size: 12px; color: #888; margin-top: 4px; }
    .red-val { color: #c0392b; }
    .green-val { color: #27ae60; }
    .amber-val { color: #d68910; }
    section { margin-bottom: 32px; }
    h2 { font-size: 15px; font-weight: 600; margin-bottom: 12px;
         padding-bottom: 8px; border-bottom: 1px solid #e8e8e4; }
    table { width: 100%; border-collapse: collapse; background: #fff;
            border: 1px solid #e8e8e4; border-radius: 10px; overflow: hidden; }
    th { text-align: left; padding: 10px 14px; background: #f4f4f0;
         font-size: 12px; color: #666; font-weight: 500; }
    td { padding: 10px 14px; border-top: 1px solid #f0f0ec; font-size: 13px; }
    tr.violation td { background: #fff9f9; }
    tr.ok td { background: #f9fff9; }
    tr.direct td { background: #fffbf2; }
    .badge { display: inline-block; padding: 2px 9px; border-radius: 99px;
             font-size: 11px; font-weight: 600; }
    .badge.red { background: #fde8e8; color: #922b21; }
    .badge.green { background: #e8f8ee; color: #1e7e34; }
    .badge.amber { background: #fef9e7; color: #9a7d0a; }
    code { font-family: 'SF Mono', Consolas, monospace; font-size: 11px;
           background: #f0f0ec; padding: 1px 5px; border-radius: 4px; }
    .footer { font-size: 12px; color: #aaa; margin-top: 40px; text-align: center; }
  </style>
</head>
<body>

<h1>Branch Audit Report — ${REPO_NAME}</h1>
<div class="meta">Generated: ${REPORT_DATE}  ·  Rule: all feature branches must be created from master</div>

<div class="summary">
  <div class="metric"><div class="val red-val">${VIOLATION_COUNT}</div><div class="lbl">Violations</div></div>
  <div class="metric"><div class="val green-val">${OK_COUNT}</div><div class="lbl">Following rules</div></div>
  <div class="metric"><div class="val amber-val">${DIRECT_COUNT}</div><div class="lbl">Direct pushes</div></div>
  <div class="metric"><div class="val">$(( VIOLATION_COUNT + OK_COUNT ))</div><div class="lbl">Total branches</div></div>
</div>

<section>
  <h2>❌ Violations — not branched from master</h2>
  <table>
    <tr><th>Branch</th><th>Source</th><th>Author</th><th>Email</th><th>Date</th><th>Commits</th><th>Fork SHA</th></tr>
    ${VIOLATIONS}
  </table>
</section>

<section>
  <h2>⚠️ Direct pushes (no feature branch)</h2>
  <table>
    <tr><th>Target</th><th>Author</th><th>Email</th><th>Date</th><th>Message</th><th>SHA</th></tr>
    ${DIRECT_DEV}
    ${DIRECT_QA}
  </table>
</section>

<section>
  <h2>✅ Correct — branched from master</h2>
  <table>
    <tr><th>Branch</th><th>Status</th><th>Author</th><th>Email</th><th>Date</th><th>Commits</th><th>Fork SHA</th></tr>
    ${OK_BRANCHES}
  </table>
</section>

<div class="footer">Generated by audit_report.sh</div>

</body>
</html>
HTMLEOF

echo "✓ Report saved to: ${OUTPUT}"
echo "  Violations : ${VIOLATION_COUNT}"
echo "  Clean      : ${OK_COUNT}"
echo "  Direct push: ${DIRECT_COUNT}"