import XCTest
import SpriteKit
@testable import SoAgentBar

// =============================================================================
// MARK: - SystemPetSceneTests
// TDD RED phase — Phase C (Scene 통합) 테스트
//
// Coverage:
//   AC3  — applyMetrics: Disk 변경 시 CPU/Memory pet 속도 불변
//   AC4  — CPU pet은 restWanderBounds 내부에서만 wander (startCPUWandering 연동)
//   AC5  — Memory pet forceZoneHop: 씬 통합 환경에서 position/lastZoneVisited 검증
//   AC10 — characterNodeCount는 systemPets 수를 포함하지 않는다
//   AC14 — Memory pet position이 memoryPetForbiddenRects 안에 없다
//
//   + spawnSystemPetsIfNeeded 멱등성
//   + applyMetrics 올바른 펫에 지표 전달
//   + pauseSystemPets / resumeSystemPets (선택적)
// =============================================================================

// MARK: - 헬퍼

private func makeScene() -> PixelAgentsScene {
    PixelAgentsScene(
        size: CGSize(width: 420, height: 560),
        provider: SpriteSheetPixelProvider()
    )
}

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

// MARK: - spawnSystemPetsIfNeeded 멱등성 테스트

final class SystemPetSceneSpawnTests: XCTestCase {

    // Happy path: spawnSystemPetsIfNeeded 첫 호출 → CPU pet + Memory pet 2마리 추가
    func test_spawnSystemPetsIfNeeded_firstCall_addsTwoPets() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        XCTAssertEqual(scene.systemPets.count, 2,
                       "spawnSystemPetsIfNeeded 후 systemPets는 2마리여야 한다")
    }

    // Happy path: spawnSystemPetsIfNeeded 후 CPU pet 노드가 존재한다
    func test_spawnSystemPetsIfNeeded_cpuPetNode_exists() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        XCTAssertNotNil(scene.systemPets[.cpu],
                        "CPU pet 노드가 systemPets 딕셔너리에 있어야 한다")
    }

    // Happy path: spawnSystemPetsIfNeeded 후 Memory pet 노드가 존재한다
    func test_spawnSystemPetsIfNeeded_memoryPetNode_exists() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        XCTAssertNotNil(scene.systemPets[.memory],
                        "Memory pet 노드가 systemPets 딕셔너리에 있어야 한다")
    }

    // 멱등성: 두 번째 호출 시 중복 생성 안 됨 → 여전히 2마리
    func test_spawnSystemPetsIfNeeded_calledTwice_noDuplication() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        scene.spawnSystemPetsIfNeeded()
        XCTAssertEqual(scene.systemPets.count, 2,
                       "멱등성: 두 번 호출해도 systemPets는 여전히 2마리여야 한다")
    }

    // 멱등성: 10회 호출해도 2마리 유지
    func test_spawnSystemPetsIfNeeded_calledMultipleTimes_staysTwo() {
        let scene = makeScene()
        for _ in 0..<10 {
            scene.spawnSystemPetsIfNeeded()
        }
        XCTAssertEqual(scene.systemPets.count, 2,
                       "멱등성: 10회 호출해도 systemPets는 2마리여야 한다")
    }

    // Happy path: spawnSystemPetsIfNeeded 후 두 펫 노드가 scene children에 추가된다
    func test_spawnSystemPetsIfNeeded_petsAddedToSceneChildren() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let cpuPet = scene.systemPets[.cpu],
              let memPet = scene.systemPets[.memory] else {
            XCTFail("systemPets에 cpu/memory 노드가 없다")
            return
        }
        XCTAssertTrue(scene.children.contains(cpuPet),
                      "CPU pet 노드가 scene의 children에 포함되어야 한다")
        XCTAssertTrue(scene.children.contains(memPet),
                      "Memory pet 노드가 scene의 children에 포함되어야 한다")
    }
}

// MARK: - applyMetrics 지표 전달 테스트 (AC3)

final class SystemPetSceneApplyMetricsTests: XCTestCase {

    // Happy path: applyMetrics → CPU pet에 cpuPercent가 전달된다
    func test_applyMetrics_cpuPercent_deliveredToCpuPet() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let cpuPet = scene.systemPets[.cpu] else {
            XCTFail("CPU pet이 없다"); return
        }

        scene.applyMetrics(SystemMetrics(
            cpuPercent: 100.0,
            memoryPercent: 50.0,
            diskPercent: 50.0,
            diskFreeGB: 200.0
        ))

        // CPU=100% → waitTime은 minWait(1.0s)
        XCTAssertEqual(cpuPet.currentWaitTime, SystemPetNode.minWaitBetweenSteps, accuracy: 0.001,
                       "AC3: CPU 100% 반영 → cpuPet.currentWaitTime == minWait")
    }

    // Happy path: applyMetrics → Memory pet에 memoryPercent가 전달된다
    func test_applyMetrics_memoryPercent_deliveredToMemoryPet() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let memPet = scene.systemPets[.memory] else {
            XCTFail("Memory pet이 없다"); return
        }

        scene.applyMetrics(SystemMetrics(
            cpuPercent: 50.0,
            memoryPercent: 100.0,
            diskPercent: 50.0,
            diskFreeGB: 200.0
        ))

        // Memory=100% → waitTime은 minWait(1.0s)
        XCTAssertEqual(memPet.currentWaitTime, SystemPetNode.minWaitBetweenSteps, accuracy: 0.001,
                       "applyMetrics: Memory 100% 반영 → memPet.currentWaitTime == minWait")
    }

    // AC3: Disk 사용률만 변경해도 CPU/Memory pet 속도는 변하지 않는다
    func test_applyMetrics_diskPercent_doesNotAffectPets() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let cpuPet = scene.systemPets[.cpu],
              let memPet = scene.systemPets[.memory] else {
            XCTFail("pet 노드가 없다"); return
        }

        // 먼저 cpu=50, mem=50 으로 기준값 설정
        scene.applyMetrics(SystemMetrics(
            cpuPercent: 50.0,
            memoryPercent: 50.0,
            diskPercent: 10.0,
            diskFreeGB: 300.0
        ))
        let cpuWaitBefore = cpuPet.currentWaitTime
        let memWaitBefore = memPet.currentWaitTime

        // disk만 0→90으로 바꿔도 cpu/mem pet 속도 불변
        scene.applyMetrics(SystemMetrics(
            cpuPercent: 50.0,
            memoryPercent: 50.0,
            diskPercent: 90.0,
            diskFreeGB: 50.0
        ))

        XCTAssertEqual(cpuPet.currentWaitTime, cpuWaitBefore, accuracy: 0.001,
                       "AC3: Disk 변경은 CPU pet의 waitTime에 영향을 주지 않는다")
        XCTAssertEqual(memPet.currentWaitTime, memWaitBefore, accuracy: 0.001,
                       "AC3: Disk 변경은 Memory pet의 waitTime에 영향을 주지 않는다")
    }

    // AC3: CPU pet은 memoryPercent 변경에 반응하지 않는다
    func test_applyMetrics_cpuPet_onlyReactsToCpuPercent() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let cpuPet = scene.systemPets[.cpu] else {
            XCTFail("CPU pet이 없다"); return
        }

        // cpu=0으로 초기화
        scene.applyMetrics(SystemMetrics(
            cpuPercent: 0.0,
            memoryPercent: 0.0,
            diskPercent: 0.0,
            diskFreeGB: 500.0
        ))
        let cpuWaitAfterZero = cpuPet.currentWaitTime

        // memory만 100으로 바꾸고 cpu는 0 유지
        scene.applyMetrics(SystemMetrics(
            cpuPercent: 0.0,
            memoryPercent: 100.0,
            diskPercent: 0.0,
            diskFreeGB: 500.0
        ))

        XCTAssertEqual(cpuPet.currentWaitTime, cpuWaitAfterZero, accuracy: 0.001,
                       "AC3: Memory 변경은 CPU pet의 waitTime에 영향을 주지 않는다")
    }

    // AC3: Memory pet은 cpuPercent 변경에 반응하지 않는다
    func test_applyMetrics_memoryPet_onlyReactsToMemoryPercent() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let memPet = scene.systemPets[.memory] else {
            XCTFail("Memory pet이 없다"); return
        }

        // memory=0으로 초기화
        scene.applyMetrics(SystemMetrics(
            cpuPercent: 0.0,
            memoryPercent: 0.0,
            diskPercent: 0.0,
            diskFreeGB: 500.0
        ))
        let memWaitAfterZero = memPet.currentWaitTime

        // cpu만 100으로 바꾸고 memory는 0 유지
        scene.applyMetrics(SystemMetrics(
            cpuPercent: 100.0,
            memoryPercent: 0.0,
            diskPercent: 0.0,
            diskFreeGB: 500.0
        ))

        XCTAssertEqual(memPet.currentWaitTime, memWaitAfterZero, accuracy: 0.001,
                       "AC3: CPU 변경은 Memory pet의 waitTime에 영향을 주지 않는다")
    }

    // Edge case: spawnSystemPetsIfNeeded 전에 applyMetrics 호출해도 크래시 없음
    func test_applyMetrics_beforeSpawn_doesNotCrash() {
        let scene = makeScene()
        // spawn 없이 바로 applyMetrics
        scene.applyMetrics(SystemMetrics(
            cpuPercent: 50.0,
            memoryPercent: 50.0,
            diskPercent: 50.0,
            diskFreeGB: 200.0
        ))
        // 크래시 없이 통과하면 OK
        XCTAssertTrue(true)
    }
}

// MARK: - AC10: characterNodeCount 불변 테스트

final class SystemPetSceneCharacterNodeCountTests: XCTestCase {

    // AC10: 펫 스폰 전 characterNodeCount == 0
    func test_characterNodeCount_beforeSpawn_isZero() {
        let scene = makeScene()
        XCTAssertEqual(scene.characterNodeCount, 0,
                       "AC10: 펫 스폰 전 characterNodeCount는 0이어야 한다")
    }

    // AC10: 펫 2마리 스폰 후에도 characterNodeCount == 0 (펫은 포함되지 않음)
    func test_characterNodeCount_afterSpawn_remainsZero() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        XCTAssertEqual(scene.characterNodeCount, 0,
                       "AC10: 펫 2마리 스폰 후에도 characterNodeCount는 0이어야 한다 (펫 미포함)")
    }

    // AC10: agents 1명 + 펫 2마리 → characterNodeCount == 1
    func test_characterNodeCount_withOneAgent_andPets_isOne() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        scene.synchronize(agents: [makeAgent(id: "a1")])
        XCTAssertEqual(scene.characterNodeCount, 1,
                       "AC10: agent 1명 + 펫 2마리 → characterNodeCount는 1이어야 한다")
    }

    // AC10: agents 3명 + 펫 2마리 → characterNodeCount == 3
    func test_characterNodeCount_withThreeAgents_andPets_isThree() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        scene.synchronize(agents: [
            makeAgent(id: "a1"),
            makeAgent(id: "a2"),
            makeAgent(id: "a3")
        ])
        XCTAssertEqual(scene.characterNodeCount, 3,
                       "AC10: agent 3명 + 펫 2마리 → characterNodeCount는 3이어야 한다")
    }

    // AC10: systemPets 딕셔너리에는 펫 2마리가 존재한다
    func test_systemPets_count_isTwo_afterSpawn() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        XCTAssertEqual(scene.systemPets.count, 2,
                       "AC10: systemPets 딕셔너리에 CPU+Memory pet 2마리가 있어야 한다")
    }

    // AC10: agents 동기화 후 agents 수와 characterNodeCount는 일치한다
    func test_characterNodeCount_matchesAgentCount_ignoringPets() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()

        let agentCount = 5
        let agents = (0..<agentCount).map { makeAgent(id: "agent-\($0)") }
        scene.synchronize(agents: agents)

        XCTAssertEqual(scene.characterNodeCount, agentCount,
                       "AC10: characterNodeCount는 agents 수(\(agentCount))만 반영해야 한다")
    }
}

// MARK: - AC14: Memory pet이 가구 AABB 안에 없음

final class SystemPetSceneForbiddenRectsTests: XCTestCase {

    // AC14: memoryPetForbiddenRects가 비어있지 않다 (가구가 최소 1개 이상)
    func test_memoryPetForbiddenRects_afterSpawn_isNotEmpty() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        XCTAssertFalse(scene.memoryPetForbiddenRects.isEmpty,
                       "AC14: memoryPetForbiddenRects는 가구 AABB를 포함해야 한다 (비어있으면 안 됨)")
    }

    // AC14: memoryPetForbiddenRects의 모든 rect는 유효한 크기를 갖는다
    func test_memoryPetForbiddenRects_allRectsHavePositiveSize() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        for rect in scene.memoryPetForbiddenRects {
            XCTAssertGreaterThan(rect.width, 0,
                                 "AC14: forbidden rect의 width는 0보다 커야 한다 (\(rect))")
            XCTAssertGreaterThan(rect.height, 0,
                                 "AC14: forbidden rect의 height는 0보다 커야 한다 (\(rect))")
        }
    }

    // AC14: 스폰 직후 Memory pet의 position이 어떤 forbidden rect 안에도 없다
    func test_memoryPet_initialPosition_notInForbiddenRects() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let memPet = scene.systemPets[.memory] else {
            XCTFail("Memory pet이 없다"); return
        }
        let position = memPet.position
        for rect in scene.memoryPetForbiddenRects {
            XCTAssertFalse(rect.contains(position),
                           "AC14: Memory pet 초기 position \(position)이 forbidden rect \(rect) 안에 있다")
        }
    }

    // AC14: forceZoneHop(.work) 후 Memory pet position이 forbidden rect 밖에 있다
    func test_memoryPet_afterForceZoneHopToWork_notInForbiddenRects() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let memPet = scene.systemPets[.memory] else {
            XCTFail("Memory pet이 없다"); return
        }

        memPet.forceZoneHop(to: .work)

        let position = memPet.position
        for rect in scene.memoryPetForbiddenRects {
            XCTAssertFalse(rect.contains(position),
                           "AC14: forceZoneHop(.work) 후 Memory pet position \(position)이 forbidden rect \(rect) 안에 있다")
        }
    }

    // AC14: forceZoneHop(.meeting) 후 Memory pet position이 forbidden rect 밖에 있다
    func test_memoryPet_afterForceZoneHopToMeeting_notInForbiddenRects() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let memPet = scene.systemPets[.memory] else {
            XCTFail("Memory pet이 없다"); return
        }

        memPet.forceZoneHop(to: .meeting)

        let position = memPet.position
        for rect in scene.memoryPetForbiddenRects {
            XCTAssertFalse(rect.contains(position),
                           "AC14: forceZoneHop(.meeting) 후 Memory pet position \(position)이 forbidden rect \(rect) 안에 있다")
        }
    }

    // AC14: forceZoneHop(.rest) 후 Memory pet position이 forbidden rect 밖에 있다
    func test_memoryPet_afterForceZoneHopToRest_notInForbiddenRects() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let memPet = scene.systemPets[.memory] else {
            XCTFail("Memory pet이 없다"); return
        }

        memPet.forceZoneHop(to: .rest)

        let position = memPet.position
        for rect in scene.memoryPetForbiddenRects {
            XCTAssertFalse(rect.contains(position),
                           "AC14: forceZoneHop(.rest) 후 Memory pet position \(position)이 forbidden rect \(rect) 안에 있다")
        }
    }
}

// MARK: - AC5: Memory pet 씬 통합 환경에서 forceZoneHop 검증

final class SystemPetSceneForceZoneHopTests: XCTestCase {

    // AC5: 씬 통합 환경에서 forceZoneHop(.rest) → lastZoneVisited == .rest
    func test_memoryPet_inScene_forceZoneHop_toRest_updatesLastZoneVisited() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let memPet = scene.systemPets[.memory] else {
            XCTFail("Memory pet이 없다"); return
        }

        memPet.forceZoneHop(to: .rest)
        XCTAssertEqual(memPet.lastZoneVisited, .rest,
                       "AC5: scene 통합 환경에서 forceZoneHop(.rest) → lastZoneVisited == .rest")
    }

    // AC5: 씬 통합 환경에서 forceZoneHop(.work) → lastZoneVisited == .work
    func test_memoryPet_inScene_forceZoneHop_toWork_updatesLastZoneVisited() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let memPet = scene.systemPets[.memory] else {
            XCTFail("Memory pet이 없다"); return
        }

        memPet.forceZoneHop(to: .work)
        XCTAssertEqual(memPet.lastZoneVisited, .work,
                       "AC5: scene 통합 환경에서 forceZoneHop(.work) → lastZoneVisited == .work")
    }

    // AC5: 씬 통합 환경에서 forceZoneHop(.meeting) → lastZoneVisited == .meeting
    func test_memoryPet_inScene_forceZoneHop_toMeeting_updatesLastZoneVisited() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let memPet = scene.systemPets[.memory] else {
            XCTFail("Memory pet이 없다"); return
        }

        memPet.forceZoneHop(to: .meeting)
        XCTAssertEqual(memPet.lastZoneVisited, .meeting,
                       "AC5: scene 통합 환경에서 forceZoneHop(.meeting) → lastZoneVisited == .meeting")
    }

    // AC5: 순차 hop — .rest → .work → .meeting 각 호출 후 lastZoneVisited가 갱신된다
    func test_memoryPet_inScene_forceZoneHop_sequential_updatesEachTime() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let memPet = scene.systemPets[.memory] else {
            XCTFail("Memory pet이 없다"); return
        }

        memPet.forceZoneHop(to: .rest)
        XCTAssertEqual(memPet.lastZoneVisited, .rest, "1번째: .rest")

        memPet.forceZoneHop(to: .work)
        XCTAssertEqual(memPet.lastZoneVisited, .work, "2번째: .work")

        memPet.forceZoneHop(to: .meeting)
        XCTAssertEqual(memPet.lastZoneVisited, .meeting, "3번째: .meeting")
    }

    // AC5: 이 검증은 실제 시간 경과에 의존하지 않는다 — forceZoneHop은 동기적으로 완료
    // (위의 테스트들이 모두 expectation/wait 없이 동기 검증함을 확인하는 문서 테스트)
    func test_memoryPet_forceZoneHop_isSynchronous_noWaitRequired() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        guard let memPet = scene.systemPets[.memory] else {
            XCTFail("Memory pet이 없다"); return
        }

        // XCTestExpectation 없이 즉시 검증 가능하면 동기적
        memPet.forceZoneHop(to: .work)
        XCTAssertEqual(memPet.lastZoneVisited, .work,
                       "AC5: forceZoneHop은 비동기 대기 없이 즉시 lastZoneVisited를 업데이트해야 한다")
    }
}

// MARK: - pauseSystemPets / resumeSystemPets (AC9 관련, Phase D 연결)

final class SystemPetScenePauseResumeTests: XCTestCase {

    // pauseSystemPets 후 모든 pet 노드의 hasActions() == false
    func test_pauseSystemPets_allPetsHaveNoActions() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()

        scene.pauseSystemPets()

        for (_, petNode) in scene.systemPets {
            XCTAssertFalse(petNode.hasActions(),
                           "pauseSystemPets 후 pet 노드의 hasActions()는 false여야 한다")
        }
    }

    // resumeSystemPets 호출이 크래시 없이 완료된다
    func test_resumeSystemPets_doesNotCrash() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()

        scene.pauseSystemPets()
        scene.resumeSystemPets()

        // 크래시 없이 통과하면 OK
        XCTAssertTrue(true)
    }

    // pause 전에 resume 호출해도 크래시 없음 (방어적 동작)
    func test_resumeSystemPets_beforePause_doesNotCrash() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()

        scene.resumeSystemPets()

        XCTAssertTrue(true)
    }
}

// MARK: - Spawn triggers wander + resume restarts wander

final class SystemPetSceneSpawnWanderTests: XCTestCase {

    private func makeScene() -> PixelAgentsScene {
        PixelAgentsScene(size: CGSize(width: 420, height: 560), provider: ProgrammaticPixelProvider())
    }

    // spawnSystemPetsIfNeeded must leave both pets with scheduled actions so they actually move.
    func test_spawnSystemPetsIfNeeded_startsWanderingOnBothPets() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()

        XCTAssertTrue(scene.systemPets[.cpu]?.hasActions() == true,
                      "CPU pet must have actions scheduled after spawn")
        XCTAssertTrue(scene.systemPets[.memory]?.hasActions() == true,
                      "Memory pet must have actions scheduled after spawn")
    }

    // resumeSystemPets after a pause must restart wander actions.
    func test_resumeSystemPets_afterPause_restartsActions() {
        let scene = makeScene()
        scene.spawnSystemPetsIfNeeded()
        scene.pauseSystemPets()
        XCTAssertFalse(scene.systemPets[.cpu]?.hasActions() ?? true)

        scene.resumeSystemPets()

        XCTAssertTrue(scene.systemPets[.cpu]?.hasActions() == true,
                      "CPU pet must restart wandering after resumeSystemPets")
        XCTAssertTrue(scene.systemPets[.memory]?.hasActions() == true,
                      "Memory pet must restart wandering after resumeSystemPets")
    }
}
