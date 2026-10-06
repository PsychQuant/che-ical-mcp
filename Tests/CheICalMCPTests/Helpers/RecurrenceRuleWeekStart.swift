import EventKit
import XCTest

/// #253 verify round 2 (11): EventKit has no public setter for a rule's week start, so the
/// tests set it the way `RecurrenceRuleSnapshot.rebuild` writes it back: through the run-time
/// setter, behind the same `responds(to:)` check. Where the setter is missing, or ignored, the
/// test is skipped rather than aborting the run with an undefined-key exception.
func setWeekStart(_ day: Int, on rule: EKRecurrenceRule) throws {
    guard rule.responds(to: NSSelectorFromString("setFirstDayOfTheWeek:")) else {
        throw XCTSkip("EKRecurrenceRule has no week-start setter on this macOS")
    }
    rule.setValue(day, forKey: "firstDayOfTheWeek")
    guard rule.firstDayOfTheWeek == day else {
        throw XCTSkip("EKRecurrenceRule ignores the week-start setter on this macOS")
    }
}
