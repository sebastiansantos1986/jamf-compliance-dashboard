#!/bin/bash

##
# Script Name: jamf_collect_os_versions.sh
# Description: Collects OS version information for all computers in JAMF Pro
#              and generates an HTML compliance dashboard with computer details
# Date: 2025-11-26
# Version: 5.0
##

# --- Configuration ---
JAMF_URL=""
JAMF_CLIENT_ID=""
JAMF_CLIENT_SECRET=""

DEBUG_MODE="false"
AUTO_OPEN_BROWSER="true"

OUTPUT_DIR="/Users/sebastian.santos/Downloads/Reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${OUTPUT_DIR}/jamf_os_report_${TIMESTAMP}.csv"
HTML_FILE="${OUTPUT_DIR}/jamf_os_dashboard_${TIMESTAMP}.html"

prompt_credentials() {
    [[ -z "$JAMF_URL" ]] && read -rp "Enter JAMF Pro URL: " JAMF_URL
    JAMF_URL="${JAMF_URL%/}"
    [[ -z "$JAMF_CLIENT_ID" ]] && read -rp "Enter API Client ID: " JAMF_CLIENT_ID
    [[ -z "$JAMF_CLIENT_SECRET" ]] && read -rsp "Enter API Client Secret: " JAMF_CLIENT_SECRET && echo ""
}

get_bearer_token() {
    echo "Authenticating with JAMF Pro API..."
    TOKEN_RESPONSE=$(curl -s -X POST "${JAMF_URL}/api/oauth/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials&client_id=${JAMF_CLIENT_ID}&client_secret=${JAMF_CLIENT_SECRET}")
    BEARER_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
    [[ -z "$BEARER_TOKEN" ]] && echo "Error: Authentication failed." && exit 1
    echo "Authentication successful."
}

get_total_computers() {
    local RESPONSE=$(curl -s -X GET "${JAMF_URL}/api/v1/computers-inventory?section=GENERAL&page=0&page-size=1" \
        -H "Authorization: Bearer ${BEARER_TOKEN}" -H "Accept: application/json")
    echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('totalCount', 0))" 2>/dev/null
}

collect_os_versions() {
    local PAGE_SIZE=100 PAGE=0
    local TOTAL_COMPUTERS=$(get_total_computers)
    [[ "$TOTAL_COMPUTERS" == "0" ]] && echo "Error: No computers found." && exit 1
    
    echo "Total computers in JAMF: $TOTAL_COMPUTERS"
    echo ""
    echo "Computer ID,Computer Name,Serial Number,OS Version,OS Build,Last Check-In,Username" > "$OUTPUT_FILE"
    echo "Collecting OS version data..."
    
    local TEMP_RESPONSE="/tmp/jamf_response_$$.json"
    while true; do
        echo "  Fetching page $((PAGE + 1))..."
        curl -s -X GET "${JAMF_URL}/api/v1/computers-inventory?section=GENERAL&section=HARDWARE&section=OPERATING_SYSTEM&section=USER_AND_LOCATION&page=${PAGE}&page-size=${PAGE_SIZE}" \
            -H "Authorization: Bearer ${BEARER_TOKEN}" -H "Accept: application/json" > "$TEMP_RESPONSE"
        
        python3 << PYPARSE >> "$OUTPUT_FILE"
import json
with open('$TEMP_RESPONSE', 'r') as f:
    for c in json.load(f).get('results', []):
        g = c.get('general', {}) or {}
        h = c.get('hardware', {}) or {}
        o = c.get('operatingSystem', {}) or {}
        u = c.get('userAndLocation', {}) or {}
        print(f"{c.get('id','')},{(g.get('name') or '').replace(',', ' ')},{h.get('serialNumber') or ''},{o.get('version') or ''},{o.get('build') or ''},{g.get('lastContactTime') or ''},{(u.get('username') or '').replace(',', ' ')}")
PYPARSE
        
        RESULT_COUNT=$(python3 -c "import json; print(len(json.load(open('$TEMP_RESPONSE')).get('results', [])))" 2>/dev/null)
        [[ -z "$RESULT_COUNT" || "$RESULT_COUNT" == "0" ]] && break
        PAGE=$((PAGE + 1))
        [[ $((PAGE * PAGE_SIZE)) -ge $TOTAL_COMPUTERS ]] && break
        sleep 0.5
    done
    rm -f "$TEMP_RESPONSE"
}

generate_summary() {
    echo ""
    echo "=== OS Version Summary ==="
    tail -n +2 "$OUTPUT_FILE" | cut -d',' -f4 | sort | uniq -c | sort -rn | head -15 | while read -r count version; do
        printf "  %-20s : %s computers\n" "$version" "$count"
    done
}

generate_html_dashboard() {
    echo ""
    echo "Generating HTML dashboard..."
    
    export OUTPUT_FILE_PATH="$OUTPUT_FILE"
    export HTML_FILE_PATH="$HTML_FILE"
    export OUTPUT_DIR_PATH="$OUTPUT_DIR"
    
    python3 /dev/stdin << 'PYPYTHON'
import json, csv, os, glob
from datetime import datetime

OUTPUT_FILE = os.environ['OUTPUT_FILE_PATH']
HTML_FILE = os.environ['HTML_FILE_PATH']
OUTPUT_DIR = os.environ['OUTPUT_DIR_PATH']

def get_prev():
    files = sorted(glob.glob(os.path.join(OUTPUT_DIR, 'jamf_os_report_*.csv')))
    files = [f for f in files if f != OUTPUT_FILE]
    if not files: return None, None
    pf = files[-1]
    pd = {'compliant': 0, 'non_compliant': 0, 'total': 0}
    with open(pf, 'r') as f:
        reader = csv.reader(f)
        next(reader)
        for row in reader:
            if len(row) >= 4 and row[3]:
                pd['total'] += 1
                v = row[3].split('.')
                major = int(v[0]) if v else 0
                minor = int(v[1]) if len(v) > 1 else 0
                patch = int(v[2]) if len(v) > 2 else 0
                if major >= 26 or (major == 15 and (minor > 7 or (minor == 7 and patch >= 2))):
                    pd['compliant'] += 1
                else:
                    pd['non_compliant'] += 1
    pdate = os.path.basename(pf).replace('jamf_os_report_', '').replace('.csv', '')
    return pd, pdate

prev_report, prev_date = get_prev()

version_counts = {}
computer_list = []
with open(OUTPUT_FILE, 'r') as f:
    reader = csv.reader(f)
    next(reader)
    for row in reader:
        if len(row) >= 4 and row[3]:
            version_counts[row[3]] = version_counts.get(row[3], 0) + 1
            computer_list.append({'id': row[0], 'name': row[1], 'serial': row[2], 'version': row[3], 
                                  'build': row[4] if len(row) > 4 else '', 
                                  'lastCheckin': row[5] if len(row) > 5 else '', 
                                  'user': row[6] if len(row) > 6 else ''})

os_data_json = json.dumps([{"version": v, "count": c} for v, c in version_counts.items()])
computer_data_json = json.dumps(computer_list)
prev_report_json = json.dumps(prev_report) if prev_report else 'null'
prev_date_str = prev_date if prev_date else ''
report_date = datetime.now().strftime("%A, %B %d, %Y")

html = f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>macOS Compliance Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{font-family:'Inter',-apple-system,sans-serif;background:#0f0f1a;min-height:100vh;color:#fff}}
.nav-tabs{{display:flex;background:#1a1a2e;border-bottom:1px solid rgba(255,255,255,0.1);padding:0 30px;position:sticky;top:0;z-index:100}}
.nav-tab{{padding:18px 28px;font-size:14px;font-weight:500;color:rgba(255,255,255,0.5);cursor:pointer;border-bottom:2px solid transparent}}
.nav-tab:hover{{color:rgba(255,255,255,0.8)}}.nav-tab.active{{color:#fff;border-bottom-color:#10B981}}
.tab-content{{display:none;padding:30px}}.tab-content.active{{display:block}}
.dashboard{{max-width:1600px;margin:0 auto}}
.header{{display:flex;justify-content:space-between;align-items:center;margin-bottom:30px}}
.header h1{{font-size:24px;font-weight:600}}.header-meta{{color:rgba(255,255,255,0.5);font-size:13px}}
.card{{background:linear-gradient(145deg,#1e1e32,#1a1a2e);border-radius:20px;padding:28px;border:1px solid rgba(255,255,255,0.06)}}
.card-title{{font-size:12px;font-weight:600;color:rgba(255,255,255,0.4);text-transform:uppercase;letter-spacing:1px;margin-bottom:20px}}
.main-grid{{display:grid;grid-template-columns:420px 1fr;gap:25px}}
.left-column,.right-column{{display:flex;flex-direction:column;gap:25px}}

/* Radial Gauge with Icons Around Arc */
.gauge-card{{text-align:center;padding:30px 20px}}
.radial-gauge{{position:relative;width:320px;height:220px;margin:0 auto}}
.radial-gauge svg.gauge-svg{{width:320px;height:180px;overflow:visible}}
.gauge-center-text{{position:absolute;top:95px;left:50%;transform:translateX(-50%);text-align:center}}
.gauge-percent{{font-size:48px;font-weight:700;line-height:1}}
.gauge-percent.excellent{{color:#10B981}}
.gauge-percent.good{{color:#84CC16}}
.gauge-percent.fair{{color:#EAB308}}
.gauge-percent.poor{{color:#F97316}}
.gauge-percent.critical{{color:#EF4444}}
.gauge-sublabel{{font-size:13px;color:rgba(255,255,255,0.5);margin-top:4px}}

/* Radial icons positioned around arc */
.radial-icon{{position:absolute;display:flex;flex-direction:column;align-items:center;gap:4px}}
.radial-icon .icon-circle{{width:40px;height:40px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:16px;border:3px solid;background:rgba(15,15,26,0.95)}}
.radial-icon .icon-label{{font-size:8px;color:rgba(255,255,255,0.5);text-transform:uppercase;letter-spacing:0.5px;font-weight:600}}
.radial-icon.pos1{{left:5px;bottom:15px}}
.radial-icon.pos2{{left:25px;top:55px}}
.radial-icon.pos3{{left:50%;top:0px;transform:translateX(-50%)}}
.radial-icon.pos4{{right:25px;top:55px}}
.radial-icon.pos5{{right:5px;bottom:15px}}
.radial-icon .icon-circle.red{{border-color:#EF4444;color:#EF4444}}
.radial-icon .icon-circle.orange{{border-color:#F97316;color:#F97316}}
.radial-icon .icon-circle.yellow{{border-color:#EAB308;color:#EAB308}}
.radial-icon .icon-circle.lime{{border-color:#84CC16;color:#84CC16}}
.radial-icon .icon-circle.green{{border-color:#10B981;color:#10B981}}

/* Stats with comparison */
.stats-row{{display:flex;gap:12px;margin-top:20px}}
.stat-box{{flex:1;background:rgba(255,255,255,0.03);border-radius:14px;padding:16px 12px;text-align:center;border:1px solid rgba(255,255,255,0.05)}}
.stat-box .value{{font-size:32px;font-weight:700}}
.stat-box .label{{font-size:10px;color:rgba(255,255,255,0.5);margin-top:2px;text-transform:uppercase;letter-spacing:0.5px}}
.stat-box .comparison{{margin-top:10px;display:flex;align-items:center;justify-content:center;gap:6px}}
.stat-box .prev-val{{font-size:11px;color:rgba(255,255,255,0.35)}}
.stat-box .delta{{font-size:11px;font-weight:600;padding:2px 8px;border-radius:10px}}
.stat-box .delta.up{{background:rgba(16,185,129,0.2);color:#10B981}}
.stat-box .delta.down{{background:rgba(239,68,68,0.2);color:#EF4444}}
.stat-box .delta.neutral{{background:rgba(255,255,255,0.08);color:rgba(255,255,255,0.4)}}
.stat-box.green .value{{color:#10B981}}.stat-box.red .value{{color:#EF4444}}.stat-box.blue .value{{color:#3B82F6}}

/* Header with comparison banner */
.header-row{{display:flex;justify-content:space-between;align-items:center;margin-bottom:25px}}
.prev-banner{{background:linear-gradient(135deg,rgba(59,130,246,0.12),rgba(139,92,246,0.08));border:1px solid rgba(59,130,246,0.2);border-radius:14px;padding:14px 20px;margin-bottom:25px;display:flex;align-items:center;gap:14px}}
.prev-banner .icon{{font-size:22px}}
.prev-banner .text{{color:rgba(255,255,255,0.8);font-size:14px;flex:1}}
.prev-banner .date{{color:#60A5FA;font-weight:600}}
.pct-badge{{font-size:13px;padding:8px 14px;border-radius:10px;font-weight:600}}
.pct-badge.up{{background:rgba(16,185,129,0.2);color:#10B981}}
.pct-badge.down{{background:rgba(239,68,68,0.2);color:#EF4444}}
.pct-badge.neutral{{background:rgba(255,255,255,0.1);color:rgba(255,255,255,0.5)}}

.version-item{{display:flex;align-items:center;gap:12px;padding:12px 0;border-bottom:1px solid rgba(255,255,255,0.05)}}
.version-item:last-child{{border-bottom:none}}.version-info{{flex:1}}
.version-name{{font-size:14px;font-weight:500;color:rgba(255,255,255,0.9)}}.version-count{{font-size:12px;color:rgba(255,255,255,0.4)}}
.version-bar-wrapper{{width:120px;display:flex;align-items:center;gap:8px}}
.version-bar{{flex:1;height:8px;background:rgba(255,255,255,0.1);border-radius:4px;overflow:hidden}}
.version-bar-fill{{height:100%;border-radius:4px}}.version-bar-fill.green{{background:linear-gradient(90deg,#10B981,#34D399)}}.version-bar-fill.red{{background:linear-gradient(90deg,#EF4444,#F87171)}}
.version-pct{{font-size:12px;color:rgba(255,255,255,0.5);min-width:40px;text-align:right}}
.version-list{{max-height:320px;overflow-y:auto}}.version-list::-webkit-scrollbar{{width:4px}}.version-list::-webkit-scrollbar-thumb{{background:rgba(255,255,255,0.1);border-radius:2px}}
.charts-row{{display:grid;grid-template-columns:1fr 1fr;gap:25px}}.chart-container{{height:280px}}
.req-item{{display:flex;align-items:center;gap:12px;padding:14px;background:rgba(255,255,255,0.03);border-radius:10px;margin-bottom:10px}}
.req-item:last-child{{margin-bottom:0}}.req-icon{{width:36px;height:36px;border-radius:10px;background:rgba(16,185,129,0.15);display:flex;align-items:center;justify-content:center;font-size:18px}}
.req-text{{font-size:14px;color:rgba(255,255,255,0.8)}}.req-text span{{display:block;font-size:11px;color:rgba(255,255,255,0.4);margin-top:2px}}
.table-controls{{display:flex;gap:15px;margin-bottom:20px;flex-wrap:wrap}}
.search-box{{flex:1;min-width:250px;position:relative}}
.search-box input{{width:100%;padding:12px 16px 12px 44px;background:rgba(255,255,255,0.05);border:1px solid rgba(255,255,255,0.1);border-radius:10px;color:#fff;font-size:14px;outline:none}}
.search-box input:focus{{border-color:#10B981}}.search-box input::placeholder{{color:rgba(255,255,255,0.3)}}
.search-box::before{{content:'🔍';position:absolute;left:16px;top:50%;transform:translateY(-50%);font-size:14px;opacity:0.5}}
.filter-btn{{padding:12px 20px;background:rgba(255,255,255,0.05);border:1px solid rgba(255,255,255,0.1);border-radius:10px;color:rgba(255,255,255,0.7);font-size:13px;cursor:pointer}}
.filter-btn:hover{{background:rgba(255,255,255,0.1)}}.filter-btn.active{{background:#10B981;border-color:#10B981;color:#fff}}.filter-btn.active.red{{background:#EF4444;border-color:#EF4444}}
.data-table{{width:100%;border-collapse:collapse}}
.data-table th{{text-align:left;padding:14px 16px;font-size:11px;font-weight:600;color:rgba(255,255,255,0.4);text-transform:uppercase;letter-spacing:0.5px;border-bottom:1px solid rgba(255,255,255,0.1);background:rgba(0,0,0,0.2);position:sticky;top:0;cursor:pointer}}
.data-table th:hover{{color:rgba(255,255,255,0.7)}}
.data-table td{{padding:14px 16px;font-size:13px;border-bottom:1px solid rgba(255,255,255,0.05);color:rgba(255,255,255,0.8)}}
.data-table tr:hover td{{background:rgba(255,255,255,0.02)}}
.status-badge{{display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border-radius:20px;font-size:11px;font-weight:500}}
.status-badge.compliant{{background:rgba(16,185,129,0.15);color:#10B981}}.status-badge.non-compliant{{background:rgba(239,68,68,0.15);color:#EF4444}}
.status-dot{{width:6px;height:6px;border-radius:50%;background:currentColor}}
.table-wrapper{{max-height:600px;overflow-y:auto;border-radius:12px;border:1px solid rgba(255,255,255,0.05)}}
.table-wrapper::-webkit-scrollbar{{width:6px}}.table-wrapper::-webkit-scrollbar-thumb{{background:rgba(255,255,255,0.1);border-radius:3px}}
.table-footer{{display:flex;justify-content:space-between;align-items:center;margin-top:16px;color:rgba(255,255,255,0.5);font-size:13px}}
.export-btn{{padding:10px 20px;background:#10B981;border:none;border-radius:8px;color:#fff;font-size:13px;font-weight:500;cursor:pointer}}.export-btn:hover{{background:#0d9668}}
@media(max-width:1200px){{.main-grid{{grid-template-columns:1fr}}.charts-row{{grid-template-columns:1fr}}}}
</style>
</head>
<body>
<div class="nav-tabs">
<div class="nav-tab active" onclick="showTab('overview')">Overview</div>
<div class="nav-tab" onclick="showTab('details')">Computer Details</div>
</div>
<div id="overview" class="tab-content active">
<div class="dashboard">
<div class="header-row">
<div><h1>macOS Fleet Compliance</h1><div class="header-meta">Weekly Report • {report_date}</div></div>
<div class="pct-badge" id="pctBadge" style="display:none"></div>
</div>
<div id="prevBanner" class="prev-banner" style="display:none">
<span class="icon">📊</span>
<span class="text">Comparing with previous report from <span class="date" id="prevDate">{prev_date_str}</span></span>
</div>
<div class="main-grid">
<div class="left-column">
<div class="card gauge-card">
<div class="card-title">Compliance Rate</div>
<div class="radial-gauge">
<svg class="gauge-svg" viewBox="0 0 320 180">
<defs>
<linearGradient id="gaugeGrad" x1="0%" y1="0%" x2="100%" y2="0%">
<stop offset="0%" stop-color="#EF4444"/>
<stop offset="25%" stop-color="#F97316"/>
<stop offset="50%" stop-color="#EAB308"/>
<stop offset="75%" stop-color="#84CC16"/>
<stop offset="100%" stop-color="#10B981"/>
</linearGradient>
</defs>
<!-- Background arc -->
<path d="M 30 160 A 130 130 0 0 1 290 160" stroke="rgba(255,255,255,0.1)" stroke-width="20" fill="none" stroke-linecap="round"/>
<!-- Colored arc segments -->
<path d="M 30 160 A 130 130 0 0 1 68 72" stroke="#EF4444" stroke-width="20" fill="none" stroke-linecap="round"/>
<path d="M 68 72 A 130 130 0 0 1 134 25" stroke="#F97316" stroke-width="20" fill="none"/>
<path d="M 134 25 A 130 130 0 0 1 186 25" stroke="#EAB308" stroke-width="20" fill="none"/>
<path d="M 186 25 A 130 130 0 0 1 252 72" stroke="#84CC16" stroke-width="20" fill="none"/>
<path d="M 252 72 A 130 130 0 0 1 290 160" stroke="#10B981" stroke-width="20" fill="none" stroke-linecap="round"/>
<!-- Needle -->
<line id="gaugeNeedle" x1="160" y1="160" x2="160" y2="45" stroke="white" stroke-width="4" stroke-linecap="round" transform="rotate(-90, 160, 160)">
<animate attributeName="transform" dur="1.5s" fill="freeze" calcMode="spline" keySplines="0.34 1.56 0.64 1"/>
</line>
<circle cx="160" cy="160" r="10" fill="white"/>
</svg>
<!-- Icons around the arc -->
<div class="radial-icon pos1"><div class="icon-circle red">✗</div><div class="icon-label">Critical</div></div>
<div class="radial-icon pos2"><div class="icon-circle orange">⚠</div><div class="icon-label">Poor</div></div>
<div class="radial-icon pos3"><div class="icon-circle yellow">◐</div><div class="icon-label">Fair</div></div>
<div class="radial-icon pos4"><div class="icon-circle lime">◑</div><div class="icon-label">Good</div></div>
<div class="radial-icon pos5"><div class="icon-circle green">✓</div><div class="icon-label">Excellent</div></div>
<!-- Center percentage -->
<div class="gauge-center-text">
<div class="gauge-percent" id="gaugePercent">0%</div>
<div class="gauge-sublabel">Compliant</div>
</div>
</div>
<div class="stats-row">
<div class="stat-box green"><div class="value" id="cCount">0</div><div class="label">Compliant</div><div class="comparison" id="cComp"></div></div>
<div class="stat-box red"><div class="value" id="nCount">0</div><div class="label">Non-Compliant</div><div class="comparison" id="nComp"></div></div>
<div class="stat-box blue"><div class="value" id="tCount">0</div><div class="label">Total</div><div class="comparison" id="tComp"></div></div>
</div>
</div>
<div class="card">
<div class="card-title">Compliance Requirements</div>
<div class="req-item"><div class="req-icon">✓</div><div class="req-text">macOS 15.7.2 or higher<span>Sequoia security update</span></div></div>
<div class="req-item"><div class="req-icon">✓</div><div class="req-text">macOS 26.0 or higher<span>Latest major version</span></div></div>
</div>
</div>
<div class="right-column">
<div class="charts-row">
<div class="card"><div class="card-title">OS Distribution</div><div class="chart-container"><canvas id="distChart"></canvas></div></div>
<div class="card"><div class="card-title">Major Versions</div><div class="chart-container"><canvas id="majorChart"></canvas></div></div>
</div>
<div class="charts-row">
<div class="card"><div class="card-title">Compliant Versions</div><div class="version-list" id="cList"></div></div>
<div class="card"><div class="card-title">Non-Compliant Versions</div><div class="version-list" id="nList"></div></div>
</div>
</div>
</div>
</div>
</div>
<div id="details" class="tab-content">
<div class="dashboard">
<div class="header"><div><h1>Computer Details</h1><div class="header-meta">All managed devices</div></div></div>
<div class="card">
<div class="table-controls">
<div class="search-box"><input type="text" id="searchInput" placeholder="Search by name, serial, user, or version..."></div>
<button class="filter-btn active" onclick="filterTable('all',this)">All</button>
<button class="filter-btn" onclick="filterTable('compliant',this)">✓ Compliant</button>
<button class="filter-btn red" onclick="filterTable('non-compliant',this)">✗ Non-Compliant</button>
</div>
<div class="table-wrapper"><table class="data-table"><thead><tr>
<th onclick="sortTable(0)">Computer Name ↕</th><th onclick="sortTable(1)">Serial ↕</th><th onclick="sortTable(2)">OS Version ↕</th><th onclick="sortTable(3)">Build ↕</th><th onclick="sortTable(4)">Last Check-In ↕</th><th onclick="sortTable(5)">User ↕</th><th onclick="sortTable(6)">Status ↕</th>
</tr></thead><tbody id="tableBody"></tbody></table></div>
<div class="table-footer"><span id="tableCount">Showing 0 computers</span><button class="export-btn" onclick="exportCSV()">Export CSV</button></div>
</div>
</div>
</div>
<script>
const osData={os_data_json};
const computerData={computer_data_json};
const prevReport={prev_report_json};
const prevDateStr="{prev_date_str}";
let currentFilter='all',sortCol=0,sortAsc=true;

function parseV(v){{const p=v.split('.').map(x=>parseInt(x)||0);return{{major:p[0]||0,minor:p[1]||0,patch:p[2]||0}};}}
function isComp(v){{const ver=parseV(v);if(ver.major>=26)return true;if(ver.major===15&&(ver.minor>7||(ver.minor===7&&ver.patch>=2)))return true;return false;}}
function showTab(id){{document.querySelectorAll('.tab-content').forEach(t=>t.classList.remove('active'));document.querySelectorAll('.nav-tab').forEach(t=>t.classList.remove('active'));document.getElementById(id).classList.add('active');event.target.classList.add('active');}}

function formatPrevDate(ds){{
if(!ds)return'';
const y=ds.substring(0,4),m=parseInt(ds.substring(4,6))-1,d=ds.substring(6,8),h=ds.substring(9,11),min=ds.substring(11,13);
return new Date(y,m,d,h,min).toLocaleDateString('en-US',{{month:'short',day:'numeric',year:'numeric',hour:'numeric',minute:'2-digit'}});
}}

function init(){{
const total=osData.reduce((s,d)=>s+d.count,0);
let cc=0,nc=0;const cv=[],nv=[];
osData.forEach(d=>{{if(isComp(d.version)){{cc+=d.count;cv.push(d);}}else{{nc+=d.count;nv.push(d);}}}});
const pct=total>0?((cc/total)*100).toFixed(1):0;

// Update gauge
const rotation=-90+(pct*1.8);
document.getElementById('gaugeNeedle').setAttribute('transform','rotate('+rotation+', 160, 160)');
const gp=document.getElementById('gaugePercent');
gp.textContent=pct+'%';
if(pct>=80)gp.className='gauge-percent excellent';
else if(pct>=60)gp.className='gauge-percent good';
else if(pct>=40)gp.className='gauge-percent fair';
else if(pct>=20)gp.className='gauge-percent poor';
else gp.className='gauge-percent critical';

document.getElementById('cCount').textContent=cc;
document.getElementById('nCount').textContent=nc;
document.getElementById('tCount').textContent=total;

// Comparison with previous
if(prevReport){{
document.getElementById('prevBanner').style.display='flex';
document.getElementById('prevDate').textContent=formatPrevDate(prevDateStr);

const prevPct=prevReport.total>0?(prevReport.compliant/prevReport.total)*100:0;
const pctDiff=(pct-prevPct).toFixed(1);
const pctBadge=document.getElementById('pctBadge');
pctBadge.style.display='block';
if(pctDiff>0){{pctBadge.className='pct-badge up';pctBadge.textContent='↑ '+pctDiff+'% improvement';}}
else if(pctDiff<0){{pctBadge.className='pct-badge down';pctBadge.textContent='↓ '+Math.abs(pctDiff)+'% decline';}}
else{{pctBadge.className='pct-badge neutral';pctBadge.textContent='No change';}}

const cDiff=cc-prevReport.compliant;
document.getElementById('cComp').innerHTML='<span class="prev-val">was '+prevReport.compliant+'</span><span class="delta '+(cDiff>0?'up':cDiff<0?'down':'neutral')+'">'+(cDiff>0?'+':'')+cDiff+'</span>';

const nDiff=nc-prevReport.non_compliant;
document.getElementById('nComp').innerHTML='<span class="prev-val">was '+prevReport.non_compliant+'</span><span class="delta '+(nDiff<0?'up':nDiff>0?'down':'neutral')+'">'+(nDiff>0?'+':'')+nDiff+'</span>';

const tDiff=total-prevReport.total;
document.getElementById('tComp').innerHTML='<span class="prev-val">was '+prevReport.total+'</span><span class="delta neutral">'+(tDiff>0?'+':'')+tDiff+'</span>';
}}else{{
document.querySelectorAll('.comparison').forEach(el=>el.style.display='none');
}}

new Chart(document.getElementById('distChart'),{{type:'doughnut',data:{{labels:['Compliant','Non-Compliant'],datasets:[{{data:[cc,nc],backgroundColor:['#10B981','#EF4444'],borderWidth:0,cutout:'70%'}}]}},options:{{responsive:true,maintainAspectRatio:false,plugins:{{legend:{{position:'bottom',labels:{{color:'rgba(255,255,255,0.6)',padding:20}}}}}}}}}});

const mg={{}};osData.forEach(d=>{{const m=parseV(d.version).major;mg['macOS '+m]=(mg['macOS '+m]||0)+d.count;}});
const sm=Object.entries(mg).sort((a,b)=>parseInt(b[0].replace('macOS ',''))-parseInt(a[0].replace('macOS ','')));
const colors=sm.map(v=>{{const m=parseInt(v[0].replace('macOS ',''));return m>=26?'#10B981':m===15?'#3B82F6':'#EF4444';}});
new Chart(document.getElementById('majorChart'),{{type:'bar',data:{{labels:sm.map(v=>v[0]),datasets:[{{data:sm.map(v=>v[1]),backgroundColor:colors,borderRadius:8,barThickness:28}}]}},options:{{indexAxis:'y',responsive:true,maintainAspectRatio:false,plugins:{{legend:{{display:false}}}},scales:{{x:{{grid:{{color:'rgba(255,255,255,0.05)'}},ticks:{{color:'rgba(255,255,255,0.4)'}}}},y:{{grid:{{display:false}},ticks:{{color:'rgba(255,255,255,0.7)'}}}}}}}}}});

function renderList(vers,id,isC){{
const el=document.getElementById(id);
el.innerHTML=vers.sort((a,b)=>b.count-a.count).map(v=>{{const p=((v.count/total)*100).toFixed(1);return'<div class="version-item"><div class="version-info"><div class="version-name">macOS '+v.version+'</div><div class="version-count">'+v.count+' device'+(v.count>1?'s':'')+'</div></div><div class="version-bar-wrapper"><div class="version-bar"><div class="version-bar-fill '+(isC?'green':'red')+'" style="width:'+Math.min(p*2,100)+'%"></div></div><span class="version-pct">'+p+'%</span></div></div>';}}).join('');
}}
renderList(cv,'cList',true);renderList(nv,'nList',false);renderTable();
}}

function renderTable(){{
const tbody=document.getElementById('tableBody');const st=document.getElementById('searchInput').value.toLowerCase();
let filtered=computerData.filter(c=>{{const ms=!st||c.name.toLowerCase().includes(st)||c.serial.toLowerCase().includes(st)||c.version.toLowerCase().includes(st)||(c.user&&c.user.toLowerCase().includes(st));const comp=isComp(c.version);const mf=currentFilter==='all'||(currentFilter==='compliant'&&comp)||(currentFilter==='non-compliant'&&!comp);return ms&&mf;}});
filtered.sort((a,b)=>{{let av,bv;switch(sortCol){{case 0:av=a.name;bv=b.name;break;case 1:av=a.serial;bv=b.serial;break;case 2:av=a.version;bv=b.version;break;case 3:av=a.build;bv=b.build;break;case 4:av=a.lastCheckin;bv=b.lastCheckin;break;case 5:av=a.user||'';bv=b.user||'';break;case 6:av=isComp(a.version)?1:0;bv=isComp(b.version)?1:0;break;}}if(av<bv)return sortAsc?-1:1;if(av>bv)return sortAsc?1:-1;return 0;}});
tbody.innerHTML=filtered.map(c=>{{const comp=isComp(c.version);const cd=c.lastCheckin?new Date(c.lastCheckin).toLocaleDateString('en-US',{{year:'numeric',month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}}):'—';return'<tr><td>'+c.name+'</td><td style="font-family:monospace;font-size:12px">'+c.serial+'</td><td>macOS '+c.version+'</td><td style="color:rgba(255,255,255,0.5)">'+(c.build||'—')+'</td><td style="color:rgba(255,255,255,0.5)">'+cd+'</td><td>'+(c.user||'—')+'</td><td><span class="status-badge '+(comp?'compliant':'non-compliant')+'"><span class="status-dot"></span>'+(comp?'Compliant':'Non-Compliant')+'</span></td></tr>';}}).join('');
document.getElementById('tableCount').textContent='Showing '+filtered.length+' of '+computerData.length+' computers';
}}

function filterTable(f,btn){{currentFilter=f;document.querySelectorAll('.filter-btn').forEach(b=>b.classList.remove('active'));btn.classList.add('active');renderTable();}}
function sortTable(col){{if(sortCol===col)sortAsc=!sortAsc;else{{sortCol=col;sortAsc=true;}}renderTable();}}
function exportCSV(){{let csv='Computer Name,Serial,OS Version,Build,Last Check-In,User,Status\\n';computerData.forEach(c=>{{csv+='"'+c.name+'","'+c.serial+'","'+c.version+'","'+(c.build||'')+'","'+(c.lastCheckin||'')+'","'+(c.user||'')+'","'+(isComp(c.version)?'Compliant':'Non-Compliant')+'"\\n';}});const blob=new Blob([csv],{{type:'text/csv'}});const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='compliance_report.csv';a.click();}}
document.getElementById('searchInput').addEventListener('input',renderTable);
init();
</script>
</body></html>'''

with open(HTML_FILE, 'w') as f:
    f.write(html)
print("HTML dashboard generated successfully.")
PYPYTHON
}

invalidate_token() {
    curl -s -X POST "${JAMF_URL}/api/v1/auth/invalidate-token" -H "Authorization: Bearer ${BEARER_TOKEN}" > /dev/null 2>&1
}

echo "=========================================="
echo "  JAMF Pro OS Version Collection Script"
echo "=========================================="
echo ""

command -v curl &>/dev/null || { echo "Error: curl required."; exit 1; }
command -v python3 &>/dev/null || { echo "Error: python3 required."; exit 1; }

prompt_credentials
[[ ! -d "$OUTPUT_DIR" ]] && mkdir -p "$OUTPUT_DIR"

get_bearer_token
collect_os_versions
generate_summary
generate_html_dashboard
invalidate_token

echo ""
echo "=========================================="
echo "  Collection Complete"
echo "=========================================="
echo ""
echo "CSV Report:      $OUTPUT_FILE"
echo "HTML Dashboard:  $HTML_FILE"
echo "Total records:   $(($(wc -l < "$OUTPUT_FILE") - 1))"
echo ""

[[ "$AUTO_OPEN_BROWSER" == "true" ]] && open "$HTML_FILE"
exit 0
