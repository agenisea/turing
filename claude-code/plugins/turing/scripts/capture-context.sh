#!/bin/bash
# capture-context.sh - Capture and persist session state before compaction
# Part of TURING - Autonomous State Machine for Cognitive Continuity
# Based on Alan Turing's 1936 paper "On Computable Numbers"
# Version: 1.1 - With validation, token tracking, auto-decisions, priorities, and context.md

set -e

# Check for Python 3
if ! command -v python3 &> /dev/null; then
    echo "# [TURING] Error: python3 not found"
    exit 0
fi

# Read hook input from stdin
INPUT=$(cat)

# Parse JSON with Python
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || echo "")
TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('transcript_path',''))" 2>/dev/null || echo "")
TRIGGER=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('trigger','unknown'))" 2>/dev/null || echo "unknown")

# Fallback if no session_id
if [ -z "$SESSION_ID" ]; then
    SESSION_ID="unknown-$(date +%s)"
fi

# Get terminal identification
TTY_OUTPUT=$(tty 2>&1 || true)
if [[ "$TTY_OUTPUT" == *"not a tty"* ]] || [[ "$TTY_OUTPUT" == *"not a terminal"* ]]; then
    TTY="pipe"
else
    TTY="${TTY_OUTPUT%%$'\n'*}"
fi

# Create session directory
SESSION_DIR=".claude/sessions/$SESSION_ID"
if ! mkdir -p "$SESSION_DIR" 2>/dev/null; then
    echo "# [TURING] Error: Cannot create directory $SESSION_DIR"
    exit 0
fi

# Update .latest marker (backwards compatibility)
echo "$SESSION_ID" > .claude/sessions/.latest 2>/dev/null || true

# Export for Python
export TURING_SESSION_DIR="$SESSION_DIR"
export TURING_SESSION_ID="$SESSION_ID"
export TURING_TTY="$TTY"
export TURING_TRANSCRIPT_PATH="$TRANSCRIPT_PATH"

# =============================================================================
# IMPROVEMENT 1: Track compaction count for state decay
# =============================================================================
COMPACTION_COUNT=1
METADATA_FILE="$SESSION_DIR/metadata.json"
if [ -f "$METADATA_FILE" ]; then
    COMPACTION_COUNT=$(python3 -c "import json; print(json.load(open('$METADATA_FILE')).get('compaction_count', 0) + 1)" 2>/dev/null || echo "1")
fi

# =============================================================================
# IMPROVEMENT 2: Auto-extract decisions from transcript
# =============================================================================
AUTO_DECISIONS=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    AUTO_DECISIONS=$(python3 << 'PYEOF'
import re
import os

transcript_path = os.environ.get("TURING_TRANSCRIPT_PATH", "")
if not transcript_path or not os.path.exists(transcript_path):
    exit(0)

try:
    with open(transcript_path, 'r', errors='ignore') as f:
        # Read last 500 lines for decision extraction
        lines = f.readlines()[-500:]

    content = ''.join(lines)

    # Patterns indicating decisions
    patterns = [
        r"(?i)decided to ([^.!?\n]{10,100})",
        r"(?i)going with ([^.!?\n]{10,80})",
        r"(?i)will use ([^.!?\n]{10,80}) because",
        r"(?i)chose ([^.!?\n]{10,80}) over",
        r"(?i)the approach is ([^.!?\n]{10,100})",
        r"(?i)implemented ([^.!?\n]{10,80})",
        r"(?i)created ([^.!?\n]{10,80}) for",
        r"(?i)added ([^.!?\n]{10,80}) to handle",
    ]

    decisions = []
    seen = set()

    for pattern in patterns:
        matches = re.findall(pattern, content)
        for match in matches:
            clean = match.strip()[:100]
            if clean and clean.lower() not in seen and len(clean) > 15:
                seen.add(clean.lower())
                decisions.append(clean)

    # Output unique decisions (max 8)
    for d in decisions[:8]:
        print(f"- {d}")
except:
    pass
PYEOF
)
fi

# =============================================================================
# IMPROVEMENT 3: Summarize previous state if exists (state decay)
# =============================================================================
PREVIOUS_SUMMARY=""
PREV_STATE_FILE="$SESSION_DIR/state.md"
if [ -f "$PREV_STATE_FILE" ] && [ "$COMPACTION_COUNT" -gt 1 ]; then
    # Archive previous state
    ARCHIVE_DIR="$SESSION_DIR/archive"
    mkdir -p "$ARCHIVE_DIR" 2>/dev/null || true
    cp "$PREV_STATE_FILE" "$ARCHIVE_DIR/state-$(date +%s).md" 2>/dev/null || true

    # Extract key info from previous state for summary
    PREVIOUS_SUMMARY=$(python3 << 'PYEOF'
import os
import re

session_dir = os.environ.get("TURING_SESSION_DIR", "")
state_file = os.path.join(session_dir, "state.md")

if not os.path.exists(state_file):
    exit(0)

try:
    with open(state_file) as f:
        content = f.read()

    # Extract Active Focus if present
    focus_match = re.search(r'## Active Focus[^\n]*\n([^\n#]+)', content)
    focus = focus_match.group(1).strip() if focus_match else ""

    # Extract key decisions
    decisions = re.findall(r'^- D\d+: (.+)$', content, re.MULTILINE)

    # Build summary
    summary_parts = []
    if focus:
        summary_parts.append(f"Previous focus: {focus[:100]}")
    if decisions:
        summary_parts.append(f"Previous decisions: {'; '.join(decisions[:3])}")

    if summary_parts:
        print('\n'.join(summary_parts))
except:
    pass
PYEOF
)
fi

# =============================================================================
# BUILD STATE FILE WITH PRIORITY LEVELS
# =============================================================================
STATE_FILE="$SESSION_DIR/state.md"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CAPTURED_DISPLAY=$(date '+%Y-%m-%d %H:%M:%S')

# Pre-calculate token estimate for frontmatter
PRE_TOKEN_ESTIMATE=0

{
    # YAML frontmatter for machine parsing (checksum added post-write)
    echo "---"
    echo "version: 1.1"
    echo "session_id: $SESSION_ID"
    echo "tty: $TTY"
    echo "captured_at: $TIMESTAMP"
    echo "compaction_count: $COMPACTION_COUNT"
    echo "trigger: $TRIGGER"
    echo "project: $(basename "$(pwd)")"
    echo "checksum: PENDING"
    echo "token_estimate: PENDING"
    echo "---"
    echo ""

    # ==========================================================================
    # PRIORITY: CRITICAL - Always include in restore
    # ==========================================================================
    echo "<!-- PRIORITY: CRITICAL -->"
    echo "## Active Focus"
    echo ""
    if [ -n "$PREVIOUS_SUMMARY" ]; then
        echo "$PREVIOUS_SUMMARY"
        echo ""
    fi
    echo "_Focus will be set by Claude during compaction. Use /turing-save to manually set._"
    echo ""

    # ==========================================================================
    # PRIORITY: HIGH - Key decisions (always include)
    # ==========================================================================
    echo "<!-- PRIORITY: HIGH -->"
    echo "## Key Decisions (This Session)"
    echo ""

    # Show auto-extracted decisions
    if [ -n "$AUTO_DECISIONS" ]; then
        echo "### Auto-Extracted"
        echo "$AUTO_DECISIONS"
        echo ""
    fi

    # Show existing ADRs summary
    ADR_FILE="$SESSION_DIR/adrs.md"
    if [ -f "$ADR_FILE" ]; then
        ADR_COUNT=$(grep -cE '^ADR-[0-9]+:' "$ADR_FILE" 2>/dev/null || echo "0")
        if [ "$ADR_COUNT" -gt 0 ]; then
            echo "### Recorded ADRs ($ADR_COUNT)"
            grep -E '^ADR-[0-9]+:|^TL;DR:' "$ADR_FILE" 2>/dev/null | head -20 || true
        fi
    else
        echo "_No formal ADRs recorded. Use /turing-save for important decisions._"
    fi
    echo ""

    # ==========================================================================
    # PRIORITY: MEDIUM - Files and git state (include on compact, skip on startup)
    # ==========================================================================
    echo "<!-- PRIORITY: MEDIUM -->"
    echo "## Modified Files"
    echo ""

    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        echo "- **Branch**: $(git branch --show-current 2>/dev/null || echo 'detached')"
        echo "- **Uncommitted**: $UNCOMMITTED files"
        echo ""

        if [ "$UNCOMMITTED" -gt 0 ]; then
            echo '```'
            git status --porcelain 2>/dev/null | head -20 || true
            if [ "$UNCOMMITTED" -gt 20 ]; then
                echo "... and $((UNCOMMITTED - 20)) more files"
            fi
            echo '```'
            echo ""
        fi

        # Recent commits (last 2 hours)
        RECENT=$(git log --oneline --since="2 hours ago" 2>/dev/null | head -5)
        if [ -n "$RECENT" ]; then
            echo "### Recent Commits"
            echo '```'
            echo "$RECENT"
            echo '```'
            echo ""
        fi
    fi

    # ==========================================================================
    # PRIORITY: LOW - Project context (skip on compact, include on startup)
    # ==========================================================================
    echo "<!-- PRIORITY: LOW -->"
    echo "## Project Context"
    echo ""
    echo "- **Directory**: $(pwd)"
    echo "- **Name**: $(basename "$(pwd)")"
    if [ -f "package.json" ]; then
        PKG_NAME=$(grep -m1 '"name"' package.json 2>/dev/null | cut -d'"' -f4 || echo "")
        [ -n "$PKG_NAME" ] && echo "- **Package**: $PKG_NAME"
    fi
    [ -f "CLAUDE.md" ] && echo "- **CLAUDE.md**: Present"
    [ -f "README.md" ] && echo "- **README.md**: Present"
    echo ""

    # ==========================================================================
    # PRIORITY: ARCHIVE - Historical context (only on explicit request)
    # ==========================================================================
    echo "<!-- PRIORITY: ARCHIVE -->"
    echo "## Session History"
    echo ""
    echo "- **Compaction Count**: $COMPACTION_COUNT"
    echo "- **Session Started**: $(python3 -c "import json; print(json.load(open('$METADATA_FILE')).get('created_at', 'unknown'))" 2>/dev/null || echo 'unknown')"

    # Count archived states
    ARCHIVE_COUNT=$(ls -1 "$SESSION_DIR/archive/" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$ARCHIVE_COUNT" -gt 0 ]; then
        echo "- **Archived States**: $ARCHIVE_COUNT"
    fi
    echo ""

    echo "---"
    echo "**M-configuration**: COMPACTING → HALTED"

} > "$STATE_FILE"

# =============================================================================
# IMPROVEMENT 4: Validation & Checksums
# =============================================================================
VALIDATION_STATUS="success"
STATE_BYTES=0
STATE_LINES=0
STATE_CHECKSUM=""

if [ -f "$STATE_FILE" ]; then
    STATE_BYTES=$(wc -c < "$STATE_FILE" | tr -d ' ')
    STATE_LINES=$(wc -l < "$STATE_FILE" | tr -d ' ')

    # Generate checksum
    if command -v md5 &>/dev/null; then
        STATE_CHECKSUM=$(md5 -q "$STATE_FILE")
    elif command -v md5sum &>/dev/null; then
        STATE_CHECKSUM=$(md5sum "$STATE_FILE" | cut -d' ' -f1)
    else
        STATE_CHECKSUM="unavailable"
    fi

    # Validate
    if [ "$STATE_BYTES" -lt 100 ]; then
        VALIDATION_STATUS="warning:small"
    fi
else
    VALIDATION_STATUS="error:missing"
fi

# Store checksum
echo "$STATE_CHECKSUM" > "$SESSION_DIR/.state-checksum" 2>/dev/null || true

# Update frontmatter with actual checksum and token estimate
if [ -f "$STATE_FILE" ]; then
    # Use sed to replace PENDING placeholders (macOS compatible)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/checksum: PENDING/checksum: $STATE_CHECKSUM/" "$STATE_FILE"
    else
        sed -i "s/checksum: PENDING/checksum: $STATE_CHECKSUM/" "$STATE_FILE"
    fi
fi

# =============================================================================
# IMPROVEMENT 5: Token Budget Tracking
# =============================================================================
# Estimate tokens (rough: 1 token ≈ 4 chars for English)
TOKEN_ESTIMATE=$((STATE_BYTES / 4))

TEMPLATE_TOKENS=0
if [ -f "${CLAUDE_PLUGIN_ROOT}/templates/turing-precompact.md" ]; then
    TEMPLATE_BYTES=$(wc -c < "${CLAUDE_PLUGIN_ROOT}/templates/turing-precompact.md" | tr -d ' ')
    TEMPLATE_TOKENS=$((TEMPLATE_BYTES / 4))
fi

TOTAL_TOKENS=$((TOKEN_ESTIMATE + TEMPLATE_TOKENS))

# Token budget warning threshold
TOKEN_WARNING_THRESHOLD=2500
TOKEN_STATUS="ok"
if [ "$TOTAL_TOKENS" -gt "$TOKEN_WARNING_THRESHOLD" ]; then
    TOKEN_STATUS="warning:large"
fi

# Update token_estimate in frontmatter
if [ -f "$STATE_FILE" ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/token_estimate: PENDING/token_estimate: $TOKEN_ESTIMATE/" "$STATE_FILE"
    else
        sed -i "s/token_estimate: PENDING/token_estimate: $TOKEN_ESTIMATE/" "$STATE_FILE"
    fi
fi

# =============================================================================
# Update metadata with all tracking info
# =============================================================================
python3 << 'PYEOF'
import json
import os
from datetime import datetime

session_dir = os.environ.get("TURING_SESSION_DIR", "")
session_id = os.environ.get("TURING_SESSION_ID", "")
tty = os.environ.get("TURING_TTY", "unknown")
cwd = os.getcwd()
now = datetime.utcnow().isoformat() + "Z"

metadata_file = os.path.join(session_dir, "metadata.json")

# Load existing or create new
if os.path.exists(metadata_file):
    try:
        with open(metadata_file) as f:
            metadata = json.load(f)
    except:
        metadata = {}
else:
    metadata = {}

# Update fields
metadata.update({
    "session_id": session_id,
    "last_compacted_at": now,
    "tty": tty,
    "project_dir": cwd,
    "project_name": os.path.basename(cwd),
})

# Preserve created_at
if "created_at" not in metadata:
    metadata["created_at"] = now

# Compaction tracking
metadata["compaction_count"] = metadata.get("compaction_count", 0) + 1

# Validation info
metadata["validation"] = {
    "status": os.environ.get("VALIDATION_STATUS", "unknown"),
    "state_bytes": int(os.environ.get("STATE_BYTES", 0)),
    "state_lines": int(os.environ.get("STATE_LINES", 0)),
    "checksum": os.environ.get("STATE_CHECKSUM", ""),
}

# Token tracking
token_estimate = int(os.environ.get("TOKEN_ESTIMATE", 0))
metadata["tokens"] = {
    "state": token_estimate,
    "template": int(os.environ.get("TEMPLATE_TOKENS", 0)),
    "total": int(os.environ.get("TOTAL_TOKENS", 0)),
    "status": os.environ.get("TOKEN_STATUS", "unknown"),
}

# Token history (keep last 10)
if "token_history" not in metadata:
    metadata["token_history"] = []
metadata["token_history"].append({
    "timestamp": now,
    "tokens": token_estimate,
    "compaction": metadata["compaction_count"]
})
metadata["token_history"] = metadata["token_history"][-10:]

# Auto-decisions count
auto_decisions = os.environ.get("AUTO_DECISIONS", "")
metadata["auto_decisions_extracted"] = len([l for l in auto_decisions.split('\n') if l.strip().startswith('-')])

with open(metadata_file, "w") as f:
    json.dump(metadata, f, indent=2)

# Update session index
sessions_dir = os.path.dirname(session_dir)
index_file = os.path.join(sessions_dir, "index.json")
try:
    if os.path.exists(index_file):
        with open(index_file) as f:
            index = json.load(f)
    else:
        index = {"sessions": {}}
except:
    index = {"sessions": {}}

index["sessions"][session_id] = {
    "last_compacted_at": now,
    "tty": tty,
    "compaction_count": metadata["compaction_count"],
    "tokens": token_estimate,
}
index["last_updated"] = now

with open(index_file, "w") as f:
    json.dump(index, f, indent=2)
PYEOF

# Export for the Python script
export VALIDATION_STATUS="$VALIDATION_STATUS"
export STATE_BYTES="$STATE_BYTES"
export STATE_LINES="$STATE_LINES"
export STATE_CHECKSUM="$STATE_CHECKSUM"
export TOKEN_ESTIMATE="$TOKEN_ESTIMATE"
export TEMPLATE_TOKENS="$TEMPLATE_TOKENS"
export TOTAL_TOKENS="$TOTAL_TOKENS"
export TOKEN_STATUS="$TOKEN_STATUS"
export AUTO_DECISIONS="$AUTO_DECISIONS"

# Re-run metadata update with exports
python3 << 'PYEOF'
import json
import os
from datetime import datetime

session_dir = os.environ.get("TURING_SESSION_DIR", "")
metadata_file = os.path.join(session_dir, "metadata.json")

if os.path.exists(metadata_file):
    with open(metadata_file) as f:
        metadata = json.load(f)

    metadata["validation"] = {
        "status": os.environ.get("VALIDATION_STATUS", "unknown"),
        "state_bytes": int(os.environ.get("STATE_BYTES", "0")),
        "state_lines": int(os.environ.get("STATE_LINES", "0")),
        "checksum": os.environ.get("STATE_CHECKSUM", ""),
    }

    metadata["tokens"] = {
        "state": int(os.environ.get("TOKEN_ESTIMATE", "0")),
        "template": int(os.environ.get("TEMPLATE_TOKENS", "0")),
        "total": int(os.environ.get("TOTAL_TOKENS", "0")),
        "status": os.environ.get("TOKEN_STATUS", "unknown"),
    }

    auto_decisions = os.environ.get("AUTO_DECISIONS", "")
    metadata["auto_decisions_extracted"] = len([l for l in auto_decisions.split('\n') if l.strip().startswith('-')])

    with open(metadata_file, "w") as f:
        json.dump(metadata, f, indent=2)
PYEOF

# =============================================================================
# CONTEXT.MD: Threads + Journal
# =============================================================================
CONTEXT_FILE=".claude/sessions/context.md"
export TURING_CONTEXT_FILE="$CONTEXT_FILE"
export TURING_UNCOMMITTED="$UNCOMMITTED"

python3 << 'PYEOF'
import os
import re
from datetime import datetime

context_file = os.environ.get("TURING_CONTEXT_FILE", "")
session_id = os.environ.get("TURING_SESSION_ID", "")
uncommitted = os.environ.get("TURING_UNCOMMITTED", "0")

if not context_file:
    exit(0)

now = datetime.now().strftime("%Y-%m-%d %H:%M")
date_only = datetime.now().strftime("%Y-%m-%d")

# Ensure directory exists
os.makedirs(os.path.dirname(context_file), exist_ok=True)

# Load existing or create new
threads = []
journal_rows = []

if os.path.exists(context_file):
    try:
        with open(context_file, 'r') as f:
            content = f.read()

        # Parse threads section
        threads_match = re.search(r'## Threads\n(.*?)(?=\n## |\Z)', content, re.DOTALL)
        if threads_match:
            for line in threads_match.group(1).strip().split('\n'):
                line = line.strip()
                if line.startswith('- ['):
                    threads.append(line)

        # Parse journal section (preserve existing rows)
        journal_match = re.search(r'\| Date \| Session \| Files \| Summary \|\n\|[-|]+\|\n(.*?)(?=\n\n|\Z)', content, re.DOTALL)
        if journal_match:
            for line in journal_match.group(1).strip().split('\n'):
                if line.startswith('|') and not line.startswith('|---'):
                    journal_rows.append(line)
    except:
        pass

# Keep only open threads (unchecked), max 5, newest first
open_threads = [t for t in threads if '- [ ]' in t][-5:]

# Add new journal entry (prepend - newest first)
try:
    files_count = int(uncommitted) if uncommitted else 0
except:
    files_count = 0

# Generate summary from session context
summary = "Session compacted"
session_dir = os.environ.get("TURING_SESSION_DIR", "")
if session_dir:
    state_file = os.path.join(session_dir, "state.md")
    if os.path.exists(state_file):
        try:
            with open(state_file, 'r') as f:
                state_content = f.read()
            # Try to extract focus for summary
            focus_match = re.search(r'## Active Focus\n\n([^\n_#]+)', state_content)
            if focus_match:
                summary = focus_match.group(1).strip()[:50]
        except:
            pass

new_journal_row = f"| {now} | {session_id[:8]} | {files_count} | {summary} |"
journal_rows = [new_journal_row] + journal_rows

# Write context.md
with open(context_file, 'w') as f:
    f.write("# TURING Context\n\n")

    f.write("## Threads\n\n")
    if open_threads:
        for t in open_threads:
            f.write(f"{t}\n")
    else:
        f.write("_No open threads._\n")
    f.write("\n")

    f.write("## Journal\n\n")
    f.write("| Date | Session | Files | Summary |\n")
    f.write("|------|---------|-------|---------|\n")
    for row in journal_rows[:50]:  # Keep last 50 entries
        f.write(f"{row}\n")
PYEOF

# =============================================================================
# OUTPUT
# =============================================================================
echo "# [TURING] State Preserved (v1.1)"
echo ""
echo "**Session**: $SESSION_ID"
echo "**TTY**: $TTY"
echo "**Compaction**: #$COMPACTION_COUNT"
echo ""

# Validation status
if [ "$VALIDATION_STATUS" = "success" ]; then
    echo "**Validation**: OK ($STATE_LINES lines, $STATE_BYTES bytes)"
else
    echo "**Validation**: $VALIDATION_STATUS"
fi

# Token budget
if [ "$TOKEN_STATUS" = "ok" ]; then
    echo "**Tokens**: ~$TOTAL_TOKENS (state: $TOKEN_ESTIMATE, template: $TEMPLATE_TOKENS)"
else
    echo "**Tokens**: ~$TOTAL_TOKENS - WARNING: Large context"
    echo "  Consider running /turing-save to archive decisions and trim state"
fi

# Auto-decisions
if [ -n "$AUTO_DECISIONS" ]; then
    DECISION_COUNT=$(echo "$AUTO_DECISIONS" | grep -c "^-" || echo "0")
    echo "**Auto-Decisions**: $DECISION_COUNT extracted from transcript"
fi

echo ""
echo "---"
echo ""

# Output the state with priority markers visible
cat "$STATE_FILE"

echo ""
echo "---"
echo ""

# Output protocol template
if [ -f "${CLAUDE_PLUGIN_ROOT}/templates/turing-precompact.md" ]; then
    cat "${CLAUDE_PLUGIN_ROOT}/templates/turing-precompact.md"
fi

exit 0
