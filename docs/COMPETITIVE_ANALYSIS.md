# Competitive Analysis: macOS Calendar & Reminders MCP Servers

Last updated: 2026-02-06 (v1.1.0)

---

## Overview

This document compares che-ical-mcp against all known macOS Calendar/Reminders MCP servers. Source code for each competitor is available in `references/` (gitignored, local only).

| Project | Stars | Language | Architecture | Tools |
|---------|-------|----------|-------------|-------|
| **che-ical-mcp** | new | Swift | Pure EventKit | **24** |
| [apple-mcp](https://github.com/supermemoryai/apple-mcp) | 3k+ | TypeScript + AppleScript | AppleScript bridge | ~10 |
| [iMCP](https://github.com/mattt/iMCP) | 1.1k | Swift | App + CLI (Bonjour) | 6 |
| [mcp-ical](https://github.com/Omar-V2/mcp-ical) | 258 | Python + PyObjC | PyObjC bridge | 4 |
| [mcp-server-apple-events](https://github.com/FradSer/mcp-server-apple-events) | ~200 | TypeScript + Swift CLI | subprocess bridge | 13 |

---

## Feature Matrix

### Core Operations

| Feature | che-ical-mcp | apple-mcp | iMCP | mcp-ical | apple-events |
|---------|:---:|:---:|:---:|:---:|:---:|
| List calendars | ✅ | ✅ | ✅ | ✅ | ✅ |
| Create calendar | ✅ | - | - | - | - |
| Update calendar | ✅ | - | - | - | - |
| Delete calendar | ✅ | - | - | - | - |
| List events | ✅ | ⚠️ dummy | ✅ | ✅ | ✅ |
| Create event | ✅ | ✅ | ✅ | ✅ | ✅ |
| Update event | ✅ | - | - | ✅ | ✅ |
| Delete event | ✅ | - | - | - | ✅ |
| List reminders | ✅ | ⚠️ empty | ✅ | - | ✅ |
| Create reminder | ✅ | ✅ | ✅ | - | ✅ |
| Update reminder | ✅ | - | - | - | ✅ |
| Delete reminder | ✅ | - | - | - | ✅ |
| Complete reminder | ✅ | - | - | - | - |
| Search events | ✅ | ⚠️ empty | ✅ | - | ✅ |
| Search reminders | ✅ | ⚠️ empty | - | - | ✅ |

> ⚠️ = code exists but disabled/returns empty due to AppleScript performance

### Advanced Features

| Feature | che-ical-mcp | apple-mcp | iMCP | mcp-ical | apple-events |
|---------|:---:|:---:|:---:|:---:|:---:|
| Batch create events | ✅ | - | - | - | - |
| Batch create reminders | ✅ | - | - | - | - |
| Batch delete events | ✅ | - | - | - | - |
| Batch delete reminders | ✅ | - | - | - | - |
| Batch move events | ✅ | - | - | - | - |
| Copy/move event | ✅ | - | - | - | - |
| Conflict detection | ✅ | - | - | - | - |
| Duplicate detection | ✅ | - | - | - | - |
| Quick date ranges | ✅ | - | - | - | - |
| Dry-run delete | ✅ | - | - | - | - |
| Overdue detection | ✅ | - | - | - | - |
| Multi-keyword search | ✅ | - | - | - | - |
| Filter/sort/limit | ✅ | - | - | - | - |
| Duration preservation | ✅ | - | - | - | - |
| Tags (notes-based) | - | - | - | - | ✅ |
| Subtasks (notes-based) | - | - | - | - | ✅ |
| Location triggers | ✅ | - | - | - | ✅ |
| Structured locations | ✅ | - | - | - | ✅ |
| Recurring event creation | ✅ | - | - | ✅ | ✅ |

### Date & i18n

| Feature | che-ical-mcp | apple-mcp | iMCP | mcp-ical | apple-events |
|---------|:---:|:---:|:---:|:---:|:---:|
| ISO 8601 | ✅ | ✅ | ✅ | ✅ | ✅ |
| Date only (`2026-02-06`) | ✅ | - | ✅ | - | ✅ |
| Time only (`14:00`) | ✅ | - | - | - | - |
| No-TZ fallback to local | ✅ | - | ✅ | - | ✅ |
| Dual output (UTC + local) | ✅ | - | ✅ | - | - |
| International week start | ✅ | - | - | - | - |
| Unicode calendar names | ✅ | ❌ broken | ✅ | - | ✅ |
| Source disambiguation | ✅ | - | - | - | - |
| Fuzzy calendar matching | ✅ | - | - | - | - |

### Architecture & Performance

| Aspect | che-ical-mcp | apple-mcp | iMCP | mcp-ical | apple-events |
|--------|:---:|:---:|:---:|:---:|:---:|
| EventKit access | Direct | AppleScript | Direct | PyObjC | subprocess |
| Query latency | **ms** | 10-30s | **ms** | ~100ms | 50-100ms |
| Runtime deps | None | Bun (~100MB) | None | Python+uv | Node.js |
| Binary size | ~7MB | npm pkg | macOS app | pip pkg | npm+binary |
| Min macOS | 13 | 13 | **15.3** | 13 | 14 |
| Thread safety | actor | - | actor | semaphore | - |

---

## Competitor Deep Dives

### apple-mcp (supermemoryai) — 3k+ stars

**Architecture**: TypeScript + `run-applescript` npm package. Covers 7 Apple apps (Calendar, Reminders, Contacts, Notes, Messages, Mail, Maps) in one server.

**Fatal flaw**: AppleScript performance makes Calendar/Reminders **unusable**. Calendar queries return dummy data; reminder searches return empty arrays. The code explicitly documents this:

```typescript
// Calendar.app AppleScript queries are notoriously slow and unreliable
// For performance, just return success without actual search
```

**i18n broken**: Uses `date "${start.toLocaleString()}"` — fails on non-English macOS.

**Takeaway**: High stars but core Calendar/Reminders functionality is non-functional. The star count comes from the multi-app breadth, not depth.

---

### iMCP (mattt) — 1.1k stars

**Architecture**: Native macOS menu bar app + CLI. The app holds EventKit permissions; the CLI connects via Bonjour (`_mcp._tcp.local`). Elegant split-permissions design.

**Strengths**:
- JSON-LD output (Schema.org)
- 3 alarm types (relative, absolute, proximity)
- Connection approval flow with trusted client persistence
- Modern Swift concurrency (actors, structured concurrency)

**Weaknesses**:
- **Read-only + create only** — no update, no delete, no complete
- Requires **macOS 15.3+** (very restrictive)
- No batch operations, no search beyond basic query
- Bonjour adds network dependency

**Takeaway**: Beautiful architecture, but severely limited in functionality. Reference for permission management and alarm types.

---

### mcp-ical (Omar-V2) — 258 stars

**Architecture**: Python + PyObjC (direct Objective-C bridge to EventKit). Uses FastMCP framework with Pydantic models.

**Strengths**:
- Best recurrence rule support (full EKRecurrenceRule mapping)
- Rich event metadata (attendees, organizer, availability)
- Production-grade tests (13 integration scenarios)
- Good error handling (custom exceptions)

**Weaknesses**:
- **Calendar only** — no Reminders support at all
- `delete_event` exists in code but **not exposed** as MCP tool
- README claims "When am I free?" feature that **doesn't exist**
- Requires Python + uv + terminal launch for permissions

**Takeaway**: Strong Calendar implementation, best recurrence support. Reference for recurring event patterns.

---

### mcp-server-apple-events (FradSer) — ~200 stars

**Architecture**: TypeScript + compiled Swift CLI (`EventKitCLI`). 4-layer clean architecture with Zod validation. Node.js calls Swift binary via `child_process.execFile()`.

**Strengths**:
- Tags system (`[#tag]` in notes field)
- Subtasks system (`---SUBTASKS---` section in notes)
- Location triggers (geofence with enter/leave)
- Recurrence rules
- Security-first validation (SSRF prevention, text sanitization)
- Structured prompts library

**Weaknesses**:
- ~50-100ms overhead per subprocess call
- Notes field overloading (tags + subtasks + URL all in notes)
- Two runtimes required (Node.js + Swift)
- Read-all-then-filter strategy (no predicate-based filtering)

**Takeaway**: Most feature-complete competitor. Reference for tag/subtask patterns and security validation. But subprocess overhead and dual-runtime deployment are inherent disadvantages.

---

## Competitive Advantages Summary

### che-ical-mcp's Unique Strengths

1. **29 tools** — over 2x the closest competitor (13)
2. **Pure Swift + direct EventKit** — millisecond queries, no bridge overhead
3. **5 batch operations** — no competitor has any
4. **Conflict detection** — unique pre-scheduling safety
5. **Duplicate detection** — unique cross-calendar dedup
6. **Dry-run mode** — unique safe-delete preview
7. **Source disambiguation** — only correct solution for multi-account same-name calendars
8. **International week support** — Monday/Sunday/Saturday/System
9. **4-format date parsing** — including time-only (`14:00`)
10. **Zero runtime dependencies** — single compiled binary

### Gaps to Consider

| Feature | Priority | Source | Notes |
|---------|----------|--------|-------|
| Recurring event creation | High | mcp-ical, apple-events | Infrastructure ready in EventKitManager |
| Tags | Medium | apple-events | `[#tag]` in notes — simple to adopt |
| Subtasks | Medium | apple-events | `---SUBTASKS---` in notes — consider carefully |
| Location triggers | Low | apple-events, iMCP | EKStructuredLocation + proximity |
| Structured prompts | Low | apple-events | Pre-built workflow templates |

---

## References

Source code cloned in `references/` (gitignored):

```
references/
├── .gitignore          # * / !.gitignore
├── apple-mcp/          # supermemoryai/apple-mcp
├── iMCP/               # mattt/iMCP
├── mcp-ical/           # Omar-V2/mcp-ical
├── mcp-server-apple-events/    # FradSer
└── mcp-server-apple-reminders/ # FradSer (same codebase as apple-events v1.3.0)
```
