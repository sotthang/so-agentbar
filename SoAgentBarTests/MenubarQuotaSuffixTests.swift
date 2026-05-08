import XCTest
import AppKit
@testable import SoAgentBar

@MainActor  // AppDelegate가 @MainActor라서 정적 메서드도 동일 격리 대응
final class MenubarQuotaSuffixTests: XCTestCase {

    // MARK: - AC1: buildQuotaSuffix

    func test_buildQuotaSuffix_withNilUsage_sessionOnly_returnsEmptyString() {
        XCTAssertEqual(AppDelegate.buildQuotaSuffix(util: nil, mode: .quotaSession), "")
    }

    func test_buildQuotaSuffix_withNilUsage_sessionAndWeekly_returnsEmptyString() {
        XCTAssertEqual(AppDelegate.buildQuotaSuffix(util: nil, mode: .quotaSessionAndWeekly), "")
    }

    func test_buildQuotaSuffix_sessionOnly_formatsCorrectly() {
        let s = AppDelegate.buildQuotaSuffix(util: (45, 72), mode: .quotaSession)
        XCTAssertEqual(s, "S45%")
    }

    func test_buildQuotaSuffix_sessionAndWeekly_formatsCorrectly() {
        let s = AppDelegate.buildQuotaSuffix(util: (45, 72), mode: .quotaSessionAndWeekly)
        XCTAssertEqual(s, "S45%/W72%")
    }

    func test_buildQuotaSuffix_truncatesFractionalPart() {
        // Int(45.9) == 45
        let s1 = AppDelegate.buildQuotaSuffix(util: (45.9, 0), mode: .quotaSession)
        XCTAssertEqual(s1, "S45%")
        let s2 = AppDelegate.buildQuotaSuffix(util: (45.9, 0), mode: .quotaSessionAndWeekly)
        XCTAssertEqual(s2, "S45%/W0%")
    }

    func test_buildQuotaSuffix_zeroUtil_isDisplayed() {
        let s = AppDelegate.buildQuotaSuffix(util: (0, 0), mode: .quotaSessionAndWeekly)
        XCTAssertEqual(s, "S0%/W0%")
    }

    func test_buildQuotaSuffix_emojiMode_returnsEmptyString() {
        let s = AppDelegate.buildQuotaSuffix(util: (45, 72), mode: .emoji)
        XCTAssertEqual(s, "")
    }

    func test_buildQuotaSuffix_emojiCountMode_returnsEmptyString() {
        let s = AppDelegate.buildQuotaSuffix(util: (45, 72), mode: .emojiCount)
        XCTAssertEqual(s, "")
    }

    // MARK: - AC2: buildMenubarAttributedTitle 색상

    func test_buildMenubarAttributedTitle_emptySuffix_bodyOnlyWithLabelColor() {
        let attr = AppDelegate.buildMenubarAttributedTitle(
            body: "🤖 3", suffix: "", sessionUtil: nil, weeklyUtil: nil, threshold: 80
        )
        XCTAssertEqual(attr.string, "🤖 3")
        // body 전체가 labelColor
        let color = attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .labelColor)
    }

    func test_buildMenubarAttributedTitle_sessionBelowThreshold_weeklyAbove_onlyWeeklyIsRed() {
        // body="🤖 3", suffix=" S30%/W85%", threshold=80
        // S30 → labelColor, W85 → systemRed
        let attr = AppDelegate.buildMenubarAttributedTitle(
            body: "🤖 3", suffix: " S30%/W85%",
            sessionUtil: 30, weeklyUtil: 85, threshold: 80
        )
        XCTAssertEqual(attr.string, "🤖 3 S30%/W85%")
        XCTAssertTrue(hasColor(attr, .labelColor, in: "S30%"))
        XCTAssertTrue(hasColor(attr, .systemRed,  in: "W85%"))
    }

    func test_buildMenubarAttributedTitle_sessionAboveThreshold_sessionIsRed() {
        let attr = AppDelegate.buildMenubarAttributedTitle(
            body: "🤖 3", suffix: " S90%",
            sessionUtil: 90, weeklyUtil: nil, threshold: 80
        )
        XCTAssertTrue(hasColor(attr, .systemRed, in: "S90%"))
    }

    func test_buildMenubarAttributedTitle_boundaryEqualThreshold_isRed() {
        // >= 비교 검증: 80 >= 80 → red
        let attr = AppDelegate.buildMenubarAttributedTitle(
            body: "🤖 3", suffix: " S80%/W80%",
            sessionUtil: 80, weeklyUtil: 80, threshold: 80
        )
        XCTAssertTrue(hasColor(attr, .systemRed, in: "S80%"))
        XCTAssertTrue(hasColor(attr, .systemRed, in: "W80%"))
    }

    func test_buildMenubarAttributedTitle_belowThreshold_allLabelColor() {
        let attr = AppDelegate.buildMenubarAttributedTitle(
            body: "🤖 3", suffix: " S79%",
            sessionUtil: 79, weeklyUtil: nil, threshold: 80
        )
        XCTAssertTrue(hasColor(attr, .labelColor, in: "S79%"))
        XCTAssertTrue(hasColor(attr, .labelColor, in: "🤖 3"))
    }

    // MARK: - 헬퍼

    /// attributed string 안에서 substring 범위의 첫 글자 색상이 expected와 같은지 검사.
    private func hasColor(_ attr: NSAttributedString, _ expected: NSColor, in substring: String) -> Bool {
        let nsString = attr.string as NSString
        let range = nsString.range(of: substring)
        guard range.location != NSNotFound else { return false }
        guard let color = attr.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor else {
            return false
        }
        return color == expected
    }
}
