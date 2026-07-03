import XCTest
import AppKit
@testable import SoAgentBar

// LSUIElement(.accessory) 메뉴바 앱은 기본 Edit 메뉴가 없어서
// 팝오버 안 TextEditor에서 Cmd+C/V/X/A 단축키가 first responder에
// 전달되지 않는다. AppDelegate.buildEditMenu()가 표준 편집 메뉴를
// 구성하여 단축키 라우팅을 복원하는지 검증한다.
@MainActor
final class EditMenuTests: XCTestCase {

    // Happy path: 표준 편집 항목(Cut/Copy/Paste/Select All)이 모두 존재
    func test_buildEditMenu_containsStandardEditingItems() {
        let menu = AppDelegate.buildEditMenu()
        let actions = menu.items.compactMap { $0.action }

        XCTAssertTrue(actions.contains(#selector(NSText.cut(_:))),
            "Edit 메뉴에 Cut 항목이 있어야 한다")
        XCTAssertTrue(actions.contains(#selector(NSText.copy(_:))),
            "Edit 메뉴에 Copy 항목이 있어야 한다")
        XCTAssertTrue(actions.contains(#selector(NSText.paste(_:))),
            "Edit 메뉴에 Paste 항목이 있어야 한다")
        XCTAssertTrue(actions.contains(#selector(NSText.selectAll(_:))),
            "Edit 메뉴에 Select All 항목이 있어야 한다")
    }

    // Copy 항목이 Cmd+C 단축키를 갖는다 (단축키 라우팅의 핵심)
    func test_buildEditMenu_copyItem_hasCommandCKeyEquivalent() {
        let menu = AppDelegate.buildEditMenu()
        let copyItem = menu.items.first { $0.action == #selector(NSText.copy(_:)) }

        XCTAssertNotNil(copyItem)
        XCTAssertEqual(copyItem?.keyEquivalent, "c",
            "Copy 항목의 key equivalent는 'c'여야 한다")
        XCTAssertEqual(copyItem?.keyEquivalentModifierMask, [.command],
            "Copy 항목의 modifier는 Command여야 한다")
    }

    // Paste 항목이 Cmd+V 단축키를 갖는다
    func test_buildEditMenu_pasteItem_hasCommandVKeyEquivalent() {
        let menu = AppDelegate.buildEditMenu()
        let pasteItem = menu.items.first { $0.action == #selector(NSText.paste(_:)) }

        XCTAssertEqual(pasteItem?.keyEquivalent, "v",
            "Paste 항목의 key equivalent는 'v'여야 한다")
        XCTAssertEqual(pasteItem?.keyEquivalentModifierMask, [.command],
            "Paste 항목의 modifier는 Command여야 한다")
    }

    // Select All 항목이 Cmd+A 단축키를 갖는다
    func test_buildEditMenu_selectAllItem_hasCommandAKeyEquivalent() {
        let menu = AppDelegate.buildEditMenu()
        let selectAllItem = menu.items.first { $0.action == #selector(NSText.selectAll(_:)) }

        XCTAssertEqual(selectAllItem?.keyEquivalent, "a",
            "Select All 항목의 key equivalent는 'a'여야 한다")
        XCTAssertEqual(selectAllItem?.keyEquivalentModifierMask, [.command],
            "Select All 항목의 modifier는 Command여야 한다")
    }
}
