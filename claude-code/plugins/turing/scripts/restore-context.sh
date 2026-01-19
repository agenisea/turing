#!/bin/bash
# restore-context.sh - Restore session state on SessionStart
# Part of TURING - Autonomous State Machine for Cognitive Continuity
# Based on Alan Turing's 1936 paper "On Computable Numbers"
# Runs from project root (CWD is always project directory)
#
# VERSION: 1.1 - Priority-based selective restore with context.md threads
#
# Priority filtering based on source:
#   startup:        CRITICAL + HIGH only (fresh context, minimal tokens)
#   compact/resume: CRITICAL + HIGH + MEDIUM (continuity, moderate tokens)

set -e

# Check for Python 3
if ! command -v python3 &> /dev/null; then
    echo "# [TURING] Error: python3 not found"
    exit 0
fi

# Read hook input from stdin
INPUT=$(cat)

# Debug mode: uncomment to see raw input
# echo "$INPUT" > /tmp/turing-restore-debug.json

# Parse JSON with Python (more universal than jq)
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || echo "")
SOURCE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('source','startup'))" 2>/dev/null || echo "startup")

# Get current terminal for TTY-based session discovery
# tty command returns exit 1 when not on a terminal, so we add || true
TTY_OUTPUT=$(tty 2>&1 || true)
if [[ "$TTY_OUTPUT" == *"not a tty"* ]] || [[ "$TTY_OUTPUT" == *"not a terminal"* ]]; then
    CURRENT_TTY="pipe"
else
    CURRENT_TTY="${TTY_OUTPUT%%$'\n'*}"  # Strip any trailing newlines
fi

# =============================================================================
# PRIORITY-BASED SELECTIVE RESTORE
# =============================================================================
# Parse state file and filter by priority level
# Returns filtered content based on allowed priorities
#
# Priority levels (from capture-context.sh):
#   CRITICAL - Active focus, blockers (always included)
#   HIGH     - Key decisions, next steps (included for all restores)
#   MEDIUM   - Modified files, project context (included for compact/resume)
#   LOW      - Session history (only on explicit request)
#   ARCHIVE  - Compressed previous states (never auto-included)

filter_state_by_priority() {
    local STATE_FILE="$1"
    local MAX_PRIORITY="$2"  # CRITICAL, HIGH, MEDIUM, LOW, or ALL

    if [ ! -f "$STATE_FILE" ]; then
        return
    fi

    export TURING_STATE_FILE="$STATE_FILE"
    export TURING_MAX_PRIORITY="$MAX_PRIORITY"

    python3 << 'PYEOF'
import os
import re
import hashlib

state_file = os.environ.get("TURING_STATE_FILE", "")
max_priority = os.environ.get("TURING_MAX_PRIORITY", "HIGH")

if not state_file or not os.path.exists(state_file):
    print("")
    exit(0)

# Priority hierarchy
PRIORITY_ORDER = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "ARCHIVE", "ALL"]

def priority_allowed(section_priority, max_priority):
    """Check if section priority is within allowed range."""
    if max_priority == "ALL":
        return True
    try:
        max_idx = PRIORITY_ORDER.index(max_priority)
        section_idx = PRIORITY_ORDER.index(section_priority)
        return section_idx <= max_idx
    except ValueError:
        return True  # Unknown priority, include it

try:
    with open(state_file, 'r') as f:
        content = f.read()
except Exception as e:
    print(f"<!-- Error reading state: {e} -->")
    exit(0)

# Parse YAML frontmatter
frontmatter = {}
body = content
yaml_match = re.match(r'^---\s*\n(.*?)\n---\s*\n(.*)$', content, re.DOTALL)
if yaml_match:
    yaml_content = yaml_match.group(1)
    body = yaml_match.group(2)

    # Simple YAML parsing
    for line in yaml_content.split('\n'):
        if ':' in line:
            key, value = line.split(':', 1)
            frontmatter[key.strip()] = value.strip()

# Verify checksum if present
stored_checksum = frontmatter.get('checksum', '')
if stored_checksum:
    # Recalculate checksum on body content
    body_bytes = body.encode('utf-8')
    actual_checksum = hashlib.md5(body_bytes).hexdigest()

    # Note: checksum may not match exactly due to filtering, but we can warn
    # if the stored checksum doesn't match the original
    # For now, just note it in output

# Parse sections by priority
# Format: <!-- PRIORITY: LEVEL -->
sections = []
current_priority = "HIGH"  # Default priority
current_content = []

for line in body.split('\n'):
    priority_match = re.match(r'<!--\s*PRIORITY:\s*(\w+)\s*-->', line)
    if priority_match:
        # Save previous section
        if current_content:
            sections.append((current_priority, '\n'.join(current_content)))
        current_priority = priority_match.group(1)
        current_content = []
    else:
        current_content.append(line)

# Don't forget the last section
if current_content:
    sections.append((current_priority, '\n'.join(current_content)))

# Filter sections by priority
filtered_content = []
included_priorities = set()
excluded_priorities = set()

for priority, section_content in sections:
    if priority_allowed(priority, max_priority):
        filtered_content.append(section_content)
        included_priorities.add(priority)
    else:
        excluded_priorities.add(priority)

# Output filtered content
output = '\n'.join(filtered_content)

# Add metadata footer
version = frontmatter.get('version', 'unknown')
token_estimate = frontmatter.get('token_estimate', 'unknown')
compaction_count = frontmatter.get('compaction_count', '1')

print(output.strip())
print("")
print("---")
print("")
print("## Restore Metadata")
print("")
print(f"- **State Version**: {version}")
print(f"- **Token Estimate**: {token_estimate}")
print(f"- **Compaction Count**: {compaction_count}")
print(f"- **Priority Filter**: {max_priority}")
print(f"- **Included Priorities**: {', '.join(sorted(included_priorities)) if included_priorities else 'none'}")
if excluded_priorities:
    print(f"- **Excluded Priorities**: {', '.join(sorted(excluded_priorities))} (use `/turing-full` for complete state)")
PYEOF
}

# =============================================================================
# SESSION DISCOVERY AND RESTORE LOGIC
# =============================================================================

# Determine which state to load based on source
case "$SOURCE" in
    "startup")
        # New session - use smart session discovery
        # Priority: 1) Same TTY 2) Most recent within 24h 3) Most recent overall

        # Export TTY for Python to read from environment (safer than heredoc substitution)
        export TURING_CURRENT_TTY="$CURRENT_TTY"

        BEST_SESSION=$(python3 << 'PYEOF'
import json
import os
from datetime import datetime, timedelta

index_file = ".claude/sessions/index.json"
tty = os.environ.get("TURING_CURRENT_TTY", "unknown")
result = ""

# Try index-based discovery first
if os.path.exists(index_file):
    try:
        with open(index_file) as f:
            index = json.load(f)

        sessions = index.get("sessions", {})
        if sessions:
            # Priority 1: Same TTY, most recent
            tty_matches = [(sid, s) for sid, s in sessions.items() if s.get("tty") == tty]
            if tty_matches:
                best = max(tty_matches, key=lambda x: x[1].get("last_compacted_at", ""))
                result = best[0]

            # Priority 2: Most recent within 24 hours (only if no TTY match)
            if not result:
                now = datetime.utcnow()
                recent = []
                for sid, s in sessions.items():
                    try:
                        ts = datetime.fromisoformat(s.get("last_compacted_at", "").rstrip("Z"))
                        if (now - ts) < timedelta(hours=24):
                            recent.append((sid, s))
                    except:
                        pass

                if len(recent) == 1:
                    result = recent[0][0]

            # Priority 3: Most recent overall (only if nothing found yet)
            if not result and sessions:
                best = max(sessions.items(), key=lambda x: x[1].get("last_compacted_at", ""))
                result = best[0]
    except:
        pass

# Fallback to .latest marker (only if nothing found yet)
if not result:
    latest_file = ".claude/sessions/.latest"
    if os.path.exists(latest_file):
        try:
            with open(latest_file) as f:
                result = f.read().strip()
        except:
            pass

print(result)
PYEOF
)

        if [ -n "$BEST_SESSION" ]; then
            STATE_FILE=".claude/sessions/$BEST_SESSION/state.md"
            METADATA_FILE=".claude/sessions/$BEST_SESSION/metadata.json"

            # Get TTY from metadata if available
            PREVIOUS_TTY=""
            COMPACTION_COUNT=""
            TOKEN_HISTORY=""
            if [ -f "$METADATA_FILE" ]; then
                PREVIOUS_TTY=$(python3 -c "import json; print(json.load(open('$METADATA_FILE')).get('tty', 'unknown'))" 2>/dev/null || echo "unknown")
                COMPACTION_COUNT=$(python3 -c "import json; print(json.load(open('$METADATA_FILE')).get('compaction_count', 1))" 2>/dev/null || echo "1")
                TOKEN_HISTORY=$(python3 -c "import json; h=json.load(open('$METADATA_FILE')).get('token_history',[]); print(h[-1] if h else 'unknown')" 2>/dev/null || echo "unknown")
            fi

            if [ -f "$STATE_FILE" ]; then
                echo "# [TURING] Previous Session Detected"
                echo ""
                echo "**Current Session**: $SESSION_ID (new)"
                echo "**Previous Session**: $BEST_SESSION"
                echo "**Current TTY**: $CURRENT_TTY"
                if [ -n "$PREVIOUS_TTY" ]; then
                    if [ "$PREVIOUS_TTY" = "$CURRENT_TTY" ]; then
                        echo "**TTY Match**: Yes (same terminal)"
                    else
                        echo "**Previous TTY**: $PREVIOUS_TTY (different terminal)"
                    fi
                fi
                if [ -n "$COMPACTION_COUNT" ] && [ "$COMPACTION_COUNT" != "1" ]; then
                    echo "**Previous Compactions**: $COMPACTION_COUNT"
                fi
                echo "**M-configuration**: RESTORED (from previous)"
                echo "**Priority Filter**: HIGH (startup mode - minimal context)"
                echo ""
                echo "---"
                echo ""
                echo "## Previous Session State (CRITICAL + HIGH priorities)"
                echo ""

                # Use priority-based filtering for startup: CRITICAL + HIGH only
                filter_state_by_priority "$STATE_FILE" "HIGH"
                echo ""
            else
                echo "# [TURING] Fresh Start"
                echo ""
                echo "**Session ID**: $SESSION_ID"
                echo "**TTY**: $CURRENT_TTY"
                echo "**M-configuration**: INITIALIZED"
                echo ""
                echo "Previous session marker found but state file missing."
                echo "Starting fresh."
            fi
        else
            echo "# [TURING] Fresh Start"
            echo ""
            echo "**Session ID**: $SESSION_ID"
            echo "**TTY**: $CURRENT_TTY"
            echo "**M-configuration**: INITIALIZED"
            echo ""
            echo "No previous session state found. Fresh tape."
        fi
        ;;

    "resume"|"compact")
        # Same session - load current session state
        STATE_FILE=".claude/sessions/$SESSION_ID/state.md"

        if [ -f "$STATE_FILE" ]; then
            echo "# [TURING] State Restored"
            echo ""
            echo "**Session ID**: $SESSION_ID"
            echo "**Source**: $SOURCE"
            echo "**TTY**: $CURRENT_TTY"
            echo "**M-configuration**: RESTORED"
            echo "**Priority Filter**: MEDIUM (continuity mode - extended context)"
            echo ""
            echo "---"
            echo ""

            # Use priority-based filtering for compact/resume: CRITICAL + HIGH + MEDIUM
            filter_state_by_priority "$STATE_FILE" "MEDIUM"
            echo ""
        else
            # Fallback: try smart discovery
            FALLBACK_SESSION=$(python3 << 'PYEOF'
import json
import os

result = ""

# Try index first
index_file = ".claude/sessions/index.json"
if os.path.exists(index_file):
    try:
        with open(index_file) as f:
            index = json.load(f)
        sessions = index.get("sessions", {})
        if sessions:
            best = max(sessions.items(), key=lambda x: x[1].get("last_compacted_at", ""))
            result = best[0]
    except:
        pass

# Fallback to .latest (only if nothing found yet)
if not result:
    latest_file = ".claude/sessions/.latest"
    if os.path.exists(latest_file):
        try:
            with open(latest_file) as f:
                result = f.read().strip()
        except:
            pass

print(result)
PYEOF
)

            if [ -n "$FALLBACK_SESSION" ]; then
                FALLBACK_STATE=".claude/sessions/$FALLBACK_SESSION/state.md"

                if [ -f "$FALLBACK_STATE" ]; then
                    echo "# [TURING] State Restored (Fallback)"
                    echo ""
                    echo "**Current Session**: $SESSION_ID"
                    echo "**Restored From**: $FALLBACK_SESSION"
                    echo "**Source**: $SOURCE"
                    echo "**TTY**: $CURRENT_TTY"
                    echo "**M-configuration**: RESTORED"
                    echo "**Priority Filter**: MEDIUM (fallback continuity mode)"
                    echo ""
                    echo "---"
                    echo ""

                    # Use priority-based filtering
                    filter_state_by_priority "$FALLBACK_STATE" "MEDIUM"
                    echo ""
                else
                    echo "# [TURING] No State Found"
                    echo ""
                    echo "**Session ID**: $SESSION_ID"
                    echo "**Source**: $SOURCE"
                    echo "**TTY**: $CURRENT_TTY"
                    echo "**M-configuration**: INITIALIZED"
                    echo ""
                    echo "No state file found for this session."
                fi
            else
                echo "# [TURING] No State Found"
                echo ""
                echo "**Session ID**: $SESSION_ID"
                echo "**Source**: $SOURCE"
                echo "**TTY**: $CURRENT_TTY"
                echo "**M-configuration**: INITIALIZED"
                echo ""
                echo "No state file found for this session."
            fi
        fi
        ;;

    *)
        echo "# [TURING] Unknown Source"
        echo ""
        echo "**Session ID**: $SESSION_ID"
        echo "**Source**: $SOURCE (unexpected)"
        echo "**TTY**: $CURRENT_TTY"
        echo ""
        ;;
esac

# =============================================================================
# ADR HISTORY DISPLAY
# =============================================================================

# Show ADR history based on trigger type
show_adrs() {
    local ADR_FILE="$1"
    local LABEL="$2"

    if [ -f "$ADR_FILE" ]; then
        echo "---"
        echo ""
        echo "## Architecture Decision Records ($LABEL)"
        echo ""
        ADR_COUNT=$(grep -cE '^ADR-[0-9]+:' "$ADR_FILE" 2>/dev/null || echo "0")
        echo "- **Location**: $ADR_FILE"
        echo "- **Total Entries**: $ADR_COUNT"
        echo ""

        # Extract and display TL;DRs for each ADR
        if [ "$ADR_COUNT" -gt 0 ]; then
            echo "### TL;DR Summary"
            echo ""
            # Extract ADR titles and their TL;DRs
            grep -E '^ADR-[0-9]+:|^TL;DR:' "$ADR_FILE" 2>/dev/null | while read -r line; do
                if [[ "$line" =~ ^ADR-[0-9]+ ]]; then
                    # Print ADR title
                    echo -n "- **$line**"
                elif [[ "$line" =~ ^TL\;DR: ]]; then
                    # Print TL;DR on same line
                    TLDR="${line#TL;DR: }"
                    echo " — $TLDR"
                fi
            done
            echo ""
        fi

        echo "Use \`cat $ADR_FILE\` to review full ADR history."
    fi
}

# Determine which ADR file to show based on trigger
case "$SOURCE" in
    "startup")
        # Show previous session's ADRs if we found one
        if [ -n "$BEST_SESSION" ]; then
            show_adrs ".claude/sessions/$BEST_SESSION/adrs.md" "Previous Session"
        fi
        ;;
    "resume"|"compact")
        # Show current session's ADRs
        show_adrs ".claude/sessions/$SESSION_ID/adrs.md" "Current Session"
        ;;
esac

# =============================================================================
# OPEN THREADS
# =============================================================================

CONTEXT_FILE=".claude/sessions/context.md"
if [ -f "$CONTEXT_FILE" ]; then
    THREADS=$(python3 << 'PYEOF'
import re
import os

context_file = ".claude/sessions/context.md"
if not os.path.exists(context_file):
    exit(0)

try:
    with open(context_file, 'r') as f:
        content = f.read()

    # Parse threads section - only open (unchecked) threads
    threads_match = re.search(r'## Threads\n(.*?)(?=\n## |\Z)', content, re.DOTALL)
    if threads_match:
        for line in threads_match.group(1).strip().split('\n'):
            line = line.strip()
            if line.startswith('- [ ]'):
                print(line)
except:
    pass
PYEOF
)

    if [ -n "$THREADS" ]; then
        echo ""
        echo "---"
        echo ""
        echo "## Open Threads"
        echo ""
        echo "$THREADS"
        echo ""
        echo "_Mark completed with \`- [x]\` in \`.claude/sessions/context.md\`_"
    fi
fi

# =============================================================================
# GIT CONTEXT
# =============================================================================

# Git context for orientation
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo ""
    echo "---"
    echo ""
    echo "## Current Git State"
    echo ""
    echo "- **Branch**: $(git branch --show-current 2>/dev/null || echo 'detached')"
    echo "- **Last Commit**: $(git log -1 --format='%h %s' 2>/dev/null || echo 'none')"
    UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    echo "- **Uncommitted Changes**: $UNCOMMITTED files"
fi

exit 0
