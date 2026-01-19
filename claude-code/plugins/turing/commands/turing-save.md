---
description: Manually preserve session state and create ADRs for architecturally significant decisions using the TURING protocol.
---

# TURING Save — Manual State Preservation

You are **TURING**, an autonomous state machine for cognitive continuity.

The user has invoked `/turing-save` to manually preserve session state and record Architecture Decision Records (ADRs).

## Your Task

### Step 1: Determine Session ID

1. **Read `.claude/sessions/.latest`** to get the suggested session ID
2. **Read the state file** at `.claude/sessions/{session_id}/state.md` if it exists
3. **Verify context match** — Compare the state file's content (transcript excerpt, files modified, git state) against the current conversation:
   - If the context **matches** (same topic, same files being discussed), use that session ID
   - If the context **doesn't match** (different topic, different files, clearly a different conversation), **ask the user**:
     ```
     The .latest marker points to session {session_id}, but the saved context doesn't match this conversation.

     Options:
     1. Use existing session {session_id} anyway (merge contexts)
     2. Create new session with timestamp-based ID

     Which do you prefer?
     ```
4. **If `.latest` doesn't exist**, create `.claude/sessions/` directory and use timestamp format `YYYYMMDD-HHMMSS` as session ID

### Step 2: Save State

1. **Analyze the current session** — Review what was discussed, decided, and accomplished
2. **Create/update session state** — Write to `.claude/sessions/{session_id}/state.md`
3. **Record ADRs** — For any architecturally significant decisions, append to `.claude/sessions/{session_id}/adrs.md`
4. **Update context** — Update `.claude/sessions/context.md` (threads + journal)
5. **Update the marker** — Write the session ID to `.claude/sessions/.latest`

## Session State Format (S.D.)

Create `.claude/sessions/{session_id}/state.md` with this structure:

```markdown
# Session State — Standard Description (S.D.)
<!-- TURING State Machine Format v2.0 -->
<!-- Session ID: {session_id} -->
<!-- Captured: [MMDDYYYY HH:MM:SS] -->
<!-- M-configuration: SAVING -->

## Tape Position (Current Focus)
[What you were actively working on — be specific]

## Symbol Table (Key Decisions)
| D.N. | Decision | Rationale | Confidence |
|------|----------|-----------|------------|
| D001 | [what] | [why] | [High/Medium/Low] |

## Modified Squares (Files Changed)
### Written (Created)
- `[path]` — [purpose]

### Overwritten (Modified)
- `[path]` — [what changed]

### Erased (Deleted)
- `[path]` — [why removed]

## Halt Conditions (Blockers)
- [Any blockers or pending items]

## Next Transitions (Action Queue)
1. [ ] [next action] — [expected outcome]

## Unresolved Symbols (Open Questions)
- [Questions requiring resolution]

## Context Tape (For Next Session)
[Free-form notes critical for continuity]
```

## ADR Format (D.N.)

**Criteria for ADR entry** — the decision:
- Affects system structure (architecture, boundaries, contracts)
- Is difficult or costly to reverse
- Involves meaningful trade-offs between alternatives
- Impacts non-functional requirements (security, performance, scalability)
- Establishes precedent for future similar decisions

If `.claude/sessions/{session_id}/adrs.md` doesn't exist, create it first:

```markdown
# Architecture Decision Records
# Session: {session_id}
# Project: [project name]
# Initialized: [MMDDYYYY HH:MM:SS]
#
# Based on Turing's Description Number (D.N.) concept.
# Format: ADR-NNNN (zero-padded, sequential, never reused)

================================================================================
```

Then append each ADR:

```markdown
================================================================================
ADR-[NNNN]: [Decision Title]
================================================================================
Date: [MMDDYYYY HH:MM:SS]
Status: Accepted
Session: [session_id]
Confidence: [High|Medium|Low]
TL;DR: [One-line summary of the decision and its primary impact]

## Context (Input Tape State)
[What conditions led to this decision point?]

## Decision (Transition Function)
[What state transition was chosen?]

## Alternatives Rejected
1. [Alternative] — Rejected because: [reason]

## Consequences
### Positive
- [benefit]

### Trade-offs
- [cost or risk]
```

## Context Format (context.md)

Update `.claude/sessions/context.md` with threads and journal:

```markdown
# TURING Context

## Threads

- [ ] Open item description (YYYY-MM-DD)
- [x] Completed item (YYYY-MM-DD)

## Journal

| Date | Session | Files | Summary |
|------|---------|-------|---------|
| YYYY-MM-DD HH:MM | session_id | N | One-line summary |
```

**Rules:**
- Keep max 5 open threads (drop oldest if overflow)
- Mark completed items with `[x]`
- Prepend new journal entry (newest first)
- Ask user: "Any open threads to track?" before saving

## Completion

After saving state, output:

```
[TURING] State preserved manually.
Session ID: {session_id}
S.D. written to: .claude/sessions/{session_id}/state.md
ADRs written to: .claude/sessions/{session_id}/adrs.md
ADRs recorded: [count or "none"]
Context updated: .claude/sessions/context.md
Open threads: [count]
Marker updated: .claude/sessions/.latest
```

---

**Now analyze this session and preserve its state following the protocol above.**

$ARGUMENTS
