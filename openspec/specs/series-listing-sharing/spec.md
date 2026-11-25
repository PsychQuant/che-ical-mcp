# series-listing-sharing Specification

## Purpose

Which readers of update_event share one listing of a series (#527, #533).

## Requirements

### Requirement: update_event lists a series once for the #509 first slot and the #503 baseline

When `update_event` reads the first slot of a series for the #509 rule-end check and the #503 deleted-occurrence baseline reads the same series over the same calendar and ranges, the server SHALL list the series once and SHALL give both readers that listing. Its answer, refusals and writes SHALL be those it gave when it listed twice, as long as the store does not change between the two reads. No refresh, save, write or suspension SHALL fall between two readers of one shared listing.

#### Scenario: A weekly series with an end, moved to a new time through its id

- **WHEN** `update_event` is called with the series' id, span `all` and a new `start_time` on a weekly series with an `end_date`
- **THEN** the series is listed once for the #509 first slot and the #503 baseline, and the response is the one the call gave before

##### Example: listings by call shape

| #509 reads the first slot | #503 baseline runs | Verdict ranges | Listings before | Listings now |
|---|---|---|---|---|
| yes | yes | the baseline's | 2 | 1 |
| yes | yes | #506's window of its own | 3 | 2 |
| yes | no | none | 1 | 1 |
| no | yes | the baseline's | 1 | 1 |
