import XCTest
@testable import SoAgentBar

// =============================================================================
// MARK: - NSPasteboard 추상화 프로토콜 (테스트용)
// =============================================================================

/// NSPasteboard를 직접 사용하지 않고 프로토콜로 추상화.
/// ClipboardMonitor는 이 프로토콜을 주입받아 실제 pasteboard 대신 Fake를 사용한다.
protocol PasteboardProviding {
    var changeCount: Int { get }
    func string() -> String?
    func write(_ text: String)
    func isConcealedType() -> Bool
}

final class FakePasteboardProvider: PasteboardProviding {
    private(set) var changeCount: Int = 0
    private var storedString: String? = nil
    var concealed: Bool = false

    func string() -> String? { storedString }

    func write(_ text: String) {
        storedString = text
        changeCount += 1
    }

    /// 테스트에서 외부에서 changeCount를 올릴 때 사용 (다른 앱이 복사한 상황 모사)
    func simulateCopy(_ text: String) {
        storedString = text
        changeCount += 1
    }

    func isConcealedType() -> Bool { concealed }
}

// NOTE: ClipboardMonitor must expose:
//   init(pasteboardProvider: PasteboardProviding, defaults: UserDefaults)
//   internal func ingest(text: String)   ← 직접 호출 가능해야 함 (internal 또는 @testable)
//
// Tests below will fail (RED) until the implementation exists.

@MainActor
final class ClipboardMonitorTests: XCTestCase {

    // MARK: - ingest(text:) 기본 동작

    // Happy path: 신규 텍스트 ingest → history 맨 앞에 추가
    func test_ingest_newText_isInsertedAtFront() {
        let pb = FakePasteboardProvider()
        let defaults = UserDefaults(suiteName: "test.ClipboardMonitor.newText")!
        defaults.removeObject(forKey: "clipboardHistory")
        let monitor = ClipboardMonitor(pasteboardProvider: pb, defaults: defaults)

        monitor.ingest(text: "hello")

        XCTAssertEqual(monitor.history.first?.text, "hello",
            "ingest한 텍스트가 history 맨 앞에 위치해야 한다")
        XCTAssertEqual(monitor.history.count, 1)

        defaults.removePersistentDomain(forName: "test.ClipboardMonitor.newText")
    }

    // Happy path: 여러 텍스트 ingest 시 가장 최근 것이 맨 앞
    func test_ingest_multipleTexts_latestIsAtFront() {
        let pb = FakePasteboardProvider()
        let defaults = UserDefaults(suiteName: "test.ClipboardMonitor.multiple")!
        defaults.removeObject(forKey: "clipboardHistory")
        let monitor = ClipboardMonitor(pasteboardProvider: pb, defaults: defaults)

        monitor.ingest(text: "first")
        monitor.ingest(text: "second")

        XCTAssertEqual(monitor.history.first?.text, "second",
            "마지막으로 ingest한 텍스트가 history 맨 앞에 있어야 한다")
        XCTAssertEqual(monitor.history.count, 2)

        defaults.removePersistentDomain(forName: "test.ClipboardMonitor.multiple")
    }

    // Happy path: 중복 텍스트 ingest → 기존 항목 제거 후 맨 앞으로 이동
    func test_ingest_duplicateText_movesToFront_noDuplicate() {
        let pb = FakePasteboardProvider()
        let defaults = UserDefaults(suiteName: "test.ClipboardMonitor.duplicate")!
        defaults.removeObject(forKey: "clipboardHistory")
        let monitor = ClipboardMonitor(pasteboardProvider: pb, defaults: defaults)

        monitor.ingest(text: "alpha")
        monitor.ingest(text: "beta")
        monitor.ingest(text: "alpha")   // 중복

        XCTAssertEqual(monitor.history.count, 2,
            "중복 텍스트는 별도로 추가되지 않고 하나만 존재해야 한다")
        XCTAssertEqual(monitor.history.first?.text, "alpha",
            "중복 ingest 시 기존 위치 제거 후 맨 앞으로 이동해야 한다")
        XCTAssertEqual(monitor.history.last?.text, "beta")

        defaults.removePersistentDomain(forName: "test.ClipboardMonitor.duplicate")
    }

    // Edge case: 20개 초과 시 가장 오래된 항목(마지막) 제거
    func test_ingest_exceedsMaxEntries_removesOldest() {
        let pb = FakePasteboardProvider()
        let defaults = UserDefaults(suiteName: "test.ClipboardMonitor.maxEntries")!
        defaults.removeObject(forKey: "clipboardHistory")
        let monitor = ClipboardMonitor(pasteboardProvider: pb, defaults: defaults)

        for i in 1...21 {
            monitor.ingest(text: "item\(i)")
        }

        XCTAssertEqual(monitor.history.count, ClipboardMonitor.maxEntries,
            "최대 \(ClipboardMonitor.maxEntries)개를 초과하면 가장 오래된 항목이 제거되어야 한다")
        XCTAssertEqual(monitor.history.first?.text, "item21",
            "가장 최근에 ingest한 항목이 맨 앞에 있어야 한다")
        XCTAssertFalse(monitor.history.contains { $0.text == "item1" },
            "가장 오래된 항목(item1)은 제거되어야 한다")

        defaults.removePersistentDomain(forName: "test.ClipboardMonitor.maxEntries")
    }

    // Edge case: 정확히 20개 ingest 시 모두 유지
    func test_ingest_exactlyMaxEntries_allRetained() {
        let pb = FakePasteboardProvider()
        let defaults = UserDefaults(suiteName: "test.ClipboardMonitor.exact20")!
        defaults.removeObject(forKey: "clipboardHistory")
        let monitor = ClipboardMonitor(pasteboardProvider: pb, defaults: defaults)

        for i in 1...20 {
            monitor.ingest(text: "item\(i)")
        }

        XCTAssertEqual(monitor.history.count, ClipboardMonitor.maxEntries,
            "정확히 20개면 모두 유지되어야 한다")

        defaults.removePersistentDomain(forName: "test.ClipboardMonitor.exact20")
    }

    // Error case: 빈 문자열 ingest → 무시
    func test_ingest_emptyString_isIgnored() {
        let pb = FakePasteboardProvider()
        let defaults = UserDefaults(suiteName: "test.ClipboardMonitor.empty")!
        defaults.removeObject(forKey: "clipboardHistory")
        let monitor = ClipboardMonitor(pasteboardProvider: pb, defaults: defaults)

        monitor.ingest(text: "")

        XCTAssertTrue(monitor.history.isEmpty,
            "빈 문자열은 history에 추가되지 않아야 한다")

        defaults.removePersistentDomain(forName: "test.ClipboardMonitor.empty")
    }

    // Error case: 공백만 있는 문자열은 저장될 수 있다 (빈 문자열과 다름)
    func test_ingest_whitespaceOnlyString_isIngested() {
        let pb = FakePasteboardProvider()
        let defaults = UserDefaults(suiteName: "test.ClipboardMonitor.whitespace")!
        defaults.removeObject(forKey: "clipboardHistory")
        let monitor = ClipboardMonitor(pasteboardProvider: pb, defaults: defaults)

        monitor.ingest(text: "   ")

        XCTAssertEqual(monitor.history.count, 1,
            "공백만 있는 문자열은 빈 문자열이 아니므로 저장되어야 한다")

        defaults.removePersistentDomain(forName: "test.ClipboardMonitor.whitespace")
    }

    // MARK: - clearAll()

    // Happy path: clearAll() 호출 → history 비워짐
    func test_clearAll_emptyHistory() {
        let pb = FakePasteboardProvider()
        let defaults = UserDefaults(suiteName: "test.ClipboardMonitor.clearAll")!
        defaults.removeObject(forKey: "clipboardHistory")
        let monitor = ClipboardMonitor(pasteboardProvider: pb, defaults: defaults)

        monitor.ingest(text: "foo")
        monitor.ingest(text: "bar")
        XCTAssertEqual(monitor.history.count, 2)

        monitor.clearAll()

        XCTAssertTrue(monitor.history.isEmpty,
            "clearAll() 후 history가 비어 있어야 한다")

        defaults.removePersistentDomain(forName: "test.ClipboardMonitor.clearAll")
    }

    // Edge case: 이미 빈 history에 clearAll() → 크래시 없이 no-op
    func test_clearAll_onEmptyHistory_doesNotCrash() {
        let pb = FakePasteboardProvider()
        let defaults = UserDefaults(suiteName: "test.ClipboardMonitor.clearAllEmpty")!
        defaults.removeObject(forKey: "clipboardHistory")
        let monitor = ClipboardMonitor(pasteboardProvider: pb, defaults: defaults)

        monitor.clearAll()

        XCTAssertTrue(monitor.history.isEmpty)

        defaults.removePersistentDomain(forName: "test.ClipboardMonitor.clearAllEmpty")
    }

    // MARK: - UserDefaults 영속화

    // Happy path: ingest 후 새 인스턴스 생성 시 history가 복원된다
    func test_persistence_historyRestoredOnNewInstance() {
        let suiteName = "test.ClipboardMonitor.persistence"
        let pb = FakePasteboardProvider()
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removeObject(forKey: "clipboardHistory")

        // 첫 번째 인스턴스: 항목 추가
        let monitor1 = ClipboardMonitor(pasteboardProvider: pb, defaults: defaults)
        monitor1.ingest(text: "persistent text")

        // 두 번째 인스턴스: 같은 UserDefaults suite에서 로드
        let monitor2 = ClipboardMonitor(pasteboardProvider: pb, defaults: defaults)

        XCTAssertEqual(monitor2.history.first?.text, "persistent text",
            "새 인스턴스 생성 시 UserDefaults에서 history가 복원되어야 한다")
        XCTAssertEqual(monitor2.history.count, 1)

        defaults.removePersistentDomain(forName: suiteName)
    }

    // Happy path: clearAll() 후 새 인스턴스에서도 history가 비어 있다
    func test_persistence_afterClearAll_newInstanceHasEmptyHistory() {
        let suiteName = "test.ClipboardMonitor.persistClear"
        let pb = FakePasteboardProvider()
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removeObject(forKey: "clipboardHistory")

        let monitor1 = ClipboardMonitor(pasteboardProvider: pb, defaults: defaults)
        monitor1.ingest(text: "temporary")
        monitor1.clearAll()

        let monitor2 = ClipboardMonitor(pasteboardProvider: pb, defaults: defaults)

        XCTAssertTrue(monitor2.history.isEmpty,
            "clearAll() 후 새 인스턴스에서도 history가 비어 있어야 한다")

        defaults.removePersistentDomain(forName: suiteName)
    }
}
