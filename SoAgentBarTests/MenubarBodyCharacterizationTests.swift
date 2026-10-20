import XCTest
import AppKit
@testable import SoAgentBar

// MARK: - MenubarBodyCharacterizationTests
//
// SPEC-003 R0 — 구조적 변경(iconSource/buildMenubarBody 추출) 안전망.
// "옳은 동작"이 아니라 "지금 동작"을 고정하는 특성화 테스트다.
//
// RED 확인 방법: 이 파일은 컴파일된다(so-tester가 SoAgentBarApp.swift에 반환값이
// 고정된 임시 스텁을 추가했기 때문). 그러나 스텁은 전부 "틀린 값"을 반환하므로
// 아래 모든 XCTAssertEqual/XCTAssertNotEqual 단정이 실패하는 것이 정상이다.
// Developer가 R0.1~R0.3의 실제 로직을 채워 넣으면 GREEN으로 바뀐다.
//
// 커버 AC: AC1(R0.2 표 10행), AC2, AC34(R0.3 표 4행), AC40

final class MenubarBodyCharacterizationTests: XCTestCase {

    // MARK: - 헬퍼: Agent 빌더 (선례: AgentModeDisplayNameTests.swift:14)

    private func makeAgent(id: String, status: AgentStatus) -> Agent {
        Agent(
            id: id,
            name: "T",
            status: status,
            currentTask: "",
            elapsedSeconds: 0,
            tokensByModel: [:],
            currentModel: "claude-sonnet-4-6",
            sessionID: id,
            projectDir: "/tmp",
            workingPath: "/tmp",
            lastActivity: Date(),
            source: .cli,
            lastResponse: "",
            permissionMode: "default",
            isSubagent: false
        )
    }

    /// 스토어를 만들면 특성화 테스트가 아니라 통합 테스트가 되므로,
    /// 스토어 없는 상수 스텁을 이모지 소스로 쓴다 (arch §6-1).
    private let stubEmoji: (Agent) -> String = { _ in "🐮" }

    // MARK: - AC1 (R0.2 표 10행): buildMenubarBody

    // 행 1 — agents.isEmpty, 임의 스타일, didSetIconImage == true → ""
    func test_buildMenubarBody_emptyAgents_didSetIconImageTrue_returnsEmptyString() {
        let body = AppDelegate.buildMenubarBody(
            agents: [],
            style: .emoji,
            approvalCount: 0,
            didSetIconImage: true,
            emoji: stubEmoji
        )
        XCTAssertEqual(body, "")
    }

    // 행 2 — agents.isEmpty, 임의 스타일, didSetIconImage == false → "🤖"
    func test_buildMenubarBody_emptyAgents_didSetIconImageFalse_returnsRobotEmoji() {
        let body = AppDelegate.buildMenubarBody(
            agents: [],
            style: .countOnly,
            approvalCount: 0,
            didSetIconImage: false,
            emoji: stubEmoji
        )
        XCTAssertEqual(body, "🤖")
    }

    // 행 3 — .emoji, n개 → 앞 4개의 emoji(agent)를 이어붙인 문자열
    func test_buildMenubarBody_emojiStyle_joinsFirstFourEmojisOnly() {
        let agents = (0..<5).map { makeAgent(id: "a\($0)", status: .working) }
        let body = AppDelegate.buildMenubarBody(
            agents: agents,
            style: .emoji,
            approvalCount: 0,
            didSetIconImage: false,
            emoji: stubEmoji
        )
        // 5개 중 앞 4개만 이어붙는다 — 5번째는 잘려야 한다
        XCTAssertEqual(body, "🐮🐮🐮🐮")
    }

    // 행 4 — .emojiCount, 첫 에이전트가 .waitingApproval이 아니고 approvalCount > 0 → "{emoji} {count}❗"
    func test_buildMenubarBody_emojiCountStyle_firstNotWaiting_approvalCountPositive_appendsBadge() {
        let agents = [
            makeAgent(id: "a1", status: .working),
            makeAgent(id: "a2", status: .waitingApproval)
        ]
        let body = AppDelegate.buildMenubarBody(
            agents: agents,
            style: .emojiCount,
            approvalCount: 1,
            didSetIconImage: false,
            emoji: stubEmoji
        )
        XCTAssertEqual(body, "🐮 2❗")
    }

    // 행 5 — .emojiCount, 첫 에이전트가 .waitingApproval → "{emoji} {count}" (뱃지 중복 방지)
    func test_buildMenubarBody_emojiCountStyle_firstIsWaitingApproval_suppressesBadge() {
        let agents = [
            makeAgent(id: "a1", status: .waitingApproval)
        ]
        let body = AppDelegate.buildMenubarBody(
            agents: agents,
            style: .emojiCount,
            approvalCount: 1,
            didSetIconImage: false,
            emoji: stubEmoji
        )
        XCTAssertEqual(body, "🐮 1")
    }

    // AC2 — 첫 에이전트가 .waitingApproval이고 approvalCount == 2일 때도 ❗가 붙지 않는다(중복 방지 보존)
    func test_buildMenubarBody_emojiCountStyle_firstIsWaitingApproval_approvalCountTwo_stillNoBadge() {
        let agents = [
            makeAgent(id: "a1", status: .waitingApproval),
            makeAgent(id: "a2", status: .working)
        ]
        let body = AppDelegate.buildMenubarBody(
            agents: agents,
            style: .emojiCount,
            approvalCount: 2,
            didSetIconImage: false,
            emoji: stubEmoji
        )
        XCTAssertEqual(body, "🐮 2")
        XCTAssertFalse(body.contains("❗"))
    }

    // 행 6 — .emojiCount, approvalCount == 0 → "{emoji} {count}"
    func test_buildMenubarBody_emojiCountStyle_approvalCountZero_noBadge() {
        let agents = [makeAgent(id: "a1", status: .working)]
        let body = AppDelegate.buildMenubarBody(
            agents: agents,
            style: .emojiCount,
            approvalCount: 0,
            didSetIconImage: false,
            emoji: stubEmoji
        )
        XCTAssertEqual(body, "🐮 1")
    }

    // 행 7 — .countOnly, approvalCount > 0 → "{count}❗"
    func test_buildMenubarBody_countOnlyStyle_approvalCountPositive_appendsBadge() {
        let agents = [
            makeAgent(id: "a1", status: .working),
            makeAgent(id: "a2", status: .waitingApproval)
        ]
        let body = AppDelegate.buildMenubarBody(
            agents: agents,
            style: .countOnly,
            approvalCount: 1,
            didSetIconImage: false,
            emoji: stubEmoji
        )
        XCTAssertEqual(body, "2❗")
    }

    // 행 8 — .countOnly, approvalCount == 0 → "{count}"
    func test_buildMenubarBody_countOnlyStyle_approvalCountZero_noBadge() {
        let agents = [makeAgent(id: "a1", status: .working)]
        let body = AppDelegate.buildMenubarBody(
            agents: agents,
            style: .countOnly,
            approvalCount: 0,
            didSetIconImage: false,
            emoji: stubEmoji
        )
        XCTAssertEqual(body, "1")
    }

    // 행 9 — quota 2종, didSetIconImage == true → ""
    func test_buildMenubarBody_quotaSession_nonEmptyAgents_didSetIconImageTrue_returnsEmptyString() {
        let agents = [makeAgent(id: "a1", status: .working)]
        let body = AppDelegate.buildMenubarBody(
            agents: agents,
            style: .quotaSession,
            approvalCount: 0,
            didSetIconImage: true,
            emoji: stubEmoji
        )
        XCTAssertEqual(body, "")
    }

    // 행 10 — quota 2종, didSetIconImage == false → "🤖"
    func test_buildMenubarBody_quotaSessionAndWeekly_nonEmptyAgents_didSetIconImageFalse_returnsRobotEmoji() {
        let agents = [makeAgent(id: "a1", status: .working)]
        let body = AppDelegate.buildMenubarBody(
            agents: agents,
            style: .quotaSessionAndWeekly,
            approvalCount: 0,
            didSetIconImage: false,
            emoji: stubEmoji
        )
        XCTAssertEqual(body, "🤖")
    }

    // MARK: - AC34 (R0.3 표 4행): iconSource(agentsIsEmpty:isQuotaMode:)

    func test_iconSource_emptyAgents_notQuotaMode_returnsLegacyLogo() {
        XCTAssertEqual(
            AppDelegate.iconSource(agentsIsEmpty: true, isQuotaMode: false),
            .legacyLogo
        )
    }

    func test_iconSource_emptyAgents_quotaMode_returnsAnimatedFrame() {
        XCTAssertEqual(
            AppDelegate.iconSource(agentsIsEmpty: true, isQuotaMode: true),
            .animatedFrame
        )
    }

    func test_iconSource_nonEmptyAgents_quotaMode_returnsAnimatedFrame() {
        XCTAssertEqual(
            AppDelegate.iconSource(agentsIsEmpty: false, isQuotaMode: true),
            .animatedFrame
        )
    }

    func test_iconSource_nonEmptyAgents_notQuotaMode_returnsNone() {
        XCTAssertEqual(
            AppDelegate.iconSource(agentsIsEmpty: false, isQuotaMode: false),
            .none
        )
    }

    // MARK: - AC40: quota 경로에는 button.image = nil로 가는 분기가 존재하지 않는다

    func test_iconSource_quotaMode_neverReturnsNone_regardlessOfAgentsEmptiness() {
        for agentsIsEmpty in [true, false] {
            let source = AppDelegate.iconSource(agentsIsEmpty: agentsIsEmpty, isQuotaMode: true)
            XCTAssertNotEqual(
                source, .none,
                "isQuotaMode == true 인데 agentsIsEmpty=\(agentsIsEmpty)에서 .none이 나오면 안 된다"
            )
        }
    }
}
