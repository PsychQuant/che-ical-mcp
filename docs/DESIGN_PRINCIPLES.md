ㄋ# che-ical-mcp Design Principles

This document outlines the design principles that guide the development of che-ical-mcp. These principles are adapted from the NSQL project's foundational rules.

---

## 1. Try First, Disambiguate Later

### Core Principle

**Operations should attempt to succeed with minimal required information.** Additional parameters for disambiguation should only be required when actual ambiguity exists, not preemptively.

### Implementation in che-ical-mcp

The `calendar_source` parameter exemplifies this principle:

```
User: "List events from 教學課表"
        ↓
MCP Tool: list_events(calendar_name: "教學課表")
        ↓
┌─────────────────────────────────────────────────────┐
│  Only 1 calendar named "教學課表"?                   │
│  → Success! Return events directly.                 │
│                                                     │
│  Multiple calendars named "教學課表"?               │
│  → Return error with available sources for          │
│    AI/user to disambiguate.                         │
└─────────────────────────────────────────────────────┘
```

### Benefits

1. **Backward Compatibility**: Existing workflows continue to work without modification
2. **Reduced Friction**: Users don't need to specify source when it's unambiguous
3. **Progressive Complexity**: Simple cases remain simple; complexity only appears when needed
4. **AI-Friendly**: Error messages contain sufficient information for AI agents to make decisions

### Anti-Patterns to Avoid

- **Preemptive Requirements**: Don't require `calendar_source` on every call
- **Silent Selection**: Don't automatically pick one when ambiguous (especially for write operations)
- **Cryptic Errors**: Don't just say "ambiguous" - provide actionable options

---

## 2. Reference Resolution Rule

### Core Rule

**All references must be unambiguous.** When ambiguity exists in a reference (calendar name, reminder list, etc.), the system MUST provide clear information for disambiguation. No automatic resolution or assumptions about user intent are permitted for critical operations.

### Implementation Requirements

#### Ambiguity Detection

The system detects the following types of ambiguities:

| Ambiguity Type | Example | Resolution |
|----------------|---------|------------|
| **Same-Name Calendars** | "教學課表" exists in both iCloud and Google | List available sources |
| **Source Ambiguity** | User says "Google calendar" but multiple Google accounts exist | List specific calendars |
| **Entity Type Ambiguity** | "Work" could be a calendar or a reminder list | Ask for clarification |

#### Resolution Process

When ambiguity is detected:

1. **Immediate Feedback**: Return an error immediately with clear information
2. **Specific Information**: Provide exactly what options are available
3. **Actionable Guidance**: Explain how to resolve (e.g., "Please specify calendar_source")
4. **Context Preservation**: Include enough context for AI to retry intelligently

#### Example Error Message

```
Multiple calendars found with name '教學課表'.
Available sources: iCloud, Google
Please specify calendar_source to disambiguate.
```

Calendars of one account that share a name cannot be told apart by `calendar_source`. That refusal gives their count and ids and asks for `calendar_id`, or for a rename where the tool takes no `calendar_id` (#604).

This error message:
- States the problem clearly
- Lists all available options
- Provides actionable guidance

---

## 3. Natural Language Rule

### Core Rule

**Error messages and feedback should use familiar, accessible terminology rather than technical jargon.** This enables both users and AI agents to understand and respond appropriately.

### Terminology Guidelines

| Use This | Instead Of |
|----------|------------|
| calendar | EKCalendar entity |
| reminder list | reminder calendar |
| event | EKEvent object |
| source (iCloud, Google) | EKSource identifier |
| couldn't find | calendarNotFound error |
| multiple calendars found | multipleCalendarsFound exception |

### Implementation in Error Messages

#### Good (Natural Language):
```
Multiple calendars found with name '教學課表'.
Available sources: iCloud, Google
Please specify calendar_source to disambiguate.
```

#### Avoid (Technical Jargon):
```
EventKitError.multipleCalendarsFound: EKCalendar query returned
multiple entities matching title predicate. Specify EKSource.title
parameter for unique resolution.
```

---

## 4. AI-Friendly Design

### Core Principle

**MCP tools should be designed to work seamlessly with AI agents.** This means error messages, return values, and parameter designs should facilitate AI decision-making.

### Implementation Guidelines

#### Error Messages Must Be:

1. **Descriptive**: Explain what went wrong
2. **Actionable**: Explain how to fix it
3. **Complete**: Include all necessary information (available options, etc.)
4. **Parseable**: Use consistent formatting that AI can understand

#### Parameters Should Be:

1. **Optional When Possible**: Don't require information that isn't always needed
2. **Well-Documented**: Clear descriptions in tool schema
3. **Consistent**: Same naming conventions across all tools
4. **Semantic**: Use meaningful names (`calendar_source` not `src`)

### Example: AI Workflow

```
1. User: "Add meeting to 教學課表 tomorrow at 2pm"

2. AI calls: create_event(
     title: "meeting",
     calendar_name: "教學課表",
     start_time: "2026-01-15T14:00:00Z",
     end_time: "2026-01-15T15:00:00Z"
   )

3. MCP returns error:
   "Multiple calendars found with name '教學課表'.
    Available sources: iCloud, Google
    Please specify calendar_source to disambiguate."

4. AI asks user: "您要加到 iCloud 還是 Google 的教學課表？"

5. User: "iCloud"

6. AI retries: create_event(
     title: "meeting",
     calendar_name: "教學課表",
     calendar_source: "iCloud",
     ...
   )

7. Success!
```

---

## 5. Safety by Design

### Core Principle

**Write operations require higher certainty than read operations.** When ambiguity could lead to data being written to the wrong location, the system must stop and ask for clarification.

### Operation Classification

| Operation Type | Ambiguity Handling | Rationale |
|----------------|-------------------|-----------|
| **Read** (list_events, search_events) | Return error, let AI/user decide | Wrong read is recoverable |
| **Write** (create_event, create_reminder) | Return error, require explicit source | Wrong write may be hard to undo |
| **Delete** (delete_event, delete_events_batch) | Return error, require explicit source | Wrong delete may be unrecoverable |
| **Move** (copy_event, move_events_batch) | Return error for target ambiguity | Data could go to wrong calendar |

### Why Not Auto-Select?

For a `create_event` call with ambiguous calendar:

| Approach | Risk |
|----------|------|
| **Auto-select first match** | Event created in wrong calendar, user may not notice |
| **Auto-select by heuristic** | Heuristic may not match user intent |
| **Return error with options** | User/AI explicitly confirms, intent is clear |

---

## 6. Backward Compatibility

### Core Principle

**New features should not break existing workflows.** Users who were successfully using the tool before an update should continue to work without changes.

### Implementation Strategy

1. **New Parameters Are Optional**: `calendar_source` has a default of `nil`
2. **Existing Behavior Preserved**: Single-calendar scenarios work exactly as before
3. **Errors Only When Necessary**: Only trigger disambiguation when actual ambiguity exists
4. **Graceful Degradation**: Old clients calling new server still work

---

## Summary

| Principle | Application in che-ical-mcp |
|-----------|----------------------------|
| Try First, Disambiguate Later | `calendar_source` is optional, only required when ambiguous |
| Reference Resolution | Clear error messages list all available options |
| Natural Language | User-friendly terminology in all messages |
| AI-Friendly Design | Errors contain actionable information for AI retry |
| Safety by Design | Write operations never auto-select ambiguous targets |
| Backward Compatibility | Existing workflows continue to work unchanged |

---

## References

These principles are adapted from the NSQL project:

- [Reference Resolution Rule](../../nsql/reference_resolution_rule.md)
- [Natural Language Rule](../../nsql/natural_language_rule.md)
- [Language Usage Principle](../../nsql/language_usage_principle.md)

---

*Last updated: 2026-01-14 (v0.6.0)*
