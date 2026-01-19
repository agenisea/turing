#!/bin/bash
# turing-status.sh - Display TURING memory status
# Part of TURING - Autonomous State Machine for Cognitive Continuity
#
# Usage:
#   turing-status.sh              # Project-level status
#   turing-status.sh --global     # Workstation-level status
#   turing-status.sh --json       # JSON output for programmatic use

set -e

GLOBAL_MODE=false
JSON_MODE=false

for arg in "$@"; do
    case $arg in
        --global|-g) GLOBAL_MODE=true ;;
        --json|-j) JSON_MODE=true ;;
    esac
done

# =============================================================================
# PROJECT-LEVEL STATUS
# =============================================================================

show_project_status() {
    local PROJECT_DIR="$1"
    local SESSIONS_DIR="$PROJECT_DIR/.claude/sessions"

    if [ ! -d "$SESSIONS_DIR" ]; then
        echo "No TURING sessions found in: $PROJECT_DIR"
        return
    fi

    local PROJECT_NAME=$(basename "$PROJECT_DIR")

    echo "# TURING Memory Status"
    echo ""
    echo "## Project: $PROJECT_NAME"
    echo "**Path**: $PROJECT_DIR"
    echo ""

    # Read index.json
    local INDEX_FILE="$SESSIONS_DIR/index.json"
    if [ -f "$INDEX_FILE" ]; then
        python3 << PYEOF
import json
import os
from datetime import datetime, timedelta

index_file = "$INDEX_FILE"
sessions_dir = "$SESSIONS_DIR"

with open(index_file) as f:
    index = json.load(f)

sessions = index.get("sessions", {})
total_tokens = 0
total_bytes = 0
session_count = len(sessions)

print(f"### Sessions Overview")
print(f"")
print(f"| Session ID | TTY | Last Compacted | Compactions | Tokens |")
print(f"|------------|-----|----------------|-------------|--------|")

now = datetime.utcnow()

for sid, info in sorted(sessions.items(), key=lambda x: x[1].get("last_compacted_at", ""), reverse=True):
    tty = info.get("tty", "unknown")
    if len(tty) > 15:
        tty = "..." + tty[-12:]

    last_compacted = info.get("last_compacted_at", "unknown")
    compaction_count = info.get("compaction_count", 1)
    tokens = info.get("tokens", 0)
    total_tokens += tokens

    # Calculate age
    age_str = "unknown"
    if last_compacted != "unknown":
        try:
            ts = datetime.fromisoformat(last_compacted.rstrip("Z"))
            delta = now - ts
            if delta < timedelta(hours=1):
                age_str = f"{int(delta.total_seconds() / 60)}m ago"
            elif delta < timedelta(days=1):
                age_str = f"{int(delta.total_seconds() / 3600)}h ago"
            else:
                age_str = f"{delta.days}d ago"
        except:
            age_str = last_compacted[:10]

    # Get state file size
    state_file = os.path.join(sessions_dir, sid, "state.md")
    if os.path.exists(state_file):
        total_bytes += os.path.getsize(state_file)

    print(f"| \`{sid[:12]}...\` | {tty} | {age_str} | {compaction_count} | ~{tokens} |")

print(f"")
print(f"### Summary")
print(f"")
print(f"- **Total Sessions**: {session_count}")
print(f"- **Total Tokens**: ~{total_tokens}")
print(f"- **Total Size**: {total_bytes / 1024:.1f} KB")
print(f"- **Last Updated**: {index.get('last_updated', 'unknown')[:19]}")
PYEOF
    else
        echo "No index.json found. Scanning session directories..."
        echo ""

        # Fallback: scan directories
        for SESSION_DIR in "$SESSIONS_DIR"/*/; do
            if [ -d "$SESSION_DIR" ]; then
                SESSION_ID=$(basename "$SESSION_DIR")
                STATE_FILE="$SESSION_DIR/state.md"
                METADATA_FILE="$SESSION_DIR/metadata.json"

                if [ -f "$STATE_FILE" ]; then
                    SIZE=$(wc -c < "$STATE_FILE" | tr -d ' ')
                    TOKENS=$((SIZE / 4))
                    echo "- **$SESSION_ID**: ~$TOKENS tokens ($SIZE bytes)"
                fi
            fi
        done
    fi

    echo ""

    # Show current/latest session details
    LATEST_FILE="$SESSIONS_DIR/.latest"
    if [ -f "$LATEST_FILE" ]; then
        LATEST_SESSION=$(cat "$LATEST_FILE")
        LATEST_STATE="$SESSIONS_DIR/$LATEST_SESSION/state.md"
        LATEST_METADATA="$SESSIONS_DIR/$LATEST_SESSION/metadata.json"

        echo "---"
        echo ""
        echo "## Latest Session: $LATEST_SESSION"
        echo ""

        if [ -f "$LATEST_METADATA" ]; then
            python3 << PYEOF
import json

metadata_file = "$LATEST_METADATA"

with open(metadata_file) as f:
    m = json.load(f)

print(f"- **Created**: {m.get('created_at', 'unknown')[:19]}")
print(f"- **Last Compacted**: {m.get('last_compacted_at', 'unknown')[:19]}")
print(f"- **TTY**: {m.get('tty', 'unknown')}")
print(f"- **Compaction Count**: {m.get('compaction_count', 1)}")

tokens = m.get('tokens', {})
if tokens:
    print(f"- **Token Usage**: state={tokens.get('state', 0)}, template={tokens.get('template', 0)}, total={tokens.get('total', 0)}")
    print(f"- **Token Status**: {tokens.get('status', 'unknown')}")

validation = m.get('validation', {})
if validation:
    print(f"- **Validation**: {validation.get('status', 'unknown')} ({validation.get('state_lines', 0)} lines, {validation.get('state_bytes', 0)} bytes)")

auto_decisions = m.get('auto_decisions_extracted', 0)
if auto_decisions:
    print(f"- **Auto Decisions Extracted**: {auto_decisions}")

# Token history
token_history = m.get('token_history', [])
if len(token_history) > 1:
    print(f"")
    print(f"### Token History (Last {len(token_history)} Compactions)")
    print(f"")
    for h in token_history:
        print(f"- Compaction #{h.get('compaction', '?')}: ~{h.get('tokens', 0)} tokens")
PYEOF
        fi

        # Show archived states
        ARCHIVE_DIR="$SESSIONS_DIR/$LATEST_SESSION/archive"
        if [ -d "$ARCHIVE_DIR" ]; then
            ARCHIVE_COUNT=$(ls -1 "$ARCHIVE_DIR" 2>/dev/null | wc -l | tr -d ' ')
            if [ "$ARCHIVE_COUNT" -gt 0 ]; then
                echo ""
                echo "### Archived States: $ARCHIVE_COUNT"
                ls -lt "$ARCHIVE_DIR" 2>/dev/null | head -5 | while read -r line; do
                    echo "- $line"
                done
            fi
        fi

        # Show ADR summary
        ADR_FILE="$SESSIONS_DIR/$LATEST_SESSION/adrs.md"
        if [ -f "$ADR_FILE" ]; then
            ADR_COUNT=$(grep -cE '^ADR-[0-9]+:' "$ADR_FILE" 2>/dev/null || echo "0")
            if [ "$ADR_COUNT" -gt 0 ]; then
                echo ""
                echo "### Architecture Decision Records: $ADR_COUNT"
                echo ""
                grep -E '^ADR-[0-9]+:|^TL;DR:' "$ADR_FILE" 2>/dev/null | head -10 | while read -r line; do
                    if [[ "$line" =~ ^ADR-[0-9]+ ]]; then
                        echo "- **$line**"
                    elif [[ "$line" =~ ^TL\;DR: ]]; then
                        TLDR="${line#TL;DR: }"
                        echo "  $TLDR"
                    fi
                done
            fi
        fi

        # Show context.md (threads + journal)
        CONTEXT_FILE="$SESSIONS_DIR/context.md"
        if [ -f "$CONTEXT_FILE" ]; then
            echo ""
            echo "### Open Threads"
            echo ""
            THREADS=$(grep -E '^\- \[ \]' "$CONTEXT_FILE" 2>/dev/null || true)
            if [ -n "$THREADS" ]; then
                echo "$THREADS"
            else
                echo "_No open threads._"
            fi

            JOURNAL_COUNT=$(grep -cE '^\| [0-9]{4}-' "$CONTEXT_FILE" 2>/dev/null || echo "0")
            echo ""
            echo "### Journal Entries: $JOURNAL_COUNT"
        fi
    fi
}

# =============================================================================
# WORKSTATION-LEVEL STATUS
# =============================================================================

show_workstation_status() {
    echo "# TURING Workstation Memory Status"
    echo ""
    echo "Scanning for TURING sessions across all projects..."
    echo ""

    # Use Python for workstation scan (handles deduplication and complex logic)
    python3 << 'PYEOF'
import os
import json
from pathlib import Path

# Common project locations
search_paths = [
    os.path.expanduser("~/Projects"),
    os.path.expanduser("~/projects"),
    os.path.expanduser("~/Developer"),
    os.path.expanduser("~/dev"),
    os.path.expanduser("~/code"),
    os.path.expanduser("~/Code"),
    os.path.expanduser("~/workspace"),
    os.path.expanduser("~/Work"),
    os.path.expanduser("~/work"),
]

found_projects = []
seen_projects = set()
total_sessions = 0
total_tokens = 0

seen_search_paths = set()
for search_path in search_paths:
    if not os.path.isdir(search_path):
        continue

    # Resolve symlinks for search path to avoid duplicates
    try:
        search_path = os.path.realpath(search_path)
    except:
        pass

    if search_path in seen_search_paths:
        continue
    seen_search_paths.add(search_path)

    # Walk up to 5 levels deep looking for .claude/sessions
    for root, dirs, files in os.walk(search_path):
        # Limit depth
        depth = root[len(search_path):].count(os.sep)
        if depth > 5:
            dirs[:] = []  # Don't recurse deeper
            continue

        # Check if this is a sessions directory
        if os.path.basename(root) == "sessions" and ".claude" in root:
            sessions_dir = root
            claude_dir = os.path.dirname(sessions_dir)
            project_dir = os.path.dirname(claude_dir)
            project_name = os.path.basename(project_dir)

            # Resolve symlinks and normalize path for deduplication
            try:
                project_dir = os.path.realpath(project_dir)
                project_name = os.path.basename(project_dir)  # Update name after resolving
            except:
                pass

            # Skip if already seen (use samefile to handle case-insensitive macOS)
            is_duplicate = False
            for seen_path in seen_projects:
                try:
                    if os.path.samefile(project_dir, seen_path):
                        is_duplicate = True
                        break
                except:
                    pass
            if is_duplicate:
                continue
            seen_projects.add(project_dir)

            # Count sessions
            session_count = 0
            tokens = 0

            index_file = os.path.join(sessions_dir, "index.json")
            if os.path.exists(index_file):
                try:
                    with open(index_file) as f:
                        index = json.load(f)
                    sessions = index.get("sessions", {})
                    session_count = len(sessions)
                    tokens = sum(s.get("tokens", 0) for s in sessions.values())
                except:
                    pass

            if session_count == 0:
                # Fallback: scan directories
                for item in os.listdir(sessions_dir):
                    item_path = os.path.join(sessions_dir, item)
                    if os.path.isdir(item_path) and not item.startswith('.'):
                        state_file = os.path.join(item_path, "state.md")
                        if os.path.exists(state_file):
                            session_count += 1
                            try:
                                tokens += os.path.getsize(state_file) // 4
                            except:
                                pass

            if session_count > 0:
                found_projects.append({
                    "name": project_name,
                    "sessions": session_count,
                    "tokens": tokens,
                    "path": project_dir
                })
                total_sessions += session_count
                total_tokens += tokens

if not found_projects:
    print("No TURING sessions found on this workstation.")
else:
    print("## Projects with TURING Memory")
    print("")
    print("| Project | Sessions | Tokens | Path |")
    print("|---------|----------|--------|------|")

    for p in sorted(found_projects, key=lambda x: x["sessions"], reverse=True):
        print(f"| {p['name']} | {p['sessions']} | ~{p['tokens']} | `{p['path']}` |")

    print("")
    print("## Workstation Summary")
    print("")
    print(f"- **Total Projects**: {len(found_projects)}")
    print(f"- **Total Sessions**: {total_sessions}")
    print(f"- **Total Tokens**: ~{total_tokens}")
    print("")
    print("---")
    print("")
    print("Use `/turing-status` in a specific project for detailed session info.")
PYEOF
}

# =============================================================================
# MAIN
# =============================================================================

if [ "$GLOBAL_MODE" = true ]; then
    show_workstation_status
else
    show_project_status "$(pwd)"
fi

exit 0
