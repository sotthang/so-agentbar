import XCTest
@testable import SoAgentBar

// 첫 실행 시 "자동 업데이트를 켤까요?" 창을 띄울지 판단하는 로직 검증.
// 한 번 물어본 뒤에는 다시 묻지 않아야 한다 (사용자 선택은 설정에서 변경).
@MainActor
final class AutoUpdatePromptTests: XCTestCase {

    // Happy path: 아직 물어본 적 없으면 첫 실행 프롬프트를 띄워야 한다
    func test_shouldAsk_whenNeverPrompted_returnsTrue() {
        let suiteName = "test.AutoUpdatePrompt.fresh"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        XCTAssertTrue(
            AppDelegate.shouldAskAutomaticUpdatesPermission(defaults: defaults),
            "한 번도 물어본 적 없으면 첫 실행 프롬프트를 띄워야 한다")

        defaults.removePersistentDomain(forName: suiteName)
    }

    // Edge case: 이미 물어봤으면 다시 띄우지 않는다
    func test_shouldAsk_whenAlreadyPrompted_returnsFalse() {
        let suiteName = "test.AutoUpdatePrompt.asked"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: AppDelegate.didAskAutomaticUpdatesKey)

        XCTAssertFalse(
            AppDelegate.shouldAskAutomaticUpdatesPermission(defaults: defaults),
            "이미 물어봤으면 프롬프트를 다시 띄우면 안 된다")

        defaults.removePersistentDomain(forName: suiteName)
    }
}
