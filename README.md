![TURING](assets/logo.png)

# TURING

**Autonomous State Machine for Cognitive Continuity**

> *"We may compare a man in the process of computing a real number to a machine which is only capable of a finite number of conditions."*
> — Alan Turing, "On Computable Numbers" (1936)

A Claude Code plugin that preserves session state across context compaction events, enabling cognitive continuity for long-running AI-assisted development sessions.

## The Problem

Claude Code has finite context. When context fills up, it compacts—summarizing the conversation and losing detailed state. For long-running sessions, this means:

- Loss of architectural decisions and their rationale
- Forgotten file changes and their purposes
- Broken continuity in multi-step implementations
- Repeated work due to lost context

## The Solution

TURING automatically captures session state **before** compaction and restores it **after**, creating a persistent memory layer that survives context boundaries.

```
┌─────────────────────┐     PreCompact      ┌─────────────────────┐
│      ACTIVE         │ ──────────────────► │    COMPACTING       │
│  (working normally) │                     │  (state captured)   │
└─────────────────────┘                     └─────────────────────┘
                                                      │
         ┌────────────────────────────────────────────┘
         │ SessionStart
         ▼
┌─────────────────────┐
│     RESTORED        │
│  (state recovered)  │
└─────────────────────┘
```

## Features

| Feature | Description |
|---------|-------------|
| **Priority-Based Restore** | CRITICAL/HIGH/MEDIUM/LOW/ARCHIVE levels for token efficiency |
| **Token Budget Tracking** | Estimates context consumption, warns when state is bloated |
| **Auto Decision Extraction** | Extracts decisions from transcript ("decided to...", "going with...") |
| **Open Threads** | Track open work items across sessions (~100 tokens) |
| **State Archiving** | Previous states archived before overwrite |
| **TTY-Based Session Discovery** | Multiple terminals maintain independent state |
| **ADR Recording** | Architecture Decision Records with TL;DR summaries |

## How TURING Differs

TURING differentiates from other Claude Code context plugins by targeting compaction events specifically with PreCompact/SessionStart hooks for automatic state persistence, rather than relying on manual summaries or skills. Unlike Claude-Mem's AI-compressed activity logs via SQLite/PM2 or Context-Toolkit's human-authored CONTEXT.md workflows, TURING captures git state, auto-extracts decisions, and uses TTY-based multi-terminal discovery for seamless continuity.

### Comparison

| Feature | TURING | Claude-Mem | Context-Toolkit | Claude-Context-Manager |
|---------|--------|------------|-----------------|------------------------|
| **What's Preserved** | Session decisions/focus | Conversation summaries | Static briefings | Code patterns/conventions |
| **Trigger** | Auto on compaction hooks | Background tool monitoring | Manual CONTEXT.md updates | claude.md health checks |
| **Storage** | `.claude/sessions/` (JSON/MD/ADR) | SQLite summaries | Human briefings | Autonomous claude.md sync |
| **Discovery** | Session ID + recency matching | Last 10 summaries | N/A (static files) | Session integration |
| **Token Optimization** | Priority restore (~2000 tokens) | AI compression | N/A | Staleness detection |
| **Dependencies** | None (bash/Python/git) | PM2/SQLite | None | CCMP ecosystem |

### Architectural Edge

TURING's Turing machine-inspired m-configurations (ACTIVE/COMPACTING states) and ADR tracking provide machine-parseable YAML frontmatter with checksums, enabling verifiable cognitive continuity for agentic sessions. The priority-based restore system provides low-overhead, production-grade persistence over summary-based alternatives. No external dependencies ensure portability across macOS/Linux, avoiding runtime overhead from background processes or databases.

## Quick Start

```bash
# Add the marketplace
/plugin marketplace add agenisea/turing

# Install the TURING plugin
/plugin install turing@agenisea-ai
```

That's it. TURING works automatically via hooks.

## Commands

| Command | Description |
|---------|-------------|
| `/turing-save` | Manually preserve state and record ADRs |
| `/turing-status` | View memory status (sessions, tokens, ADRs) |
| `/turing-status --global` | View memory across all projects on workstation |

## How It Works

1. **PreCompact hook** fires before context compaction
2. TURING captures: git state, decisions, modified files, session metadata
3. State written to `.claude/sessions/{session_id}/state.md`
4. **SessionStart hook** fires when session resumes
5. TURING restores state based on priority level and source type

## Documentation

See [TURING.md](TURING.md) for comprehensive documentation:

- Conceptual foundation (Turing machine metaphor)
- Features in depth
- Architecture and file formats
- Hook system details
- Session discovery algorithm
- Gotchas and troubleshooting

## Requirements

- Claude Code 1.0+
- Python 3 (pre-installed on macOS/Linux)
- Git (for state capture)
- No external dependencies

## Disclaimer

IMPORTANT: TURING writes files to your project's `.claude/` directory and executes shell scripts during Claude Code hook events. The authors are not responsible for any loss of data. Always maintain proper backups.

## License

MIT License — see [LICENSE](LICENSE)

## Links

- [Repository](https://github.com/agenisea/turing)
- [Issues](https://github.com/agenisea/turing/issues)
- [Full Documentation](TURING.md)

---

Built by [Agenisea AI™](https://agenisea.ai) | Cognitive Continuity for Claude Code
