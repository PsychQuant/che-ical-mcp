import Foundation
import XCTest
@testable import CheICalMCP

/// #304: the `*_local` strings and the other fixed-pattern output dates were formatted by a
/// `DateFormatter` with a pattern and a zone but no locale, so the host locale decided the year
/// (its calendar: Buddhist 2569, ROC 0115, Japanese 0008, Islamic 1448) and the digits (Arabic-Indic
/// under `ar_SA`). `DateFormatter.machineReadable` sets `en_US_POSIX` and the Gregorian calendar.
///
/// A test process cannot change `Locale.current`, so the host's choice is stood in for by
/// `hostDefault`: a formatter carrying the locale a host would hand out. The helper must override it.
final class MachineReadableDateFormatTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    /// 2026-10-10T09:30:00+08:00.
    private let instant = Date(timeIntervalSince1970: 1_791_595_800)
    private let pattern = "yyyy-MM-dd'T'HH:mm:ss"

    private func hostFormatter(_ locale: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        return formatter
    }

    func testInstantIsTheOneTheTestsMean() {
        XCTAssertEqual(ISO8601DateFormatter().string(from: instant), "2026-10-10T01:30:00Z")
    }

    /// The host locales the issue measured, plus one with Arabic-Indic digits.
    func testOutputIsGregorianWithASCIIDigitsWhateverTheHostLocale() {
        for locale in ["en_US@calendar=buddhist", "zh_TW@calendar=roc", "ja_JP@calendar=japanese",
                       "ar_SA", "ar_EG", "fa_IR", "en_US", "zh_TW"] {
            let formatter = DateFormatter.machineReadable(pattern, zone: taipei, hostDefault: hostFormatter(locale))
            XCTAssertEqual(formatter.string(from: instant), "2026-10-10T09:30:00", locale)
        }
    }

    /// The control: the same pattern on the host's formatter, as the formatters were written
    /// before #304, prints another year or other digits.
    func testWithoutTheHelperTheHostLocaleLeaksIn() {
        func old(_ locale: String) -> String {
            let formatter = hostFormatter(locale)
            formatter.dateFormat = pattern
            formatter.timeZone = taipei
            return formatter.string(from: instant)
        }
        XCTAssertEqual(old("en_US@calendar=buddhist"), "2569-10-10T09:30:00")
        XCTAssertFalse(old("ar_SA").unicodeScalars.allSatisfy(\.isASCII), old("ar_SA"))
    }

    /// A Gregorian calendar alone fixes the year but not the digits; the locale is what matters.
    func testTheLocaleIsWhatMakesTheDigitsASCII() {
        let formatter = hostFormatter("ar_SA")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = pattern
        formatter.timeZone = taipei
        XCTAssertFalse(formatter.string(from: instant).unicodeScalars.allSatisfy(\.isASCII))
    }

    func testTheHelperSetsLocaleCalendarZoneAndPattern() {
        let formatter = DateFormatter.machineReadable("HH:mm:ss", zone: taipei)
        XCTAssertEqual(formatter.locale.identifier, "en_US_POSIX")
        XCTAssertEqual(formatter.calendar.identifier, .gregorian)
        XCTAssertEqual(formatter.timeZone, taipei)
        XCTAssertEqual(formatter.dateFormat, "HH:mm:ss")
        XCTAssertEqual(formatter.string(from: instant), "09:30:00")
    }

    // MARK: - Source pin: every DateFormatter() sets en_US_POSIX

    /// Every `DateFormatter()` built in `Sources/` sets `en_US_POSIX` within the five lines after it
    /// (the helper, the input parser, `lstartFormatter`, `formatExclusionDay`). New output formatters
    /// go through `DateFormatter.machineReadable`.
    func testEveryDateFormatterInSourcesSetsPOSIX() throws {
        var offenders: [String] = []
        for file in try SourceScan.swiftFiles() {
            let code = SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8))
            offenders += Self.formattersWithoutPOSIX(in: code).map { "\(file.lastPathComponent):\($0)" }
        }
        XCTAssertEqual(offenders, [], "DateFormatter() without en_US_POSIX; use DateFormatter.machineReadable")
    }

    /// The pin's own rule, on fixtures.
    func testThePinRule() {
        XCTAssertEqual(Self.formattersWithoutPOSIX(in: "let f = DateFormatter()\nf.dateFormat = \"yyyy\"\n"), [1])
        XCTAssertEqual(Self.formattersWithoutPOSIX(in: "let f = DateFormatter()\nf.locale = Locale(identifier: \"en_US_POSIX\")\n"), [])
        XCTAssertEqual(Self.formattersWithoutPOSIX(in: "let f = ISO8601DateFormatter()\n"), [])
        XCTAssertEqual(Self.formattersWithoutPOSIX(in: "x\nlet f = DateFormatter()\n1\n2\n3\n4\n5\nf.locale = Locale(identifier: \"en_US_POSIX\")\n"), [2],
                       "POSIX set more than five lines later does not count")
    }

    /// 1-based line numbers of `DateFormatter()` constructions not followed by `en_US_POSIX` on the
    /// same line or within the five lines after it. `ISO8601DateFormatter()` is not matched.
    static func formattersWithoutPOSIX(in code: String) -> [Int] {
        let lines = code.components(separatedBy: "\n")
        let construction = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])DateFormatter\(\)"#)
        return lines.indices.compactMap { index in
            let line = lines[index]
            guard construction.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { return nil }
            let window = lines[index..<min(lines.count, index + 6)].joined(separator: "\n")
            return window.contains("Locale(identifier: \"en_US_POSIX\")") ? nil : index + 1
        }
    }
}
