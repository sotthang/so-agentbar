import XCTest
import SpriteKit
@testable import SoAgentBar

// =============================================================================
// MARK: - Phase D RED Tests
// TDD RED phase — AC8 / AC9 / AC13 대응
//
// Coverage:
//   AC13 — AgentStore.systemMetricsMonitor 프로퍼티 존재 + init 시 start() 즉시 호출
//   AC8  — agents 비어있어도 isPixelWindowVisible=true 이면 창이 보여야 함
//          (PixelAgentsWindowController.bindToStore()의 !agents.isEmpty 조건 제거 검증)
//   AC9  — isPixelWindowVisible=false 시 scene.pauseSystemPets() 호출
//          (systemPets 노드 hasActions() == false)
// =============================================================================

// MARK: - AC13: AgentStore.systemMetricsMonitor 즉시 폴링 시작

final class AgentStoreSystemMetricsMonitorTests: XCTestCase {

    private var store: AgentStore!

    override func setUp() {
        super.setUp()
        store = AgentStore()
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    // AC13: AgentStore는 systemMetricsMonitor 프로퍼티를 보유한다
    // 이 테스트는 프로퍼티가 없으면 컴파일 에러로 실패한다
    @MainActor
    func test_agentStore_hasSystemMetricsMonitorProperty() {
        // Given / When
        let monitor = store.systemMetricsMonitor

        // Then: 프로퍼티가 존재하면 nil이 아니어야 한다
        XCTAssertNotNil(monitor,
                        "AC13: AgentStore는 systemMetricsMonitor 프로퍼티를 갖고 있어야 한다")
    }

    // AC13: AgentStore init 직후 systemMetricsMonitor.metrics 가 nil이 아니다
    // (init에서 start()를 즉시 호출하기 때문에 첫 번째 샘플이 채워져야 한다)
    @MainActor
    func test_agentStore_init_systemMetricsMonitor_metricsIsNotNil() {
        // Given: AgentStore가 생성됨 (setUp에서)

        // When: 별도 start() 호출 없음 — init에서 이미 호출되어야 함

        // Then: metrics가 nil이 아니어야 한다
        XCTAssertNotNil(store.systemMetricsMonitor.metrics,
                        "AC13: AgentStore init 후 systemMetricsMonitor.metrics가 채워져야 한다 (init에서 start() 즉시 호출)")
    }

    // AC13: 동일 인스턴스인지 확인 (computed property가 아닌 stored property)
    @MainActor
    func test_agentStore_systemMetricsMonitor_isSameInstance() {
        // Given / When
        let m1 = store.systemMetricsMonitor
        let m2 = store.systemMetricsMonitor

        // Then: 매번 같은 인스턴스여야 한다 (computed property로 새 인스턴스 생성하면 안 됨)
        XCTAssertTrue(m1 === m2,
                      "AC13: systemMetricsMonitor는 매번 동일 인스턴스를 반환해야 한다")
    }

    // AC13: systemMetricsMonitor는 SystemMetricsMonitor 타입이다
    @MainActor
    func test_agentStore_systemMetricsMonitor_isCorrectType() {
        // Given / When
        let monitor = store.systemMetricsMonitor

        // Then
        XCTAssertTrue(monitor is SystemMetricsMonitor,
                      "AC13: systemMetricsMonitor는 SystemMetricsMonitor 타입이어야 한다")
    }
}

// MARK: - AC8: agents 0개여도 isPixelWindowVisible=true 이면 창 노출
// AC8는 bindToStore()의 !agents.isEmpty 조건 제거를 동작으로 검증한다.
// NSWindow를 실제로 띄우지 않고, bindToStore() 로직을 검증한다.
// 구체적으로: WindowController를 생성하고 store.isPixelWindowVisible=true, store.agents=[]
// 상태에서 window.isVisible 또는 controller 내부 상태를 검증한다.

final class PixelAgentsWindowControllerBindingTests: XCTestCase {

    // 테스트에서 AgentStore를 생성할 때 UserDefaults를 정리한다
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "isPixelWindowVisible")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "isPixelWindowVisible")
        super.tearDown()
    }

    // AC8: agents가 비어있어도 isPixelWindowVisible=true → showWindow()가 호출되어야 한다
    // 검증 방식: window.isVisible 상태 또는 isPixelWindowVisible=true + agents=[] 조합에서
    // window.orderFront()가 호출되는지 확인
    // 기존 코드: "if visible && !agents.isEmpty" → 변경 후: "if visible"
    @MainActor
    func test_windowController_bindToStore_emptyAgents_pixelVisible_showsWindow() {
        // Given
        let store = AgentStore()
        store.agents = []

        // When: isPixelWindowVisible=true로 설정하면 창이 보여야 한다
        store.isPixelWindowVisible = true

        let controller = PixelAgentsWindowController(store: store)

        // Combine publisher가 RunLoop.main에서 동작하므로 현재 runloop를 돌린다
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Then: agents가 없어도 visible=true면 창이 표시되어야 한다 (AC8)
        // 기존 코드(if visible && !agents.isEmpty)에서는 agents=[]이면 hide됨
        XCTAssertTrue(
            controller.window?.isVisible ?? false,
            "AC8: agents가 없어도 isPixelWindowVisible=true면 창이 표시되어야 한다. " +
            "bindToStore()에서 !agents.isEmpty 조건이 제거됐는지 검증"
        )
    }

    // AC8: agents가 있을 때도 visible=true면 창이 보인다 (기존 동작 유지 확인)
    @MainActor
    func test_windowController_bindToStore_withAgents_pixelVisible_showsWindow() {
        // Given
        let store = AgentStore()
        store.isPixelWindowVisible = true

        let agent = Agent(
            id: "test-agent",
            name: "Test",
            status: .idle,
            currentTask: "",
            elapsedSeconds: 0,
            tokensByModel: [:],
            currentModel: "claude-sonnet-4-6",
            sessionID: "test-agent",
            projectDir: "/tmp",
            workingPath: "/tmp",
            lastActivity: Date(),
            source: .cli,
            lastResponse: "",
            permissionMode: "default",
            isSubagent: false
        )
        store.agents = [agent]

        let controller = PixelAgentsWindowController(store: store)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Then
        XCTAssertTrue(
            controller.window?.isVisible ?? false,
            "agents가 있고 isPixelWindowVisible=true면 창이 표시되어야 한다"
        )
    }

    // AC8: isPixelWindowVisible=false면 agents 유무에 관계없이 창이 숨겨진다
    @MainActor
    func test_windowController_bindToStore_pixelInvisible_hidesWindow() {
        // Given
        let store = AgentStore()
        store.isPixelWindowVisible = false
        store.agents = []

        let controller = PixelAgentsWindowController(store: store)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Then
        XCTAssertFalse(
            controller.window?.isVisible ?? false,
            "isPixelWindowVisible=false면 창이 숨겨져야 한다"
        )
    }
}

// MARK: - AC9: isPixelWindowVisible=false 시 scene의 펫 노드 액션 중지

final class PixelAgentsWindowControllerPauseTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "isPixelWindowVisible")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "isPixelWindowVisible")
        super.tearDown()
    }

    // AC9: isPixelWindowVisible=false → scene.pauseSystemPets() 호출
    // 검증: PixelAgentsWindowController의 scene을 접근하여 systemPets 노드 상태 확인
    // 단, scene에 대한 외부 접근자가 없으면 이 테스트는 컴파일 에러로 실패한다
    // → PixelAgentsWindowController에 internal var scene 노출이 필요할 수 있음
    @MainActor
    func test_windowController_pixelInvisible_pausesSystemPets() {
        // Given: 창을 먼저 visible=true로 열었다가
        let store = AgentStore()
        store.isPixelWindowVisible = true
        store.agents = []

        let controller = PixelAgentsWindowController(store: store)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // When: isPixelWindowVisible=false로 변경
        store.isPixelWindowVisible = false
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Then: scene의 모든 systemPets 노드가 액션 중지 상태여야 한다 (AC9)
        // PixelAgentsWindowController.scene은 internal 접근자가 필요하다
        let scene = controller.pixelScene  // 테스트 접근자: controller.pixelScene
        for (kind, petNode) in scene.systemPets {
            XCTAssertFalse(
                petNode.hasActions(),
                "AC9: isPixelWindowVisible=false 후 \(kind) pet 노드의 hasActions()는 false여야 한다"
            )
        }
    }

    // AC9: isPixelWindowVisible=false → 창이 숨겨진다 (hideWindow 호출)
    @MainActor
    func test_windowController_pixelInvisible_hidesWindow() {
        // Given
        let store = AgentStore()
        store.isPixelWindowVisible = true
        store.agents = []

        let controller = PixelAgentsWindowController(store: store)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // When
        store.isPixelWindowVisible = false
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Then
        XCTAssertFalse(
            controller.window?.isVisible ?? false,
            "AC9: isPixelWindowVisible=false 후 창이 숨겨져야 한다"
        )
    }

    // AC9: visible=true → false → true 사이클에서 창이 정상적으로 show/hide 된다
    @MainActor
    func test_windowController_pixelVisible_toggle_showsAndHides() {
        // Given
        let store = AgentStore()
        store.isPixelWindowVisible = false
        store.agents = []

        let controller = PixelAgentsWindowController(store: store)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(controller.window?.isVisible ?? false, "초기: false")

        // When: true로 전환
        store.isPixelWindowVisible = true
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(controller.window?.isVisible ?? false, "true 전환 후: visible")

        // When: false로 다시 전환
        store.isPixelWindowVisible = false
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(controller.window?.isVisible ?? false, "false 재전환 후: hidden")
    }
}

// MARK: - PixelAgentsWindowController.pixelScene 접근자 요구사항 문서화
// 위 테스트 중 `controller.pixelScene`을 사용하는 테스트는
// PixelAgentsWindowController에 아래 접근자가 추가되어야 통과한다:
//
//   /// 테스트 전용 scene 접근자.
//   var pixelScene: PixelAgentsScene { scene }
//
// Developer에게 이 API 추가가 필요함을 명시.
