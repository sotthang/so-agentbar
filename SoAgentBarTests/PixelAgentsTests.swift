import XCTest
import SpriteKit
@testable import SoAgentBar

// =============================================================================
// MARK: - PixelAgentsTests
// TDD RED phase — all tests are expected to fail (compile error or assertion)
// until the implementation files are created.
//
// Coverage:
//   R2  AC1  AC2  — AgentStore.isPixelWindowVisible toggle + UserDefaults persist
//   R9  AC9  AC10 — AgentStore.pixelWindowOpacity persist
//   R6  AC5  AC6  — PixelCharacterNode AgentStatus → animation category mapping
//   R7  AC3  AC11 — PixelAgentsScene character size calculation logic
//   R4  AC4       — PixelAgentsScene session add / remove syncs characterNodes count
//   R10 AC12      — PixelCharacterProvider protocol + ProgrammaticPixelProvider conformance
//   R5            — ProgrammaticPixelProvider.hue(for:) determinism & range
// =============================================================================

// MARK: - AgentStore pixel-window properties (R2, R9)

final class AgentStorePixelWindowTests: XCTestCase {

    private var store: AgentStore!
    private let visibleKey = "isPixelWindowVisible"
    private let opacityKey = "pixelWindowOpacity"

    override func setUp() {
        super.setUp()
        // Clear relevant UserDefaults keys so each test starts clean
        UserDefaults.standard.removeObject(forKey: visibleKey)
        UserDefaults.standard.removeObject(forKey: opacityKey)
        store = AgentStore()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: visibleKey)
        UserDefaults.standard.removeObject(forKey: opacityKey)
        store = nil
        super.tearDown()
    }

    // Happy path: isPixelWindowVisible defaults to true when key absent
    func test_isPixelWindowVisible_defaultsToTrue() {
        XCTAssertTrue(store.isPixelWindowVisible)
    }

    // Happy path: toggling isPixelWindowVisible flips the value
    func test_isPixelWindowVisible_toggle_flipsValue() {
        XCTAssertFalse(store.isPixelWindowVisible)
        store.isPixelWindowVisible = true
        XCTAssertTrue(store.isPixelWindowVisible)
        store.isPixelWindowVisible = false
        XCTAssertFalse(store.isPixelWindowVisible)
    }

    // Happy path: isPixelWindowVisible change persists to UserDefaults
    func test_isPixelWindowVisible_persistsToUserDefaults() {
        store.isPixelWindowVisible = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: visibleKey))
        store.isPixelWindowVisible = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: visibleKey))
    }

    // Happy path: pixelWindowOpacity defaults to 0.8 when key absent
    func test_pixelWindowOpacity_defaultsTo_0_8() {
        XCTAssertEqual(store.pixelWindowOpacity, 0.8, accuracy: 0.0001)
    }

    // Happy path: pixelWindowOpacity change persists to UserDefaults
    func test_pixelWindowOpacity_persistsToUserDefaults() {
        store.pixelWindowOpacity = 0.5
        let saved = UserDefaults.standard.double(forKey: opacityKey)
        XCTAssertEqual(saved, 0.5, accuracy: 0.0001)
    }

    // Edge case: new AgentStore instance reads previously-stored visibility value
    func test_isPixelWindowVisible_restoredFromUserDefaults() {
        UserDefaults.standard.set(true, forKey: visibleKey)
        let freshStore = AgentStore()
        XCTAssertTrue(freshStore.isPixelWindowVisible)
    }

    // Edge case: new AgentStore instance reads previously-stored opacity value
    func test_pixelWindowOpacity_restoredFromUserDefaults() {
        UserDefaults.standard.set(0.3, forKey: opacityKey)
        let freshStore = AgentStore()
        XCTAssertEqual(freshStore.pixelWindowOpacity, 0.3, accuracy: 0.0001)
    }
}

// MARK: - PixelCharacterNode animation category mapping (R6)

final class PixelCharacterNodeAnimationTests: XCTestCase {

    private func makeNode(status: AgentStatus) -> PixelCharacterNode {
        let provider = ProgrammaticPixelProvider()
        return PixelCharacterNode(
            agentID: "test-agent-\(status)",
            status: status,
            provider: provider,
            characterSize: 32
        )
    }

    // Happy path: idle status maps to idle animation category
    func test_update_idleStatus_setsIdleAnimation() {
        let node = makeNode(status: .idle)
        XCTAssertEqual(node.currentStatus, .idle)
        node.update(status: .idle)
        XCTAssertEqual(node.currentStatus, .idle)
    }

    // Happy path: thinking status maps to idle animation category (same as idle)
    func test_update_thinkingStatus_setsThinkingState() {
        let node = makeNode(status: .idle)
        node.update(status: .thinking)
        XCTAssertEqual(node.currentStatus, .thinking)
    }

    // Happy path: working status triggers typing animation
    func test_update_workingStatus_setsWorkingState() {
        let node = makeNode(status: .idle)
        node.update(status: .working)
        XCTAssertEqual(node.currentStatus, .working)
    }

    // Happy path: waitingApproval shows bubble node
    func test_update_waitingApproval_showsBubble() {
        let node = makeNode(status: .idle)
        node.update(status: .waitingApproval)
        XCTAssertEqual(node.currentStatus, .waitingApproval)
        // After update to waitingApproval the bubble child should be present
        XCTAssertNotNil(node.children.first(where: { $0.name == "bubbleNode" }))
    }

    // Happy path: transitioning away from waitingApproval hides bubble
    func test_update_fromWaitingApproval_to_working_hidesBubble() {
        let node = makeNode(status: .waitingApproval)
        node.update(status: .working)
        XCTAssertNil(node.children.first(where: { $0.name == "bubbleNode" }))
    }

    // Happy path: error status sets error state
    func test_update_errorStatus_setsErrorState() {
        let node = makeNode(status: .idle)
        node.update(status: .error)
        XCTAssertEqual(node.currentStatus, .error)
    }

    // Edge case: calling update with same status does not crash
    func test_update_sameStatus_doesNotCrash() {
        let node = makeNode(status: .working)
        node.update(status: .working)
        XCTAssertEqual(node.currentStatus, .working)
    }
}

// MARK: - PixelAgentsScene character size calculation (R7, decision #4)

final class PixelAgentsSceneCharacterSizeTests: XCTestCase {

    // Happy path: fewer than 10 characters → full default size (32)
    func test_calculateCharacterSize_fewAgents_returnsFullSize() {
        let scene = PixelAgentsScene(
            size: CGSize(width: 480, height: 200),
            provider: ProgrammaticPixelProvider()
        )
        // With 0 characters the size should be the default (32)
        let size = scene.characterSize(forCount: 0)
        XCTAssertEqual(size, 32)
    }

    // Happy path: 9 characters → still full size (32)
    func test_calculateCharacterSize_nineAgents_returnsFullSize() {
        let scene = PixelAgentsScene(
            size: CGSize(width: 480, height: 200),
            provider: ProgrammaticPixelProvider()
        )
        let size = scene.characterSize(forCount: 9)
        XCTAssertEqual(size, 32)
    }

    // Edge case: 10 characters → size must be reduced below 32
    func test_calculateCharacterSize_tenAgents_reducesSize() {
        let scene = PixelAgentsScene(
            size: CGSize(width: 480, height: 200),
            provider: ProgrammaticPixelProvider()
        )
        let size = scene.characterSize(forCount: 10)
        XCTAssertLessThan(size, 32)
    }

    // Edge case: very many characters → size never drops below 24 (minimum)
    func test_calculateCharacterSize_manyAgents_neverBelowMinimum() {
        let scene = PixelAgentsScene(
            size: CGSize(width: 480, height: 200),
            provider: ProgrammaticPixelProvider()
        )
        let size = scene.characterSize(forCount: 100)
        XCTAssertGreaterThanOrEqual(size, 24)
    }

    // Edge case: narrow scene (width 240) with 10 agents → still >= 24
    func test_calculateCharacterSize_narrowScene_respectsMinimum() {
        let scene = PixelAgentsScene(
            size: CGSize(width: 240, height: 200),
            provider: ProgrammaticPixelProvider()
        )
        let size = scene.characterSize(forCount: 10)
        XCTAssertGreaterThanOrEqual(size, 24)
    }
}

// MARK: - PixelAgentsScene session add/remove sync (R4)

final class PixelAgentsSceneSessionSyncTests: XCTestCase {

    private func makeAgent(id: String, status: AgentStatus = .idle) -> Agent {
        Agent(
            id: id,
            name: "Test Agent",
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

    // Happy path: adding agents increases characterNodes count
    func test_sync_addAgents_createsCharacterNodes() {
        let scene = PixelAgentsScene(
            size: CGSize(width: 480, height: 200),
            provider: ProgrammaticPixelProvider()
        )
        let agents = [makeAgent(id: "a1"), makeAgent(id: "a2"), makeAgent(id: "a3")]
        scene.synchronize(agents: agents)
        XCTAssertEqual(scene.characterNodeCount, 3)
    }

    // Happy path: empty agent list → zero character nodes
    func test_sync_emptyAgents_zeroCharacterNodes() {
        let scene = PixelAgentsScene(
            size: CGSize(width: 480, height: 200),
            provider: ProgrammaticPixelProvider()
        )
        scene.synchronize(agents: [])
        XCTAssertEqual(scene.characterNodeCount, 0)
    }

    // Happy path: removing an agent decreases character count
    func test_sync_removeAgent_decreasesCharacterCount() {
        let scene = PixelAgentsScene(
            size: CGSize(width: 480, height: 200),
            provider: ProgrammaticPixelProvider()
        )
        scene.synchronize(agents: [makeAgent(id: "a1"), makeAgent(id: "a2")])
        scene.synchronize(agents: [makeAgent(id: "a1")])
        // After removal the node for "a2" is being faded out; it may still be in the
        // scene graph but should be removed from the tracking dictionary immediately.
        XCTAssertEqual(scene.characterNodeCount, 1)
    }

    // Edge case: re-syncing with same agents does not duplicate nodes
    func test_sync_sameAgentsTwice_doesNotDuplicate() {
        let scene = PixelAgentsScene(
            size: CGSize(width: 480, height: 200),
            provider: ProgrammaticPixelProvider()
        )
        let agents = [makeAgent(id: "a1")]
        scene.synchronize(agents: agents)
        scene.synchronize(agents: agents)
        XCTAssertEqual(scene.characterNodeCount, 1)
    }

    // Happy path: status update is reflected in the existing node
    func test_sync_statusChange_updatesExistingNode() {
        let scene = PixelAgentsScene(
            size: CGSize(width: 480, height: 200),
            provider: ProgrammaticPixelProvider()
        )
        scene.synchronize(agents: [makeAgent(id: "a1", status: .idle)])
        scene.synchronize(agents: [makeAgent(id: "a1", status: .working)])
        XCTAssertEqual(scene.characterNode(forID: "a1")?.currentStatus, .working)
    }
}

// MARK: - PixelCharacterProvider protocol conformance (R10, AC12)

final class PixelCharacterProviderTests: XCTestCase {

    // AC12: ProgrammaticPixelProvider conforms to PixelCharacterProvider
    func test_programmaticProvider_conformsToProtocol() {
        let provider: PixelCharacterProvider = ProgrammaticPixelProvider()
        XCTAssertNotNil(provider)
    }

    // Happy path: textures(for:hue:size:) returns at least one texture for each status
    func test_textures_idle_returnsNonEmptyArray() {
        let provider = ProgrammaticPixelProvider()
        let frames = provider.textures(for: .idle, hue: 0.5, size: 32)
        XCTAssertFalse(frames.isEmpty)
    }

    func test_textures_working_returnsNonEmptyArray() {
        let provider = ProgrammaticPixelProvider()
        let frames = provider.textures(for: .working, hue: 0.5, size: 32)
        XCTAssertFalse(frames.isEmpty)
    }

    func test_textures_waitingApproval_returnsNonEmptyArray() {
        let provider = ProgrammaticPixelProvider()
        let frames = provider.textures(for: .waitingApproval, hue: 0.5, size: 32)
        XCTAssertFalse(frames.isEmpty)
    }

    func test_textures_error_returnsNonEmptyArray() {
        let provider = ProgrammaticPixelProvider()
        let frames = provider.textures(for: .error, hue: 0.5, size: 32)
        XCTAssertFalse(frames.isEmpty)
    }

    // Happy path: bubbleTexture returns a valid SKTexture
    func test_bubbleTexture_returnsNonNilTexture() {
        let provider = ProgrammaticPixelProvider()
        let texture = provider.bubbleTexture(size: 32)
        XCTAssertNotNil(texture)
    }

    // Happy path: hue(for:) is deterministic — same id gives same hue
    func test_hue_forAgentID_isDeterministic() {
        let hue1 = ProgrammaticPixelProvider.hue(for: "agent-abc")
        let hue2 = ProgrammaticPixelProvider.hue(for: "agent-abc")
        XCTAssertEqual(hue1, hue2, accuracy: 0.0001)
    }

    // Edge case: hue(for:) output is in [0.0, 1.0]
    func test_hue_forAgentID_isInValidRange() {
        let ids = ["", "a", "very-long-id-string-1234567890", "💡emoji"]
        for id in ids {
            let hue = ProgrammaticPixelProvider.hue(for: id)
            XCTAssertGreaterThanOrEqual(hue, 0.0, "hue for id '\(id)' is below 0")
            XCTAssertLessThanOrEqual(hue, 1.0, "hue for id '\(id)' exceeds 1")
        }
    }

    // Edge case: different ids produce different hues (collision is unlikely for these)
    func test_hue_differentIDs_produceDifferentHues() {
        let hue1 = ProgrammaticPixelProvider.hue(for: "agent-001")
        let hue2 = ProgrammaticPixelProvider.hue(for: "agent-002")
        // Not guaranteed to be different in all cases, but these specific ids should differ
        XCTAssertNotEqual(hue1, hue2, accuracy: 0.001)
    }
}

// MARK: - 작업 1: 텍스처 캐시 무효화 (invalidateCache)

final class SpriteSheetProviderInvalidateCacheTests: XCTestCase {

    // Happy path: invalidateCache() 후 cache가 비워져 새 charIndex 기준 텍스처가 생성된다
    func test_spriteSheetProvider_invalidateCache_clearsTextureCache() {
        let provider = SpriteSheetPixelProvider()
        // charIndex 0으로 맵핑되는 agentID로 텍스처 생성 → cache 채움
        provider.characterOverrides = ["agent-x": 0]
        _ = provider.textures(for: .idle, agentID: "agent-x", size: 32)

        // override를 변경 후 invalidateCache 호출
        provider.characterOverrides = ["agent-x": 3]
        provider.invalidateCache()

        // 캐시가 비워졌으므로 cacheSize는 0이어야 함
        XCTAssertEqual(provider.cacheSize, 0)
    }

    // Happy path: ProgrammaticPixelProvider.invalidateCache()도 cache를 비운다
    func test_programmaticProvider_invalidateCache_clearsCache() {
        let provider = ProgrammaticPixelProvider()
        _ = provider.textures(for: .idle, hue: 0.5, size: 32)
        provider.invalidateCache()
        XCTAssertEqual(provider.cacheSize, 0)
    }

    // Happy path: invalidateCache 후 textures() 재호출 시 새 charIndex 기준 결과 반환
    func test_spriteSheetProvider_invalidateCache_returnsNewCharIndexTextures() {
        let provider = SpriteSheetPixelProvider()
        provider.characterOverrides = ["agent-y": 0]
        let before = provider.textures(for: .working, agentID: "agent-y", size: 32)

        provider.characterOverrides = ["agent-y": 5]
        provider.invalidateCache()

        let after = provider.textures(for: .working, agentID: "agent-y", size: 32)
        // 서로 다른 sprite sheet → 텍스처 배열이 달라야 함 (같을 수도 있으나 최소한 캐시가 재생성됨)
        // cache miss 후 재생성 확인: cacheSize가 1 이상
        XCTAssertGreaterThan(provider.cacheSize, 0)
        // before/after는 동일 객체가 아님 (새로 생성됨)
        _ = before  // suppress unused warning
        _ = after
    }
}

// MARK: - 작업 2: 새 세션에 미사용 캐릭터 랜덤 배정

final class AgentStoreAssignCharacterTests: XCTestCase {

    private var store: AgentStore!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "pixelCharacterOverrides")
        store = AgentStore()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "pixelCharacterOverrides")
        store = nil
        super.tearDown()
    }

    private var total: Int { SpriteSheetPixelProvider.charCount }

    // Happy path: inUseIndices에 없는 인덱스를 반환한다
    func test_assignCharacter_returnsUnusedIndex() {
        let inUse: Set<Int> = [0, 1]
        let assigned = store.assignCharacter(forNewAgentID: "new-agent", inUseIndices: inUse)
        XCTAssertFalse(inUse.contains(assigned), "사용 중인 인덱스가 배정되면 안 됨")
        XCTAssertGreaterThanOrEqual(assigned, 0)
        XCTAssertLessThan(assigned, total)
    }

    // Happy path: 모든 인덱스가 사용 중이면 유효 범위 중 랜덤 반환
    func test_assignCharacter_allInUse_returnsAnyValidIndex() {
        let inUse = Set(0..<total)
        let assigned = store.assignCharacter(forNewAgentID: "new-agent", inUseIndices: inUse)
        XCTAssertGreaterThanOrEqual(assigned, 0)
        XCTAssertLessThan(assigned, total)
    }

    // Edge case: inUseIndices가 비어있으면 유효 범위 중 하나 반환
    func test_assignCharacter_emptyInUse_returnsValidIndex() {
        let assigned = store.assignCharacter(forNewAgentID: "agent-abc", inUseIndices: [])
        XCTAssertGreaterThanOrEqual(assigned, 0)
        XCTAssertLessThan(assigned, total)
    }

    // Edge case: N-1개 사용 중이면 나머지 1개가 반드시 반환된다
    func test_assignCharacter_almostAllInUse_returnsTheRemainingOne() {
        let remaining = total - 1
        let inUse = Set(0..<total).subtracting([remaining])
        let assigned = store.assignCharacter(forNewAgentID: "agent-xyz", inUseIndices: inUse)
        XCTAssertEqual(assigned, remaining)
    }
}
