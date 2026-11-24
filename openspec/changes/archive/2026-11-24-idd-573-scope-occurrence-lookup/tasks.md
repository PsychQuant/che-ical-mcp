<!-- No [P]: every task ends in a build or a test run under the shared build lock. -->

## 1. Lookup (pure, `OccurrenceLookup.swift`)

- [x] 1.1 `OccurrenceLookup.find`, `dayReadings` and `scope` with the query injected; the window and selection moved unchanged. Verify: `OccurrenceLookupTests` (two calendars, recorded scopes, equality with the query of every calendar, unknown calendar).

## 2. Wiring (`EventKitManager`)

- [x] 2.1 `findOccurrence` and `dayReadings` take a calendar with no default and query through `enumerateDayWindow`; each of the eight calls passes the object named in the Diagnosis. Verify: `OccurrenceLookupWiringTests` red on `main`, green after; pins quoting the old text rewritten.

## 3. Texts

- [x] 3.1 `CHANGELOG.md` `[Unreleased]` Changed entry; release-gate note for non-iCloud sources in the rules file.

## 4. Proof

- [x] 4.1 Full `swift test` in three zones; removed and rewritten tests listed; mutants (nil at each call, the move's target calendar, the scope dropped).
