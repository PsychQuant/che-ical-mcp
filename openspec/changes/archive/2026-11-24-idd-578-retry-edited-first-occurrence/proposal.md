## Problem

A recurring `create_event` retry over a series whose first occurrence was edited on its own answered with the occurrence's identifier (`<series id>/RID=` and digits) when no exclusions were checked, and, when that first occurrence was retitled, matched nothing and created a second series (#578; measured on `main` `88e5158a`, iCloud, 2026-11-24).

## Root Cause

`createEvent` takes the event the duplicate lookup (`findDuplicateEvent`: title, the 30-second window, calendar, timed or all-day) returns as the existing series. #544 checked the series only on the path with exclusions; the fall-through return answers the match's identifier, and a retitled first occurrence is not a title match.

## Proposed Solution

- `CreateRetryIdentity.answeredSeries` (pure): for a recurring request, the series' identifier when `ExclusionRetryTarget.resolve` (unchanged) takes the series; otherwise nil, keeping `main`'s answer. A raise in the series lookup reads as nil.
- `CreateRetryIdentity.retitledFirstOccurrence` (pure): for a recurring request whose title lookup missed, the first window event of the same kind that `resolve` takes for a series with the requested title; `createEvent` then throws `createRetryRetitledFirstOccurrence`, writing nothing.
- `createEvent`: one shared request and series read (`retrySeriesFacts`) for #544 and #578; the window read factored into `startWindowEvents`.

## Non-Goals

- #585: a first occurrence moved off the requested start (not in the window).
- Answering `skipped` over a retitled first occurrence: the default taken is the refusal (Choice Default Record on #578); flipping it changes one branch and its text.
- One-off requests and other matches: unchanged.

## Success Criteria

- Pure tests of both functions; wiring pins; handler tests of the refusal.
- Device (iCloud, `--cli`, signed release builds of the head and of `main`, `#578` calendars): the shapes of the Diagnosis, the other-series shapes unchanged.

## Capabilities

### New Capabilities

- `create-retry-edited-first-occurrence`: what a recurring create retry answers over the series' edited first occurrence.

### Modified Capabilities

- `recurrence-excluded-dates`: the retitled first occurrence sentence points to the new capability.

## Impact

- Affected specs: `create-retry-edited-first-occurrence` (new), `recurrence-excluded-dates`
- Affected code: `Sources/CheICalMCP/EventKit/CreateRetryIdentity.swift` (new), `Sources/CheICalMCP/EventKit/EventKitManager.swift`, `Sources/CheICalMCP/Server.swift` (descriptions), tests, `CHANGELOG.md`, README files, `.claude/rules/mcp-binary-version-testing.md`
