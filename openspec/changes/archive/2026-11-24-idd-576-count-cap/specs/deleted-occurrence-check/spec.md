## ADDED Requirements

### Requirement: Expansion cap of the deleted-occurrence check

The deleted-occurrence check SHALL expand a series' rule from its first slot to the end of the listing taking at most 20,000 slots. When a 20,001st slot of the rule is inside the expanded range, the expansion SHALL answer too many and the check SHALL answer unknown (more occurrences than the check expands), whether the rule is open, ends at a date, or is counted; for a counted rule this SHALL hold also when the 20,001st slot is its last (#576). A rule with 20,000 slots or fewer in range SHALL expand to all of them.

#### Scenario: A count of 20,001 is capped like an open rule

- **GIVEN** a daily rule counted at 20,001 occurrences, and a range past all of them
- **WHEN** the check expands it
- **THEN** the expansion answers too many, as it does for an open daily rule and for a count of 20,002 over the same range

#### Scenario: A count at the cap expands

- **GIVEN** a daily rule counted at 20,000 (or 19,999) occurrences, and a range past all of them
- **WHEN** the check expands it
- **THEN** the expansion returns all 20,000 (or 19,999) slots

#### Scenario: The verdict refuses past the cap

- **GIVEN** a daily rule counted at 20,001 occurrences, every slot listed and none edited, the listing covering the whole series
- **WHEN** the check decides
- **THEN** it answers unknown because the rule gives more occurrences than the check expands
