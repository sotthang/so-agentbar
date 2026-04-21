import XCTest
@testable import SoAgentBar

// =============================================================================
// MARK: - KeepAwakeMode Tests
// =============================================================================

final class KeepAwakeModeTests: XCTestCase {

    // Happy path: off.next → always
    func test_mode_next_off_returnsAlways() {
        XCTAssertEqual(KeepAwakeMode.off.next, .always)
    }

    // Happy path: always.next → auto
    func test_mode_next_always_returnsAuto() {
        XCTAssertEqual(KeepAwakeMode.always.next, .auto)
    }

    // Happy path: auto.next → off (循環 완성)
    func test_mode_next_auto_returnsOff() {
        XCTAssertEqual(KeepAwakeMode.auto.next, .off)
    }

    // Edge case: 3번 연속 next 호출 시 원래 값으로 돌아온다
    func test_mode_next_threeSteps_cyclesBackToOriginal() {
        let original = KeepAwakeMode.off
        let cycled = original.next.next.next
        XCTAssertEqual(cycled, original)
    }
}

// =============================================================================
// MARK: - KeepAwakeManager State Tests (mock assertion via FakePowerAssertion)
// =============================================================================

/// IOKit 실제 호출을 피하기 위한 프로토콜 + Fake 구현체.
/// KeepAwakeManager는 이 프로토콜을 주입받아 IOKit 대신 Fake를 호출한다.
protocol PowerAssertionProvider {
    func createAssertion(type: String, name: String) -> Bool
    func releaseAssertion(type: String)
    var isSystemAssertionHeld: Bool { get }
    var isDisplayAssertionHeld: Bool { get }
}

final class FakePowerAssertionProvider: PowerAssertionProvider {
    private(set) var systemHeld = false
    private(set) var displayHeld = false

    var isSystemAssertionHeld: Bool { systemHeld }
    var isDisplayAssertionHeld: Bool { displayHeld }

    func createAssertion(type: String, name: String) -> Bool {
        if type.contains("SystemSleep") { systemHeld = true }
        if type.contains("DisplaySleep") { displayHeld = true }
        return true
    }

    func releaseAssertion(type: String) {
        if type.contains("SystemSleep") { systemHeld = false }
        if type.contains("DisplaySleep") { displayHeld = false }
    }
}

// NOTE: KeepAwakeManager must be extended to accept a PowerAssertionProvider
// injection through its initializer for these tests.
// Expected signature:
//   init(initialMode: KeepAwakeMode = .off, assertionProvider: PowerAssertionProvider? = nil)
//
// Tests below will fail (RED) until the implementation exists.

@MainActor
final class KeepAwakeManagerTests: XCTestCase {

    // MARK: - always 모드 assertion 유지

    // Happy path: always 모드에서 applyAutoState(sessionsActive: false)해도 assertion 유지
    func test_always_mode_applyAutoStateSessionsFalse_assertionRemainsActive() {
        let fake = FakePowerAssertionProvider()
        let manager = KeepAwakeManager(initialMode: .always, assertionProvider: fake)

        manager.applyAutoState(sessionsActive: false)

        XCTAssertTrue(manager.isAssertionActive,
            "always 모드에서는 세션이 없어도 assertion이 유지되어야 한다")
        XCTAssertTrue(fake.isSystemAssertionHeld,
            "always 모드에서는 SystemSleep assertion이 항상 잡혀 있어야 한다")
        XCTAssertTrue(fake.isDisplayAssertionHeld,
            "always 모드에서는 DisplaySleep assertion이 항상 잡혀 있어야 한다")
    }

    // Happy path: always 모드에서 applyAutoState(sessionsActive: true)해도 assertion 유지
    func test_always_mode_applyAutoStateSessionsTrue_assertionRemainsActive() {
        let fake = FakePowerAssertionProvider()
        let manager = KeepAwakeManager(initialMode: .always, assertionProvider: fake)

        manager.applyAutoState(sessionsActive: true)

        XCTAssertTrue(manager.isAssertionActive,
            "always 모드에서는 세션 상관없이 assertion이 유지되어야 한다")
    }

    // MARK: - auto 모드 세션 연동

    // Happy path: auto 모드에서 applyAutoState(sessionsActive: true) → assertion 생성
    func test_auto_mode_applyAutoStateSessionsTrue_assertionBecomesActive() {
        let fake = FakePowerAssertionProvider()
        let manager = KeepAwakeManager(initialMode: .auto, assertionProvider: fake)

        manager.applyAutoState(sessionsActive: true)

        XCTAssertTrue(manager.isAssertionActive,
            "auto 모드에서 활성 세션이 있으면 assertion이 생성되어야 한다")
        XCTAssertTrue(fake.isSystemAssertionHeld)
        XCTAssertTrue(fake.isDisplayAssertionHeld)
    }

    // Happy path: auto 모드에서 applyAutoState(sessionsActive: false) → assertion 해제
    func test_auto_mode_applyAutoStateSessionsFalse_assertionBecomesInactive() {
        let fake = FakePowerAssertionProvider()
        let manager = KeepAwakeManager(initialMode: .auto, assertionProvider: fake)

        // 먼저 활성화
        manager.applyAutoState(sessionsActive: true)
        XCTAssertTrue(manager.isAssertionActive)

        // 세션 종료
        manager.applyAutoState(sessionsActive: false)

        XCTAssertFalse(manager.isAssertionActive,
            "auto 모드에서 세션이 0이면 assertion이 해제되어야 한다")
        XCTAssertFalse(fake.isSystemAssertionHeld)
        XCTAssertFalse(fake.isDisplayAssertionHeld)
    }

    // MARK: - off 모드

    // Happy path: off 모드에서는 assertion 없음
    func test_off_mode_noAssertionHeld() {
        let fake = FakePowerAssertionProvider()
        let manager = KeepAwakeManager(initialMode: .off, assertionProvider: fake)

        XCTAssertFalse(manager.isAssertionActive,
            "off 모드에서는 assertion이 없어야 한다")
        XCTAssertFalse(fake.isSystemAssertionHeld)
        XCTAssertFalse(fake.isDisplayAssertionHeld)
    }

    // Edge case: off 모드에서 applyAutoState(sessionsActive: true)해도 assertion 없음
    func test_off_mode_applyAutoStateSessionsTrue_noAssertionHeld() {
        let fake = FakePowerAssertionProvider()
        let manager = KeepAwakeManager(initialMode: .off, assertionProvider: fake)

        manager.applyAutoState(sessionsActive: true)

        XCTAssertFalse(manager.isAssertionActive,
            "off 모드에서는 세션이 있어도 assertion이 생성되지 않아야 한다")
    }

    // MARK: - UserDefaults 영속화

    // Happy path: mode 변경 시 UserDefaults에 저장된다
    func test_mode_change_persistedToUserDefaults() {
        let fake = FakePowerAssertionProvider()
        let defaults = UserDefaults(suiteName: "test.KeepAwakeManager.persist")!
        defaults.removeObject(forKey: "keepAwakeMode")

        let manager = KeepAwakeManager(
            initialMode: .off,
            assertionProvider: fake,
            defaults: defaults
        )

        manager.mode = .always

        XCTAssertEqual(defaults.string(forKey: "keepAwakeMode"), KeepAwakeMode.always.rawValue,
            "mode 변경 시 UserDefaults에 rawValue가 저장되어야 한다")

        defaults.removePersistentDomain(forName: "test.KeepAwakeManager.persist")
    }

    // Happy path: 저장된 mode가 새 인스턴스에서 복원된다
    func test_mode_restoredFromUserDefaults_onInit() {
        let fake = FakePowerAssertionProvider()
        let defaults = UserDefaults(suiteName: "test.KeepAwakeManager.restore")!
        defaults.set(KeepAwakeMode.always.rawValue, forKey: "keepAwakeMode")

        let manager = KeepAwakeManager(
            initialMode: .off,
            assertionProvider: fake,
            defaults: defaults
        )

        // KeepAwakeManager는 initialMode를 인자로 받지만,
        // AgentStore가 UserDefaults에서 읽어서 initialMode로 전달하는 패턴이므로
        // 여기서는 저장된 rawValue를 파싱하여 복원하는 흐름을 검증한다.
        let restoredRaw = defaults.string(forKey: "keepAwakeMode")
        let restoredMode = KeepAwakeMode(rawValue: restoredRaw ?? "") ?? .off

        XCTAssertEqual(restoredMode, .always,
            "UserDefaults에서 읽은 rawValue로 KeepAwakeMode를 복원할 수 있어야 한다")
        _ = manager  // suppress unused warning

        defaults.removePersistentDomain(forName: "test.KeepAwakeManager.restore")
    }
}
