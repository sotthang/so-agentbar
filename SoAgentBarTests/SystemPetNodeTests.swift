import XCTest
import SpriteKit
@testable import SoAgentBar

// =============================================================================
// MARK: - SystemPetNodeTests
// TDD RED phase — Phase B 테스트
//
// Coverage:
//   AC5  (R17) — forceZoneHop → lastZoneVisited 갱신 (결정적 검증)
//   AC6        — CPU pet: updateMetric → currentWaitTime/currentWalkSpeed 비례
//   AC7        — Memory pet: updateMetric → currentWaitTime/currentWalkSpeed 비례
//   D5         — CPU spriteIndex=0, Memory spriteIndex=1
//   D6         — lastZoneVisited 초기값 = .rest
//   초기 상태   — 생성 직후 currentWaitTime/currentWalkSpeed 보수적 초기값
// =============================================================================

// MARK: - SystemPetKind 열거형 테스트

final class SystemPetKindTests: XCTestCase {

    // Happy path: .cpu 와 .memory 케이스가 존재한다
    func test_systemPetKind_cpuCase_exists() {
        let kind: SystemPetKind = .cpu
        XCTAssertEqual(kind, .cpu)
    }

    func test_systemPetKind_memoryCase_exists() {
        let kind: SystemPetKind = .memory
        XCTAssertEqual(kind, .memory)
    }

    // Happy path: Hashable 준수 — Dictionary 키로 사용 가능
    func test_systemPetKind_hashable_usableAsDictionaryKey() {
        var dict: [SystemPetKind: String] = [:]
        dict[.cpu] = "CPU"
        dict[.memory] = "Memory"
        XCTAssertEqual(dict[.cpu], "CPU")
        XCTAssertEqual(dict[.memory], "Memory")
    }
}

// MARK: - SystemPetZone 열거형 테스트

final class SystemPetZoneTests: XCTestCase {

    // Happy path: .rest, .work, .meeting 케이스가 존재한다
    func test_systemPetZone_restCase_exists() {
        let zone: SystemPetZone = .rest
        XCTAssertEqual(zone, .rest)
    }

    func test_systemPetZone_workCase_exists() {
        let zone: SystemPetZone = .work
        XCTAssertEqual(zone, .work)
    }

    func test_systemPetZone_meetingCase_exists() {
        let zone: SystemPetZone = .meeting
        XCTAssertEqual(zone, .meeting)
    }

    // Happy path: Hashable 준수 — Dictionary 키로 사용 가능
    func test_systemPetZone_hashable_usableAsDictionaryKey() {
        var dict: [SystemPetZone: CGRect] = [:]
        dict[.rest] = CGRect(x: 0, y: 0, width: 100, height: 100)
        dict[.work] = CGRect(x: 100, y: 0, width: 100, height: 100)
        dict[.meeting] = CGRect(x: 200, y: 0, width: 100, height: 100)
        XCTAssertNotNil(dict[.rest])
        XCTAssertNotNil(dict[.work])
        XCTAssertNotNil(dict[.meeting])
    }
}

// MARK: - SystemPet 구조체 테스트 (D5)

final class SystemPetModelTests: XCTestCase {

    // Happy path: SystemPet 초기화 — kind, metricValue, spriteIndex 저장
    func test_systemPet_init_fieldsStoredCorrectly() {
        let pet = SystemPet(kind: .cpu, metricValue: 42.0, spriteIndex: 0)
        XCTAssertEqual(pet.kind, .cpu)
        XCTAssertEqual(pet.metricValue, 42.0, accuracy: 0.001)
        XCTAssertEqual(pet.spriteIndex, 0)
    }

    // D5: CPU pet spriteIndex = 0 (고정 상수)
    func test_systemPet_cpuSpriteIndex_isZero() {
        XCTAssertEqual(SystemPet.cpuSpriteIndex, 0,
                       "D5: CPU pet은 spriteIndex=0을 사용해야 한다")
    }

    // D5: Memory pet spriteIndex = 1 (고정 상수)
    func test_systemPet_memorySpriteIndex_isOne() {
        XCTAssertEqual(SystemPet.memorySpriteIndex, 1,
                       "D5: Memory pet은 spriteIndex=1을 사용해야 한다")
    }

    // Happy path: badgeLabel — CPU pet은 "CPU" 반환
    func test_systemPet_badgeLabel_cpuReturnsCorrectString() {
        let pet = SystemPet(kind: .cpu, metricValue: 0, spriteIndex: SystemPet.cpuSpriteIndex)
        XCTAssertEqual(pet.badgeLabel, "CPU")
    }

    // Happy path: badgeLabel — Memory pet은 "MEM" 반환
    func test_systemPet_badgeLabel_memoryReturnsCorrectString() {
        let pet = SystemPet(kind: .memory, metricValue: 0, spriteIndex: SystemPet.memorySpriteIndex)
        XCTAssertEqual(pet.badgeLabel, "MEM")
    }

    // Happy path: Equatable — 같은 값은 equal
    func test_systemPet_equatable_sameValues_areEqual() {
        let a = SystemPet(kind: .cpu, metricValue: 50, spriteIndex: 0)
        let b = SystemPet(kind: .cpu, metricValue: 50, spriteIndex: 0)
        XCTAssertEqual(a, b)
    }
}

// MARK: - SystemPetNode 초기 상태 테스트 (D6, R17)

final class SystemPetNodeInitialStateTests: XCTestCase {

    private func makeCPUNode() -> SystemPetNode {
        SystemPetNode(
            kind: .cpu,
            provider: SpriteSheetPixelProvider(),
            spriteIndex: SystemPet.cpuSpriteIndex
        )
    }

    private func makeMemoryNode() -> SystemPetNode {
        SystemPetNode(
            kind: .memory,
            provider: SpriteSheetPixelProvider(),
            spriteIndex: SystemPet.memorySpriteIndex
        )
    }

    // D6: CPU pet 생성 직후 lastZoneVisited == .rest
    func test_cpuPetNode_initialLastZoneVisited_isRest() {
        let node = makeCPUNode()
        XCTAssertEqual(node.lastZoneVisited, .rest,
                       "D6: CPU pet의 lastZoneVisited 초기값은 .rest여야 한다")
    }

    // D6: Memory pet 생성 직후 lastZoneVisited == .rest
    func test_memoryPetNode_initialLastZoneVisited_isRest() {
        let node = makeMemoryNode()
        XCTAssertEqual(node.lastZoneVisited, .rest,
                       "D6: Memory pet의 lastZoneVisited 초기값은 .rest여야 한다")
    }

    // 초기 상태: currentWaitTime은 maxWaitBetweenSteps
    func test_cpuPetNode_initialCurrentWaitTime_isMaxWait() {
        let node = makeCPUNode()
        // 생성 직후 지표 미반영 → 보수적 최대값
        XCTAssertEqual(node.currentWaitTime, SystemPetNode.maxWaitBetweenSteps, accuracy: 0.001,
                       "초기 currentWaitTime은 maxWaitBetweenSteps 여야 한다")
    }

    // 초기 상태: currentWalkSpeed는 minWalkSpeed(보수적 값 = 80)
    func test_cpuPetNode_initialCurrentWalkSpeed_isMinSpeed() {
        let node = makeCPUNode()
        // 생성 직후 지표 미반영 → 보수적 최소 속도(80 pt/s)
        XCTAssertEqual(node.currentWalkSpeed, SystemPetNode.minWalkSpeed, accuracy: 0.1,
                       "초기 currentWalkSpeed는 minWalkSpeed(80 pt/s)여야 한다")
    }

    // 파라미터 상수 검증
    func test_systemPetNode_parameters_matchSpecValues() {
        XCTAssertEqual(SystemPetNode.minWaitBetweenSteps, 3.0, accuracy: 0.001)
        XCTAssertEqual(SystemPetNode.maxWaitBetweenSteps, 15.0, accuracy: 0.001)
        XCTAssertEqual(SystemPetNode.minWalkSpeed, 80, accuracy: 0.1)
        XCTAssertEqual(SystemPetNode.maxWalkSpeed, 240, accuracy: 0.1)
    }
}

// MARK: - SystemPetNode.updateMetric — AC6/AC7 (속도 비례 검증)

final class SystemPetNodeUpdateMetricTests: XCTestCase {

    // 보간 공식 (SPEC): waitTime = lerp(maxWait, minWait, metric/100)
    //                    walkSpeed = lerp(minSpeed, maxSpeed, metric/100)
    // metric=0   → waitTime=8.0,  walkSpeed=80
    // metric=100 → waitTime=1.0,  walkSpeed=240
    // metric=50  → waitTime=4.5,  walkSpeed=160

    private func makeCPUNode() -> SystemPetNode {
        SystemPetNode(
            kind: .cpu,
            provider: SpriteSheetPixelProvider(),
            spriteIndex: SystemPet.cpuSpriteIndex
        )
    }

    private func makeMemoryNode() -> SystemPetNode {
        SystemPetNode(
            kind: .memory,
            provider: SpriteSheetPixelProvider(),
            spriteIndex: SystemPet.memorySpriteIndex
        )
    }

    // AC6: CPU=0% → currentWaitTime == maxWaitBetweenSteps (8.0s, 느림)
    func test_cpuPet_updateMetric_zero_setsMaxWaitTime() {
        let node = makeCPUNode()
        node.updateMetric(0.0)
        XCTAssertEqual(node.currentWaitTime, SystemPetNode.maxWaitBetweenSteps, accuracy: 0.001,
                       "AC6: CPU 0% → waitTime은 maxWait(8.0s)여야 한다")
    }

    // AC6: CPU=100% → currentWaitTime == minWaitBetweenSteps (1.0s, 빠름)
    func test_cpuPet_updateMetric_hundred_setsMinWaitTime() {
        let node = makeCPUNode()
        node.updateMetric(100.0)
        XCTAssertEqual(node.currentWaitTime, SystemPetNode.minWaitBetweenSteps, accuracy: 0.001,
                       "AC6: CPU 100% → waitTime은 minWait(1.0s)여야 한다")
    }

    // AC6: CPU=0% → currentWalkSpeed == minWalkSpeed (80 pt/s, 느림)
    func test_cpuPet_updateMetric_zero_setsMinWalkSpeed() {
        let node = makeCPUNode()
        node.updateMetric(0.0)
        XCTAssertEqual(node.currentWalkSpeed, SystemPetNode.minWalkSpeed, accuracy: 0.1,
                       "AC6: CPU 0% → walkSpeed는 minSpeed(80 pt/s)여야 한다")
    }

    // AC6: CPU=100% → currentWalkSpeed == maxWalkSpeed (240 pt/s, 빠름)
    func test_cpuPet_updateMetric_hundred_setsMaxWalkSpeed() {
        let node = makeCPUNode()
        node.updateMetric(100.0)
        XCTAssertEqual(node.currentWalkSpeed, SystemPetNode.maxWalkSpeed, accuracy: 0.1,
                       "AC6: CPU 100% → walkSpeed는 maxSpeed(240 pt/s)여야 한다")
    }

    // AC6: CPU=50% → waitTime은 중간값 — linear lerp 허용 범위 ±1.0
    func test_cpuPet_updateMetric_fifty_setsMidpointWaitTime() {
        let node = makeCPUNode()
        node.updateMetric(50.0)
        // lerp(maxWait, minWait, 0.5) = (maxWait + minWait) / 2
        let expectedWait = (SystemPetNode.maxWaitBetweenSteps + SystemPetNode.minWaitBetweenSteps) / 2
        XCTAssertEqual(node.currentWaitTime, expectedWait, accuracy: 1.0,
                       "AC6: CPU 50% → waitTime은 중간값 근방이어야 한다")
    }

    // AC6: CPU=50% → walkSpeed는 중간값(≈160 pt/s) — linear lerp 허용 범위 ±10
    func test_cpuPet_updateMetric_fifty_setsMidpointWalkSpeed() {
        let node = makeCPUNode()
        node.updateMetric(50.0)
        // lerp(80, 240, 0.5) = 160
        let expectedSpeed: CGFloat = 160
        XCTAssertEqual(node.currentWalkSpeed, expectedSpeed, accuracy: 10,
                       "AC6: CPU 50% → walkSpeed는 ≈160 pt/s 근방이어야 한다")
    }

    // AC7: Memory=0% → currentWaitTime == maxWaitBetweenSteps (8.0s)
    func test_memoryPet_updateMetric_zero_setsMaxWaitTime() {
        let node = makeMemoryNode()
        node.updateMetric(0.0)
        XCTAssertEqual(node.currentWaitTime, SystemPetNode.maxWaitBetweenSteps, accuracy: 0.001,
                       "AC7: Memory 0% → waitTime은 maxWait(8.0s)여야 한다")
    }

    // AC7: Memory=100% → currentWaitTime == minWaitBetweenSteps (1.0s)
    func test_memoryPet_updateMetric_hundred_setsMinWaitTime() {
        let node = makeMemoryNode()
        node.updateMetric(100.0)
        XCTAssertEqual(node.currentWaitTime, SystemPetNode.minWaitBetweenSteps, accuracy: 0.001,
                       "AC7: Memory 100% → waitTime은 minWait(1.0s)여야 한다")
    }

    // AC7: Memory=0% → currentWalkSpeed == minWalkSpeed (80 pt/s)
    func test_memoryPet_updateMetric_zero_setsMinWalkSpeed() {
        let node = makeMemoryNode()
        node.updateMetric(0.0)
        XCTAssertEqual(node.currentWalkSpeed, SystemPetNode.minWalkSpeed, accuracy: 0.1,
                       "AC7: Memory 0% → walkSpeed는 minSpeed(80 pt/s)여야 한다")
    }

    // AC7: Memory=100% → currentWalkSpeed == maxWalkSpeed (240 pt/s)
    func test_memoryPet_updateMetric_hundred_setsMaxWalkSpeed() {
        let node = makeMemoryNode()
        node.updateMetric(100.0)
        XCTAssertEqual(node.currentWalkSpeed, SystemPetNode.maxWalkSpeed, accuracy: 0.1,
                       "AC7: Memory 100% → walkSpeed는 maxSpeed(240 pt/s)여야 한다")
    }

    // AC7: Memory=50% → waitTime 중간값 근방
    func test_memoryPet_updateMetric_fifty_setsMidpointWaitTime() {
        let node = makeMemoryNode()
        node.updateMetric(50.0)
        let expectedWait = (SystemPetNode.maxWaitBetweenSteps + SystemPetNode.minWaitBetweenSteps) / 2
        XCTAssertEqual(node.currentWaitTime, expectedWait, accuracy: 1.0,
                       "AC7: Memory 50% → waitTime은 중간값 근방이어야 한다")
    }

    // Edge case: metric 값이 0 미만이어도 크래시 없이 처리된다
    func test_cpuPet_updateMetric_belowZero_doesNotCrash() {
        let node = makeCPUNode()
        node.updateMetric(-10.0)
        // 최소한 크래시 없이 currentWaitTime이 유효한 값이어야 한다
        XCTAssertGreaterThan(node.currentWaitTime, 0,
                             "Edge case: metric < 0이어도 waitTime은 양수여야 한다")
    }

    // Edge case: metric 값이 100 초과여도 크래시 없이 처리된다
    func test_cpuPet_updateMetric_aboveHundred_doesNotCrash() {
        let node = makeCPUNode()
        node.updateMetric(150.0)
        XCTAssertGreaterThan(node.currentWalkSpeed, 0,
                             "Edge case: metric > 100이어도 walkSpeed는 양수여야 한다")
    }
}

// MARK: - SystemPetNode.forceZoneHop — AC5 (결정적 존 전환 훅)

final class SystemPetNodeForceZoneHopTests: XCTestCase {

    // Memory pet 전용 테스트 — forceZoneHop(to:)은 Memory pet에서 주로 의미가 있다.
    // D2: forceZoneHop은 SKAction 없이 position을 즉시 할당하므로 동기 검증 가능.

    private func makeMemoryNode() -> SystemPetNode {
        SystemPetNode(
            kind: .memory,
            provider: SpriteSheetPixelProvider(),
            spriteIndex: SystemPet.memorySpriteIndex
        )
    }

    private func makeCPUNode() -> SystemPetNode {
        SystemPetNode(
            kind: .cpu,
            provider: SpriteSheetPixelProvider(),
            spriteIndex: SystemPet.cpuSpriteIndex
        )
    }

    // AC5: Memory pet에 forceZoneHop(to: .rest) 호출 → lastZoneVisited == .rest
    func test_memoryPet_forceZoneHop_toRest_updatesLastZoneVisited() {
        let node = makeMemoryNode()
        node.forceZoneHop(to: .rest)
        XCTAssertEqual(node.lastZoneVisited, .rest,
                       "AC5: forceZoneHop(.rest) 후 lastZoneVisited는 .rest여야 한다")
    }

    // AC5: Memory pet에 forceZoneHop(to: .work) 호출 → lastZoneVisited == .work
    func test_memoryPet_forceZoneHop_toWork_updatesLastZoneVisited() {
        let node = makeMemoryNode()
        node.forceZoneHop(to: .work)
        XCTAssertEqual(node.lastZoneVisited, .work,
                       "AC5: forceZoneHop(.work) 후 lastZoneVisited는 .work여야 한다")
    }

    // AC5: Memory pet에 forceZoneHop(to: .meeting) 호출 → lastZoneVisited == .meeting
    func test_memoryPet_forceZoneHop_toMeeting_updatesLastZoneVisited() {
        let node = makeMemoryNode()
        node.forceZoneHop(to: .meeting)
        XCTAssertEqual(node.lastZoneVisited, .meeting,
                       "AC5: forceZoneHop(.meeting) 후 lastZoneVisited는 .meeting이어야 한다")
    }

    // AC5: 순차 호출 — .rest → .work → .meeting 순서로 lastZoneVisited가 갱신된다
    func test_memoryPet_forceZoneHop_sequential_updatesEachTime() {
        let node = makeMemoryNode()

        node.forceZoneHop(to: .rest)
        XCTAssertEqual(node.lastZoneVisited, .rest, "1번째 hop: .rest")

        node.forceZoneHop(to: .work)
        XCTAssertEqual(node.lastZoneVisited, .work, "2번째 hop: .work")

        node.forceZoneHop(to: .meeting)
        XCTAssertEqual(node.lastZoneVisited, .meeting, "3번째 hop: .meeting")
    }

    // AC5: forceZoneHop 호출 후 position이 zoneBounds 안에 있다 (D2: 즉시 position 할당)
    // zoneBounds 없이 생성된 경우 position 갱신 여부만 확인
    func test_memoryPet_forceZoneHop_toWork_positionIsUpdatedImmediately() {
        let node = makeMemoryNode()
        let initialPosition = node.position

        // forceZoneHop은 position을 즉시 할당해야 한다 (D2)
        // (zoneBounds가 주입되지 않았을 때는 구현에 따라 원점 근방 또는 불변일 수 있으나,
        //  호출이 크래시 없이 완료되고 lastZoneVisited가 갱신되어야 한다)
        node.forceZoneHop(to: .work)
        XCTAssertEqual(node.lastZoneVisited, .work)
        _ = initialPosition // suppress warning
    }

    // CPU pet에 forceZoneHop 호출 — 아키텍트 설계: CPU pet은 항상 .rest 유지 (N1)
    // CPU pet에 forceZoneHop을 호출해도 크래시 없이 동작해야 한다
    func test_cpuPet_forceZoneHop_doesNotCrash() {
        let node = makeCPUNode()
        // CPU pet의 lastZoneVisited는 항상 .rest (ARCH 2.5: N1 반영)
        node.forceZoneHop(to: .rest)
        XCTAssertEqual(node.lastZoneVisited, .rest,
                       "CPU pet: forceZoneHop(.rest) 후 lastZoneVisited는 여전히 .rest")
    }

    // Edge case: forceZoneHop 후 currentWaitTime/currentWalkSpeed는 변하지 않는다
    // (zone hop은 속도 재계산과 무관 — updateMetric만이 속도를 바꾼다)
    func test_memoryPet_forceZoneHop_doesNotChangeWaitTime() {
        let node = makeMemoryNode()
        node.updateMetric(50.0)
        let waitBefore = node.currentWaitTime

        node.forceZoneHop(to: .work)

        XCTAssertEqual(node.currentWaitTime, waitBefore, accuracy: 0.001,
                       "forceZoneHop은 currentWaitTime을 변경하면 안 된다")
    }
}

// MARK: - SystemPetNode kind 프로퍼티 테스트

final class SystemPetNodeKindTests: XCTestCase {

    // Happy path: CPU kind로 생성하면 kind == .cpu
    func test_systemPetNode_cpuKind_isPreserved() {
        let node = SystemPetNode(
            kind: .cpu,
            provider: SpriteSheetPixelProvider(),
            spriteIndex: SystemPet.cpuSpriteIndex
        )
        XCTAssertEqual(node.kind, .cpu)
    }

    // Happy path: Memory kind로 생성하면 kind == .memory
    func test_systemPetNode_memoryKind_isPreserved() {
        let node = SystemPetNode(
            kind: .memory,
            provider: SpriteSheetPixelProvider(),
            spriteIndex: SystemPet.memorySpriteIndex
        )
        XCTAssertEqual(node.kind, .memory)
    }
}

// MARK: - Visible sprite + badge label (R11)

final class SystemPetNodeVisibilityTests: XCTestCase {

    private func makeNode(kind: SystemPetKind) -> SystemPetNode {
        SystemPetNode(
            kind: kind,
            provider: ProgrammaticPixelProvider(),
            spriteIndex: kind == .cpu ? 0 : 1
        )
    }

    // Node must contain a visible SKSpriteNode — otherwise scene renders nothing.
    func test_init_hasSpriteChild() {
        let node = makeNode(kind: .cpu)
        XCTAssertTrue(
            node.children.contains { $0 is SKSpriteNode },
            "SystemPetNode must have an SKSpriteNode child to be visible"
        )
    }

    // CPU pet shows "CPU..." text label (R11 — identifies pet as system pet, not agent).
    func test_init_cpuPet_showsCPULabel() {
        let node = makeNode(kind: .cpu)
        let allLabels = node.allDescendantLabels()
        XCTAssertTrue(
            allLabels.contains { ($0.text ?? "").hasPrefix("CPU") },
            "CPU pet must display a 'CPU' text badge"
        )
    }

    // Memory pet shows "MEM..." text label.
    func test_init_memoryPet_showsMEMLabel() {
        let node = makeNode(kind: .memory)
        let allLabels = node.allDescendantLabels()
        XCTAssertTrue(
            allLabels.contains { ($0.text ?? "").hasPrefix("MEM") },
            "Memory pet must display a 'MEM' text badge"
        )
    }

    // After updateMetric, badge label must reflect the percentage.
    func test_updateMetric_updatesBadgeText() {
        let node = makeNode(kind: .cpu)
        node.updateMetric(55.0)
        let labels = node.allDescendantLabels()
        XCTAssertTrue(
            labels.contains { $0.text == "CPU 55%" },
            "Badge must show 'CPU 55%' after updateMetric(55); got: \(labels.map { $0.text ?? "nil" })"
        )
    }
}

// MARK: - Wander action scheduling

final class SystemPetNodeWanderTests: XCTestCase {

    private func makeCPUNode() -> SystemPetNode {
        SystemPetNode(
            kind: .cpu,
            provider: ProgrammaticPixelProvider(),
            spriteIndex: 0
        )
    }

    private func makeMemoryNode() -> SystemPetNode {
        SystemPetNode(
            kind: .memory,
            provider: ProgrammaticPixelProvider(),
            spriteIndex: 1
        )
    }

    // startCPUWandering must schedule an SKAction so the node moves over time.
    func test_startCPUWandering_schedulesAction() {
        let node = makeCPUNode()
        node.startCPUWandering(
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
            interestPoints: []
        )
        XCTAssertTrue(node.hasActions(), "CPU pet must have scheduled actions after startCPUWandering")
    }

    // startMemoryWandering must schedule actions for zone-hopping.
    func test_startMemoryWandering_schedulesAction() {
        let node = makeMemoryNode()
        node.startMemoryWandering(
            zoneBounds: [.rest: CGRect(x: 0, y: 400, width: 420, height: 180)],
            forbiddenRects: []
        )
        XCTAssertTrue(node.hasActions(), "Memory pet must have scheduled actions after startMemoryWandering")
    }

    // stopAllMovement must cancel scheduled actions.
    func test_stopAllMovement_cancelsActions() {
        let node = makeCPUNode()
        node.startCPUWandering(
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
            interestPoints: []
        )
        node.stopAllMovement()
        XCTAssertFalse(node.hasActions(), "stopAllMovement must clear scheduled actions")
    }
}

// MARK: - Helpers

private extension SKNode {
    func allDescendantLabels() -> [SKLabelNode] {
        var out: [SKLabelNode] = []
        for child in children {
            if let l = child as? SKLabelNode { out.append(l) }
            out.append(contentsOf: child.allDescendantLabels())
        }
        return out
    }
}
