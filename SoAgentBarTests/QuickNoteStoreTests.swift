import XCTest
import Combine
@testable import SoAgentBar

// NOTE: QuickNoteStore must expose:
//   init(defaults: UserDefaults)
//   @Published var content: String
//   func flush()
//
// Tests below will fail (RED) until the implementation exists.

@MainActor
final class QuickNoteStoreTests: XCTestCase {

    // MARK: - 초기 로드

    // Happy path: UserDefaults에 저장된 값이 init 시 복원된다
    func test_init_loadsContentFromUserDefaults() {
        let suiteName = "test.QuickNoteStore.load"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("saved note content", forKey: "quickNoteContent")

        let store = QuickNoteStore(defaults: defaults)

        XCTAssertEqual(store.content, "saved note content",
            "init 시 UserDefaults의 quickNoteContent 값이 content에 복원되어야 한다")

        defaults.removePersistentDomain(forName: suiteName)
    }

    // Edge case: UserDefaults에 값이 없을 때 content는 빈 문자열
    func test_init_noStoredValue_contentIsEmpty() {
        let suiteName = "test.QuickNoteStore.empty"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removeObject(forKey: "quickNoteContent")

        let store = QuickNoteStore(defaults: defaults)

        XCTAssertEqual(store.content, "",
            "저장된 값이 없으면 content는 빈 문자열이어야 한다")

        defaults.removePersistentDomain(forName: suiteName)
    }

    // Happy path: 빈 문자열 저장 가능
    func test_content_emptyString_canBeSaved() {
        let suiteName = "test.QuickNoteStore.saveEmpty"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("some old text", forKey: "quickNoteContent")

        let store = QuickNoteStore(defaults: defaults)
        store.content = ""
        store.flush()

        XCTAssertEqual(defaults.string(forKey: "quickNoteContent"), "",
            "빈 문자열도 UserDefaults에 저장될 수 있어야 한다")

        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - flush() 즉시 저장

    // Happy path: flush() 호출 시 content가 즉시 UserDefaults에 저장된다
    func test_flush_persistsContentImmediately() {
        let suiteName = "test.QuickNoteStore.flush"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removeObject(forKey: "quickNoteContent")

        let store = QuickNoteStore(defaults: defaults)
        store.content = "important note"

        // debounce 대기 없이 즉시 flush
        store.flush()

        XCTAssertEqual(defaults.string(forKey: "quickNoteContent"), "important note",
            "flush() 호출 시 content가 즉시 저장되어야 한다")

        defaults.removePersistentDomain(forName: suiteName)
    }

    // Edge case: flush()를 여러 번 호출해도 마지막 content 값이 저장된다
    func test_flush_calledMultipleTimes_lastContentIsSaved() {
        let suiteName = "test.QuickNoteStore.multiFlush"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removeObject(forKey: "quickNoteContent")

        let store = QuickNoteStore(defaults: defaults)
        store.content = "first"
        store.flush()
        store.content = "second"
        store.flush()

        XCTAssertEqual(defaults.string(forKey: "quickNoteContent"), "second",
            "여러 번 flush() 호출 시 마지막 content 값이 저장되어야 한다")

        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - debounce 자동 저장

    // Happy path: content 변경 후 500ms 이상 경과 시 UserDefaults에 저장된다
    func test_content_change_afterDebounce_isSavedToUserDefaults() {
        let suiteName = "test.QuickNoteStore.debounce"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removeObject(forKey: "quickNoteContent")

        let store = QuickNoteStore(defaults: defaults)

        let expectation = XCTestExpectation(description: "debounce 후 UserDefaults 저장")

        var cancellable: AnyCancellable?
        cancellable = store.$content
            .dropFirst()            // 초기값 스킵
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak defaults] _ in
                if defaults?.string(forKey: "quickNoteContent") == "debounced text" {
                    expectation.fulfill()
                }
                cancellable?.cancel()
            }

        store.content = "debounced text"

        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(defaults.string(forKey: "quickNoteContent"), "debounced text",
            "content 변경 후 debounce 시간이 지나면 UserDefaults에 저장되어야 한다")

        defaults.removePersistentDomain(forName: suiteName)
    }

    // Edge case: 빠르게 연속 입력 시 debounce가 묶어서 마지막 값만 저장한다
    func test_content_rapidChanges_debouncesSavesToLastValue() {
        let suiteName = "test.QuickNoteStore.rapidDebounce"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removeObject(forKey: "quickNoteContent")

        let store = QuickNoteStore(defaults: defaults)

        // debounce 전에 값 확인 (저장 안 되어 있어야 함)
        store.content = "a"
        store.content = "ab"
        store.content = "abc"

        // debounce 전에는 마지막 값이 아직 저장되지 않을 수 있다
        // (또는 이전 값이 저장될 수 있으므로 flush로 강제 저장)
        store.flush()

        XCTAssertEqual(defaults.string(forKey: "quickNoteContent"), "abc",
            "연속 변경 후 flush() 시 최종 content인 'abc'가 저장되어야 한다")

        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 재시작 시 복원 (round-trip)

    // Happy path: flush 후 새 인스턴스를 생성하면 content가 복원된다
    func test_roundTrip_flushAndRestore() {
        let suiteName = "test.QuickNoteStore.roundTrip"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removeObject(forKey: "quickNoteContent")

        let store1 = QuickNoteStore(defaults: defaults)
        store1.content = "my important note"
        store1.flush()

        let store2 = QuickNoteStore(defaults: defaults)

        XCTAssertEqual(store2.content, "my important note",
            "flush 후 새 인스턴스에서 content가 복원되어야 한다")

        defaults.removePersistentDomain(forName: suiteName)
    }

    // Happy path: 긴 텍스트도 저장/복원된다
    func test_roundTrip_longContent_persistedAndRestored() {
        let suiteName = "test.QuickNoteStore.longText"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removeObject(forKey: "quickNoteContent")

        let longText = String(repeating: "가나다라마바사아자차카타파하 ", count: 200)
        let store1 = QuickNoteStore(defaults: defaults)
        store1.content = longText
        store1.flush()

        let store2 = QuickNoteStore(defaults: defaults)

        XCTAssertEqual(store2.content, longText,
            "긴 텍스트도 저장 후 새 인스턴스에서 정확히 복원되어야 한다")

        defaults.removePersistentDomain(forName: suiteName)
    }
}
