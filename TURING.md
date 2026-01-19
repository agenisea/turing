![TURING](assets/logo.png)

# TURING — Autonomous State Machine for Cognitive Continuity

> *"We may compare a man in the process of computing a real number to a machine which is only capable of a finite number of conditions."*
> — Alan Turing, "On Computable Numbers" (1936)

TURING is a Claude Code plugin that preserves session state across context compaction events, enabling cognitive continuity for long-running AI-assisted development sessions.

**Version 1.1** — Priority-based selective restore, token budget tracking, auto decision extraction, state archiving, and open threads.

## Table of Contents

- [Conceptual Foundation](#conceptual-foundation)
- [How It Works](#how-it-works)
- [Features](#features)
- [Architecture](#architecture)
- [Tech Stack](#tech-stack)
- [Hook System](#hook-system)
- [Session Discovery Algorithm](#session-discovery-algorithm)
- [File Formats](#file-formats)
- [Installation](#installation)
- [Usage](#usage)
- [Gotchas & Limitations](#gotchas--limitations)
- [Troubleshooting](#troubleshooting)
- [Development](#development)

---

## Conceptual Foundation

TURING draws from Alan Turing's 1936 paper "On Computable Numbers, with an Application to the Entscheidungsproblem" — the foundational work that introduced:

| Turing Concept | TURING Plugin Equivalent |
|----------------|--------------------------|
| **m-configurations** | Session states (ACTIVE, COMPACTING, RESTORED, HALTED) |
| **Infinite tape** | Conversation context divided into sessions |
| **Scanning head** | Claude's current focus in the codebase |
| **Standard Description (S.D.)** | `.claude/sessions/{session_id}/state.md` |
| **Description Number (D.N.)** | ADR entries (ADR-0001, ADR-0002, etc.) |

### The Problem

Claude Code has finite context. When context fills up, it compacts — summarizing the conversation and losing detailed state. For long-running sessions, this means:

- Loss of architectural decisions and their rationale
- Forgotten file changes and their purposes
- Broken continuity in multi-step implementations
- Repeated work due to lost context

### The Solution

TURING automatically captures session state **before** compaction and restores it **after**, creating a persistent memory layer that survives context boundaries.

---

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                        NORMAL OPERATION                         │
│                                                                 │
│    Claude Code Session (ACTIVE)                                 │
│    ├── User requests                                            │
│    ├── File modifications                                       │
│    ├── Architectural decisions                                  │
│    └── Context accumulates...                                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ Context limit approached
┌─────────────────────────────────────────────────────────────────┐
│                     PreCompact HOOK FIRES                       │
│                                                                 │
│    capture-context.sh executes:                                 │
│    ├── Reads session_id from hook input                         │
│    ├── Captures git state (branch, commits, changes)            │
│    ├── Captures project identification                          │
│    ├── Saves transcript excerpt                                 │
│    ├── Writes state.md (Standard Description)                   │
│    ├── Writes metadata.json (TTY, timestamps)                   │
│    ├── Updates index.json (session registry)                    │
│    └── Outputs state for Claude to see before compaction        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ Context compacts
┌─────────────────────────────────────────────────────────────────┐
│                   SessionStart HOOK FIRES                       │
│                   (source: "compact")                           │
│                                                                 │
│    restore-context.sh executes:                                 │
│    ├── Reads session_id from hook input                         │
│    ├── Loads state.md for current session                       │
│    ├── Displays restored state to Claude                        │
│    ├── Shows ADR summaries (TL;DR)                              │
│    └── Shows current git state for orientation                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    SESSION CONTINUES (RESTORED)                 │
│                                                                 │
│    Claude has context from:                                     │
│    ├── Compaction summary (built-in)                            │
│    ├── TURING state.md (detailed state)                         │
│    ├── ADR history (architectural decisions)                    │
│    └── Git state (current codebase position)                    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Features

Key capabilities for context efficiency and reliability.

### Priority-Based Selective Restore

State sections are tagged with priority levels to optimize token usage:

| Priority | Content | Included On |
|----------|---------|-------------|
| **CRITICAL** | Active focus, blockers | All restores |
| **HIGH** | Key decisions, next steps | All restores |
| **MEDIUM** | Modified files, project context | compact/resume |
| **LOW** | Session history, project info | Explicit request |
| **ARCHIVE** | Compressed previous states | Never auto-included |

**Behavior by Source:**
- `startup` (new session): CRITICAL + HIGH only (~minimal tokens)
- `compact`/`resume` (continuity): CRITICAL + HIGH + MEDIUM (~moderate tokens)
- `/turing-full` command: ALL priorities (~full context)

### Token Budget Tracking

Every capture tracks token usage:

```
**Tokens**: ~2000 (state: 300, template: 1700)
```

**What tokens represent:** These are **context window consumption estimates** — how many tokens the restored TURING state will use in Claude's context when a session is restored. They are NOT API billing tokens.

```
┌─────────────────────────────────────────────┐
│           Claude Context Window             │
├─────────────────────────────────────────────┤
│ TURING restored state (~300 tokens)         │ ← Tracked here
│ System prompts & instructions               │
│ Conversation history                        │
│ Code being discussed                        │
│ Available space for new work                │
└─────────────────────────────────────────────┘
```

- Estimates tokens using ~4 chars/token heuristic
- Warns when context exceeds 2500 tokens (state getting bloated)
- Tracks token history across compactions in `metadata.json`
- Helps you understand how much context space TURING consumes on restore

### Auto Decision Extraction

Automatically extracts decisions from the conversation transcript:

```markdown
### Auto-Extracted
- implemented TTY-based session discovery
- going with SQLite + sqlite-vec for storage
- decided to use priority levels for state filtering
```

**Patterns recognized:**
- "decided to [action]"
- "going with [choice]"
- "will use [tool] because"
- "chose [option] over [alternative]"
- "implemented [feature]"

### Open Threads

Track open work items across sessions via `.claude/sessions/context.md`:

```markdown
## Threads
- [ ] Add rate limiting (2026-01-19)
- [ ] Review caching strategy (2026-01-19)
```

- Max 5 open threads displayed on restore (~100 tokens)
- Completed `[x]` threads auto-pruned
- Session journal logged but never restored (write-only)

### State Decay & Archiving

Previous states are automatically archived before overwrite:

```
.claude/sessions/{session_id}/
├── state.md              # Current state
├── metadata.json         # Session metadata
└── archive/
    ├── state-1702858200.md   # Previous state 1
    └── state-1702861800.md   # Previous state 2
```

Key info from previous states is summarized in the ARCHIVE section.

### YAML Frontmatter

State files now include machine-parseable YAML frontmatter:

```yaml
---
version: 1.1
session_id: abc123-def456
tty: /dev/ttys001
captured_at: 2025-12-17T15:30:00Z
compaction_count: 3
trigger: auto
project: my-project
checksum: a1b2c3d4e5f6...
token_estimate: 850
---
```

### Validation & Checksums

- MD5 checksum generated for state file integrity
- Validation status tracked (success, warning:small, error:missing)
- Checksum stored both in frontmatter and `.state-checksum` file

### Enhanced Metadata

`metadata.json` now tracks:

```json
{
  "session_id": "abc123",
  "created_at": "2025-12-17T10:00:00Z",
  "last_compacted_at": "2025-12-17T15:30:00Z",
  "tty": "/dev/ttys001",
  "project_dir": "/path/to/project",
  "compaction_count": 3,
  "validation": {
    "status": "success",
    "state_bytes": 3400,
    "state_lines": 85,
    "checksum": "a1b2c3d4..."
  },
  "tokens": {
    "state": 300,
    "template": 1700,
    "total": 2000,
    "status": "ok"
  },
  "token_history": [
    {"timestamp": "...", "tokens": 250, "compaction": 1},
    {"timestamp": "...", "tokens": 280, "compaction": 2},
    {"timestamp": "...", "tokens": 300, "compaction": 3}
  ],
  "auto_decisions_extracted": 5
}
```

---

## Architecture

### Directory Structure

```
project-root/
└── .claude/
    └── sessions/
        ├── index.json                    # Session registry for fast lookup
        ├── context.md                    # Open threads + session journal
        ├── .latest                       # Backwards-compat marker
        ├── {session_id_1}/
        │   ├── state.md                  # Standard Description (S.D.)
        │   ├── adrs.md                   # Architecture Decision Records
        │   ├── metadata.json             # Session metadata
        │   ├── .state-checksum           # MD5 checksum for validation
        │   └── archive/                  # Previous state versions
        │       ├── state-1702858200.md
        │       └── state-1702861800.md
        └── {session_id_2}/
            ├── state.md
            ├── adrs.md
            ├── metadata.json
            └── .state-checksum
```

### Plugin Structure

```
claude-code/plugins/turing/
├── .claude-plugin/
│   └── plugin.json                       # Plugin manifest
├── hooks/
│   └── hooks.json                        # Hook definitions
├── scripts/
│   ├── capture-context.sh                # PreCompact handler
│   └── restore-context.sh                # SessionStart handler
├── commands/
│   └── turing-save.md                    # Manual save command
└── templates/
    └── turing-precompact.md              # Protocol template
```

---

## Tech Stack

### Runtime Dependencies

| Component | Purpose | Why This Choice |
|-----------|---------|-----------------|
| **Bash** | Script execution | Universal on macOS/Linux, no installation needed |
| **Python 3** | JSON parsing | Pre-installed on macOS/Linux, more robust than jq |
| **Git** | State capture | Already present in development environments |

### No External Dependencies

TURING deliberately avoids external dependencies:

- **No jq** — Python's `json` module is more universal
- **No Node.js** — Slower startup, not always present
- **No compiled binaries** — Maximum portability

### Performance Characteristics

| Operation | Typical Time | Notes |
|-----------|--------------|-------|
| capture-context.sh | ~100-200ms | Dominated by git commands |
| restore-context.sh | ~50-100ms | Mostly file reads |
| Python JSON parsing | ~10-20ms | Negligible overhead |

---

## Hook System

### Hook Types Used

TURING uses two Claude Code hook types:

#### PreCompact Hook

Fires **before** context compaction occurs.

```json
{
  "PreCompact": [
    {
      "matcher": "auto",
      "hooks": [{ "type": "command", "command": "..." }]
    },
    {
      "matcher": "manual",
      "hooks": [{ "type": "command", "command": "..." }]
    }
  ]
}
```

**Matchers:**
- `auto` — Automatic compaction (context limit reached)
- `manual` — User-triggered via `/compact` command

**Input (stdin JSON):**
```json
{
  "session_id": "abc123-def456",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/path/to/project",
  "trigger": "auto"
}
```

#### SessionStart Hook

Fires when a session starts or resumes.

```json
{
  "SessionStart": [
    { "matcher": "startup", "hooks": [...] },
    { "matcher": "resume", "hooks": [...] },
    { "matcher": "compact", "hooks": [...] }
  ]
}
```

**Matchers:**
- `startup` — Fresh `claude` invocation (new session_id)
- `resume` — `claude --resume` or `claude --continue` (same session_id)
- `compact` — After context compaction (same session_id)

**Input (stdin JSON):**
```json
{
  "session_id": "abc123-def456",
  "cwd": "/path/to/project",
  "source": "compact"
}
```

### Hook Output

Hooks output to **stdout**. Everything printed becomes part of the initial context Claude sees.

```bash
echo "# [TURING] State Restored"
echo ""
cat "$STATE_FILE"
```

### Critical Limitation: Prompt Hooks Don't Work for PreCompact

Claude Code supports two hook types:
- `"type": "command"` — Runs a shell command
- `"type": "prompt"` — Injects a prompt

**However, prompt-type hooks only work for `Stop` and `SubagentStop` hooks, NOT for `PreCompact`.** This is why TURING uses command hooks exclusively and outputs the protocol template via bash.

---

## Session Discovery Algorithm

When a fresh session starts (`source: "startup"`), TURING must find the most relevant previous session. This is non-trivial with multiple concurrent terminals.

### The Multi-Terminal Problem

```
Terminal A (session abc123): Working on feature X
Terminal B (session def456): Working on bugfix Y
                ↓
Terminal A: /compact → .latest = abc123
Terminal B: /compact → .latest = def456  (overwrites!)
                ↓
Terminal A: exits, starts fresh session
         → reads .latest → gets def456's state ❌ WRONG!
```

### The Solution: TTY-Based Discovery

Each session records its TTY (terminal device path):

```json
{
  "session_id": "abc123",
  "tty": "/dev/ttys001",
  "last_compacted_at": "2025-12-17T12:00:00Z"
}
```

Discovery priority:

1. **Same TTY, most recent** — If the current terminal matches a previous session's TTY, use that session
2. **Single recent session** — If only one session exists within 24 hours, use it
3. **Most recent overall** — Fall back to the most recently compacted session
4. **`.latest` marker** — Backwards compatibility if index.json doesn't exist

### Algorithm (Python)

```python
# Priority 1: Same TTY, most recent
tty_matches = [s for s in sessions if s['tty'] == current_tty]
if tty_matches:
    return max(tty_matches, key=lambda s: s['last_compacted_at'])

# Priority 2: Single recent session (within 24h)
recent = [s for s in sessions if is_within_24h(s['last_compacted_at'])]
if len(recent) == 1:
    return recent[0]

# Priority 3: Most recent overall
return max(sessions, key=lambda s: s['last_compacted_at'])
```

### TTY Values

| Scenario | TTY Value |
|----------|-----------|
| Interactive terminal | `/dev/ttys001`, `/dev/pts/0`, etc. |
| Piped input (CI/CD) | `pipe` |
| SSH session | `/dev/pts/N` |
| VS Code terminal | `/dev/ttys00N` |

---

## File Formats

### state.md (Standard Description)

**Format with YAML frontmatter and priority tags:**

```markdown
---
version: 1.1
session_id: abc123-def456
tty: /dev/ttys001
captured_at: 2025-12-17T15:30:00Z
compaction_count: 2
trigger: auto
project: my-project
checksum: a1b2c3d4e5f6...
token_estimate: 850
---

<!-- PRIORITY: CRITICAL -->
## Active Focus

Previous focus: Implementing session-aware architecture
Previous decisions: Use TTY-based discovery; Add priority levels

_Focus will be set by Claude during compaction. Use /turing-save to manually set._

<!-- PRIORITY: HIGH -->
## Key Decisions (This Session)

### Auto-Extracted
- implemented TTY-based session discovery
- going with priority levels for state filtering
- decided to use YAML frontmatter

### Recorded ADRs (2)
ADR-0001: Use TypeScript strict mode
TL;DR: Enable strict mode to catch type errors at compile time
ADR-0002: Use React Query for data fetching
TL;DR: Simplify data fetching with caching and background updates

<!-- PRIORITY: MEDIUM -->
## Modified Files

- **Branch**: `<your-current-branch>`
- **Uncommitted**: N files

```
M  path/to/modified-file.ext
A  path/to/staged-file.ext
?? path/to/untracked-file.ext
```

### Recent Commits
```
<hash> <your most recent commit message>
<hash> <previous commit message>
```

<!-- PRIORITY: LOW -->
## Project Context

- **Directory**: /Users/dev/project
- **Name**: my-project
- **Package**: @scope/my-project
- **CLAUDE.md**: Present

<!-- PRIORITY: ARCHIVE -->
## Session History

- **Compaction Count**: 2
- **Session Started**: 2025-12-17T10:00:00Z
- **Archived States**: 1

---
**M-configuration**: COMPACTING → HALTED
```

### metadata.json

```json
{
  "session_id": "abc123-def456",
  "created_at": "2025-12-17T10:00:00.000000Z",
  "last_compacted_at": "2025-12-17T15:30:00.000000Z",
  "tty": "/dev/ttys001",
  "project_dir": "/Users/dev/project"
}
```

### index.json

```json
{
  "sessions": {
    "abc123-def456": {
      "last_compacted_at": "2025-12-17T15:30:00.000000Z",
      "tty": "/dev/ttys001"
    },
    "xyz789-uvw012": {
      "last_compacted_at": "2025-12-17T14:00:00.000000Z",
      "tty": "/dev/ttys002"
    }
  },
  "last_updated": "2025-12-17T15:30:00.000000Z"
}
```

### adrs.md (Architecture Decision Records)

```markdown
# Architecture Decision Records
# Session: abc123-def456
# Project: my-project
# Initialized: 12172025 10:00:00

================================================================================
ADR-0001: Use TypeScript strict mode
================================================================================
Date: 12172025 10:30:00
Status: Accepted
Session: abc123-def456
Confidence: High
TL;DR: Enable strict mode to catch type errors at compile time

## Context
The project had several runtime type errors...

## Decision
Enable `strict: true` in tsconfig.json...

## Alternatives Rejected
1. Keep loose mode — Rejected because: Too many runtime errors

## Consequences
### Positive
- Catch errors at compile time

### Trade-offs
- More verbose type annotations required
```

### context.md (Threads + Journal)

```markdown
# TURING Context

## Threads

- [ ] Add rate limiting (2026-01-19)
- [x] Implement auth flow (2026-01-18)

## Journal

| Date | Session | Files | Summary |
|------|---------|-------|---------|
| 2026-01-19 16:45 | abc123 | 3 | Added unit tests |
```

- **Threads**: Restored on session start (max 5 open)
- **Journal**: Write-only historical log (never restored)

---

## Installation

### Via Claude Code Plugin System

```bash
# Add the marketplace
/plugin marketplace add agenisea/turing

# Install the TURING plugin
/plugin install turing@agenisea-ai
```

### Manual Installation

```bash
# Clone the repository
git clone https://github.com/agenisea/turing.git

# Install from local directory
/plugin marketplace add ./turing
/plugin install turing@agenisea-ai
```

---

## Usage

### Automatic Operation

TURING works automatically once installed:

1. **Work normally** — Make changes, discuss architecture, etc.
2. **Context compacts** — TURING captures state automatically
3. **Continue working** — State is restored seamlessly

### Manual Save

Use `/turing-save` to manually preserve state and record ADRs:

```
/turing-save
```

Claude will:
1. Analyze the current session
2. Create/update `state.md`
3. Record any architecturally significant decisions to `adrs.md`
4. Output confirmation

### View Memory Status

Use `/turing-status` to see TURING's cognitive memory:

```bash
/turing-status           # Project-level: sessions, tokens, ADRs
/turing-status --global  # Workstation-level: all projects with TURING memory
```

**Project-level output:**
```
# TURING Memory Status

## Project: my-project

### Sessions Overview
| Session ID | TTY | Last Compacted | Compactions | Tokens |
|------------|-----|----------------|-------------|--------|
| `abc123...` | /dev/ttys001 | 2h ago | 3 | ~850 |

## Latest Session: abc123...
- **Token Usage**: state=300, template=1700, total=2000
- **Compaction Count**: 3
```

**Workstation-level output:**
```
# TURING Workstation Memory Status

## Projects with TURING Memory
| Project | Sessions | Tokens | Path |
|---------|----------|--------|------|
| my-project | 2 | ~5098 | `/path/to/my-project` |

## Workstation Summary
- **Total Projects**: 1
- **Total Sessions**: 2
- **Total Tokens**: ~5098
```

### View Current State

```bash
cat .claude/sessions/$(cat .claude/sessions/.latest)/state.md
```

### View ADR History

```bash
cat .claude/sessions/$(cat .claude/sessions/.latest)/adrs.md
```

---

## Gotchas & Limitations

### 1. Plugin Cache Requires Restart

Claude Code caches plugins at session startup. If you modify the plugin:

```bash
# Changes won't take effect until you restart Claude Code
claude  # Fresh session picks up changes
```

### 2. TTY Detection in Pipes

When running Claude Code in a pipe (CI/CD, scripts), TTY is detected as `pipe`. All piped sessions share the same TTY identifier, which may cause session confusion.

**Workaround:** Use explicit session IDs in automated scenarios.

### 3. `${CLAUDE_PLUGIN_ROOT}` Only Works in Command Hooks

The `${CLAUDE_PLUGIN_ROOT}` variable expands only in `"type": "command"` hooks, not in `"type": "prompt"` hooks.

```json
// ✅ Works
{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh" }

// ❌ Does NOT work
{ "type": "prompt", "prompt": "Read ${CLAUDE_PLUGIN_ROOT}/templates/bar.md" }
```

### 4. Session IDs are Opaque

Session IDs are generated by Claude Code and are opaque strings. Don't rely on their format — they may change between versions.

### 5. Transcript Path May Be Empty

The `transcript_path` in hook input may be empty or point to a non-existent file in some scenarios. TURING handles this gracefully.

### 6. Git Operations Assume Git Repository

State capture includes git information. In non-git directories, git sections are omitted but the plugin still functions.

### 7. Python 3 Required

TURING requires Python 3 for JSON parsing. It's pre-installed on macOS and most Linux distributions. If missing:

```bash
# macOS
brew install python3

# Ubuntu/Debian
sudo apt install python3

# The script will output an error if Python 3 is not found
```

### 8. No Windows Support

TURING uses bash scripts and Unix-specific commands (`tty`, etc.). Windows support would require PowerShell equivalents.

### 9. ADRs Require Manual Trigger

ADRs are only recorded when:
- You run `/turing-save` manually
- Claude follows the TURING protocol during PreCompact (not guaranteed)

For critical decisions, explicitly use `/turing-save`.

### 10. Session Cleanup is Manual

Old sessions accumulate in `.claude/sessions/`. Periodically clean up:

```bash
# Remove sessions older than 7 days
find .claude/sessions -type d -mtime +7 -exec rm -rf {} +
```

---

## Troubleshooting

### State Not Being Captured

1. **Check plugin is installed:**
   ```bash
   claude /plugins
   ```

2. **Check hooks are registered:**
   ```bash
   cat ~/.claude/plugins/cache/*/hooks.json | grep -i turing
   ```

3. **Test capture script manually:**
   ```bash
   echo '{"session_id":"test","trigger":"auto"}' | \
     bash ./claude-code/plugins/turing/scripts/capture-context.sh
   ```

### State Not Being Restored

1. **Check session directory exists:**
   ```bash
   ls -la .claude/sessions/
   ```

2. **Check index.json:**
   ```bash
   cat .claude/sessions/index.json
   ```

3. **Test restore script manually:**
   ```bash
   echo '{"session_id":"test","source":"startup"}' | \
     bash ./claude-code/plugins/turing/scripts/restore-context.sh
   ```

### Wrong Session Being Restored

Check TTY matching:

```bash
# Current TTY
tty

# TTYs in index
cat .claude/sessions/index.json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for sid, info in data['sessions'].items():
    print(f'{sid}: {info.get(\"tty\", \"unknown\")}')"
```

### Debug Mode

Enable debug logging in the scripts:

```bash
# In capture-context.sh or restore-context.sh, uncomment:
# echo "$INPUT" > /tmp/turing-debug.json
```

---

## Development

### Running Tests

```bash
cd /path/to/turing

# Test capture
echo '{"session_id":"test-123","trigger":"auto","transcript_path":""}' | \
  bash ./claude-code/plugins/turing/scripts/capture-context.sh

# Test restore (startup)
echo '{"session_id":"new-session","source":"startup"}' | \
  bash ./claude-code/plugins/turing/scripts/restore-context.sh

# Test restore (compact)
echo '{"session_id":"test-123","source":"compact"}' | \
  bash ./claude-code/plugins/turing/scripts/restore-context.sh
```

### Debugging Hook Input

Add to script:

```bash
# At the top of capture-context.sh or restore-context.sh
INPUT=$(cat)
echo "$INPUT" > /tmp/turing-hook-input.json
```

Then check `/tmp/turing-hook-input.json` after a hook fires.

### Modifying the Plugin

1. Make changes to files in `claude-code/plugins/turing/`
2. Reinstall the plugin or clear the cache:
   ```bash
   rm -rf ~/.claude/plugins/cache/turing*
   claude /install ./path/to/plugin
   ```
3. Start a fresh Claude Code session

---

## License

MIT License — see [LICENSE](LICENSE)

---

## Credits

- **Concept & Implementation:** Patrick Peña
- **Inspiration:** Alan Turing's "On Computable Numbers" (1936)
- **Platform:** [Claude Code](https://claude.ai/code) by Anthropic
