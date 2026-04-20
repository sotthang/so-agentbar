import Combine
import SpriteKit

// MARK: - PixelAgentsScene

/// Manages all pixel character nodes in the SpriteKit scene.
/// Subscribe to an agents publisher via `bind(to:)` to keep characters in sync.
final class PixelAgentsScene: SKScene {

    // MARK: - Zone definition

    private enum Zone: Equatable {
        case rest
        case wait
        case work(slot: Int)

        static func == (lhs: Zone, rhs: Zone) -> Bool {
            switch (lhs, rhs) {
            case (.rest, .rest): return true
            case (.wait, .wait): return true
            case (.work(let a), .work(let b)): return a == b
            default: return false
            }
        }
    }

    // MARK: - Public (testable)

    /// Number of active character nodes tracked (not counting fading-out nodes).
    var characterNodeCount: Int { characterNodes.count }

    // MARK: - Private

    private let provider: PixelCharacterProvider

    /// agentID → PixelCharacterNode
    private var characterNodes: [String: PixelCharacterNode] = [:]

    /// agentID → current zone
    private var currentZones: [String: Zone] = [:]

    /// REST zone furniture (sofa, bench) — persistent
    private var restZoneNodes: [SKNode] = []

    /// WORK zone desks — persistent, fixed slots
    private var workDeskNodes: [SKNode] = []

    /// MEETING zone furniture (frames on wall) — persistent
    private var meetingZoneNodes: [SKNode] = []

    /// MEETING zone tables — dynamic, one per session group
    private var meetingTableNodes: [SKNode] = []
    private var meetingGroupCount: Int = 0

    private var floorNode: SKNode?

    private var cancellables = Set<AnyCancellable>()

    private var allIdleSince: Date?
    private static let idlePauseThreshold: TimeInterval = 30

    // MARK: - Zone layout constants
    // T자형 레이아웃:
    //   상단 전체: 휴게실 (420×180)
    //   ─────────────────── (수평 벽, Y=380)
    //   좌하단: 일하는방    │   우하단: 미팅룸
    //   (210×380)          │   (210×380)
    //                      (수직 벽, X=210, Y=0~380)

    private static let sceneW: CGFloat = 420
    private static let sceneH: CGFloat = 560
    private static let splitX: CGFloat = 210   // 수직 벽 X

    // 책상 슬롯 기준으로 splitY 자동 계산
    // deskY(slot N-1) = workBaseY + (N-1)*charSpacingY - 40
    // 책상 스프라이트 높이 128px → 상단 Y = deskY + 128
    private static let workDeskSlots: Int = 4
    private static let charSpacingY: CGFloat = 60
    private static let workBaseY: CGFloat = 50
    private static let deskH: CGFloat = 128
    private static let splitY: CGFloat =
        workBaseY + CGFloat(workDeskSlots - 1) * charSpacingY - 40 + deskH + 30  // = 50+180-40+128+30 = 348

    // 책상 2×2 그리드: 왼쪽 열(col 0) + 오른쪽 열(col 1)
    private static let workLeftDeskX: CGFloat  = 40             // 왼쪽 열 책상 X
    private static let workRightDeskX: CGFloat = splitX - 40   // 오른쪽 열 책상 X (170)
    private static let workLeftCharX: CGFloat  = workLeftDeskX + 30   // 왼쪽 캐릭터 X (70)
    private static let workRightCharX: CGFloat = workRightDeskX - 30  // 오른쪽 캐릭터 X (140)
    // 행 간격: row 0 = 하단(workBaseY), row 1 = 상단(workBaseY + workRowSpacing)
    private static let workRowSpacing: CGFloat = 150

    // 각 존의 캐릭터 기준점
    private static let restCenterX: CGFloat = sceneW / 2        // 휴게실: 상단 중앙
    private static let restBaseY: CGFloat   = splitY + 148      // 휴게실 캐릭터 시작 Y (소파 위치 = splitY+150)

    // 휴게실 wander 영역: 가구 사이를 돌아다닐 수 있는 바닥 공간
    private static let restWanderBounds = CGRect(
        x: 40, y: splitY + 20, width: sceneW - 80, height: 120
    )
    // 관심 지점: 냉장고 앞, 자판기 앞, 소파 앞 — 캐릭터가 자주 방문
    private static let restInterestPoints: [CGPoint] = [
        CGPoint(x: sceneW - 24 - 40, y: splitY + 40),  // 냉장고 앞
        CGPoint(x: sceneW - 24,      y: splitY + 40),  // 자판기 앞
        CGPoint(x: restCenterX - 80, y: splitY + 100), // 소파1 앞
        CGPoint(x: restCenterX + 80, y: splitY + 100), // 소파2 앞
        CGPoint(x: restCenterX,      y: splitY + 80)   // 벤치 앞
    ]
    // PC 중심 Y = deskY + 64 = (charBaseY - 40) + 64 = charBaseY + 24
    // 캐릭터를 PC 화면 높이에 맞추기 위해 +24 오프셋 적용
    private static let workCharOffsetY: CGFloat = 24
    private static let waitCenterX: CGFloat = splitX + 105      // 미팅룸 중앙 X
    private static let waitBaseY: CGFloat   = 60                // 미팅룸 캐릭터 시작 Y
    private static let waitColSpacing: CGFloat = 35             // 테이블 양쪽 열 간격

    /// 부모 세션 ID에서 결정적으로 파생된 배경 색상 (부모+서브에이전트 그룹 색상).
    /// 어두운 floor 색상 위에서도 글자가 잘 보이도록 중간 명도/채도 팔레트 사용.
    static func sessionColor(forParentID agentID: String) -> NSColor {
        var hash: UInt32 = 2166136261
        for byte in agentID.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        let hue = CGFloat(hash % 1000) / 1000.0
        return NSColor(hue: hue, saturation: 0.55, brightness: 0.55, alpha: 1)
    }

    // 미팅룸 동적 레이아웃: N개 세션 그룹 수에 따라 테이블 Y 간격 자동 조정
    private static let meetingMarginY: CGFloat = 30
    private static let meetingMaxPitch: CGFloat = 120
    /// 세션이 없어도 항상 유지되는 최소 테이블 수
    private static let minMeetingTables: Int = 2
    private static func meetingPitch(groupCount: Int) -> CGFloat {
        let avail = splitY - 2 * meetingMarginY
        guard groupCount > 0 else { return meetingMaxPitch }
        return min(meetingMaxPitch, avail / CGFloat(groupCount))
    }
    private static func meetingTableY(index: Int, groupCount: Int) -> CGFloat {
        let pitch = meetingPitch(groupCount: groupCount)
        return meetingMarginY + pitch * (CGFloat(index) + 0.5)
    }

    // 가구 고정 Y
    private static let furnitureY: CGFloat = 30

    // 문(doorway) 크기 및 위치
    private static let doorSize: CGFloat = 80
    // 수평 벽의 문: 일하는방↔휴게실(왼쪽), 휴게실↔미팅룸(오른쪽)
    private static let hDoorLeftX: CGFloat  = splitX / 2          // ~105
    private static let hDoorRightX: CGFloat = splitX + splitX / 2 // ~315
    // 수직 벽의 문: 일하는방↔미팅룸 (수직 벽 중간)
    private static let vDoorY: CGFloat = splitY / 2               // ~174

    // MARK: - Init

    init(size: CGSize, provider: PixelCharacterProvider) {
        self.provider = provider
        super.init(size: size)
        backgroundColor = .clear
        setupFloor()
        setupRoomDividers()
        setupWallFaces()
        setupRestZone()
        setupWorkZone()
        setupMeetingRoom()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Combine binding

    /// Binds this scene to an agents publisher.
    func bind(to agentsPublisher: AnyPublisher<[Agent], Never>) {
        agentsPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] agents in
                self?.synchronize(agents: agents)
            }
            .store(in: &cancellables)
    }

    // MARK: - Synchronization (internal for testing)

    /// Synchronizes characterNodes to the given agent list.
    func synchronize(agents: [Agent]) {
        isPaused = false
        allIdleSince = nil

        // 부모 에이전트 + 활성 서브에이전트 flat 목록
        // 조건: 부모가 활성(non-idle)일 때만, 그 중 활성 서브에이전트만 포함
        var flatAgents = [Agent]()
        var sessionColors: [String: NSColor] = [:]  // agentID → team color (부모+서브 동일)
        for agent in agents {
            flatAgents.append(agent)
            if agent.status != .idle {
                let activeSubs = agent.subagents.filter { $0.status != .idle }
                if !activeSubs.isEmpty {
                    let color = Self.sessionColor(forParentID: agent.id)
                    sessionColors[agent.id] = color
                    for sub in activeSubs {
                        flatAgents.append(sub)
                        sessionColors[sub.id] = color
                    }
                } else {
                    flatAgents += activeSubs
                }
            }
        }

        let incomingIDs = Set(flatAgents.map { $0.id })
        let existingIDs = Set(characterNodes.keys)

        // Remove departed agents
        for id in existingIDs.subtracting(incomingIDs) {
            if let node = characterNodes.removeValue(forKey: id) {
                node.fadeOutAndRemove()
            }
            currentZones.removeValue(forKey: id)
        }

        // 존별 인덱스 계산
        // 미팅룸: 서브에이전트가 있는 부모 + 서브에이전트 본인, 또는 waitingApproval
        let meetingAgents = flatAgents.filter { isInMeeting($0) }
        let restAgents    = flatAgents.filter { !isInMeeting($0) && $0.status == .idle }
        let workAgents    = flatAgents.filter { !isInMeeting($0) && isWorkStatus($0.status) }

        var meetingIndexMap: [String: Int] = [:]
        var restIndexMap: [String: Int] = [:]
        var workSlotMap: [String: Int] = [:]
        for (i, a) in restAgents.enumerated()    { restIndexMap[a.id] = i }
        for (i, a) in workAgents.enumerated()    { workSlotMap[a.id] = i }

        // 세션별로 미팅 테이블 배정: 부모(또는 독립 waitingApproval) = 새 테이블, 서브에이전트 = 같은 테이블.
        // 같은 테이블 4좌석 초과 시 테이블 추가.
        // composite index: tableIdx*4 + seatIdx
        var currentTableIdx = -1
        var currentSeat = 0
        for agent in meetingAgents {
            if !agent.isSubagent {
                currentTableIdx += 1
                currentSeat = 0
            } else if currentSeat >= 4 {
                currentTableIdx += 1
                currentSeat = 0
            }
            meetingIndexMap[agent.id] = currentTableIdx * 4 + currentSeat
            currentSeat += 1
        }
        let newGroupCount = max(0, currentTableIdx + 1)
        if newGroupCount != meetingGroupCount {
            rebuildMeetingTables(count: max(Self.minMeetingTables, newGroupCount))
            meetingGroupCount = newGroupCount
        }

        // Add new agents / update existing
        for agent in flatAgents {
            let workSlot  = workSlotMap[agent.id] ?? 0
            let targetZone = zoneForAgent(agent, workSlot: workSlot)

            let indexInZone: Int = {
                switch targetZone {
                case .rest: return restIndexMap[agent.id] ?? 0
                case .wait: return meetingIndexMap[agent.id] ?? 0
                case .work: return workSlot
                }
            }()
            let dest = destPoint(for: targetZone, indexInZone: indexInZone)

            if let existing = characterNodes[agent.id] {
                let previousZone = currentZones[agent.id]
                existing.update(status: agent.status, task: agent.currentTask)

                if previousZone != targetZone {
                    // 존 이동: wander 정지 후 새 목적지로 걸어감
                    existing.stopWandering()
                    let waypoints = doorWaypoints(from: previousZone ?? targetZone, to: targetZone)
                    currentZones[agent.id] = targetZone
                    let agentID = agent.id
                    existing.walkPath(through: waypoints, to: dest) { [weak existing, weak self] in
                        // 도착 후에도 여전히 휴게실이면 wander 시작 (중간에 zone 변경되었으면 skip)
                        guard let self, let existing,
                              self.currentZones[agentID] == .rest else { return }
                        existing.startWandering(
                            bounds: Self.restWanderBounds,
                            interestPoints: Self.restInterestPoints,
                            otherIdlePositions: { [weak self, weak existing] in
                                self?.otherIdlePositions(excluding: existing) ?? []
                            }
                        )
                    }
                } else if case .rest = targetZone {
                    // 이미 휴게실 안 → wander가 position 관리, 덮어쓰지 않음
                } else {
                    existing.position = dest
                }
            } else {
                let charSize = characterSize(forCount: flatAgents.count)
                let node = PixelCharacterNode(
                    agentID: agent.id,
                    name: agent.name,
                    status: agent.status,
                    task: agent.currentTask,
                    provider: provider,
                    characterSize: charSize,
                    sessionColor: sessionColors[agent.id]
                )
                characterNodes[agent.id] = node
                currentZones[agent.id] = targetZone
                node.position = dest
                node.zPosition = 2
                addChild(node)
                // 신규 노드가 휴게실에 배치 → 바로 wander 시작
                if case .rest = targetZone {
                    node.startWandering(
                        bounds: Self.restWanderBounds,
                        interestPoints: Self.restInterestPoints,
                        otherIdlePositions: { [weak self, weak node] in
                            self?.otherIdlePositions(excluding: node) ?? []
                        }
                    )
                }
            }
        }

        repositionWorkFurniture(allAgents: agents)
    }

    /// Returns the character node for a given agent ID (used in tests).
    func characterNode(forID id: String) -> PixelCharacterNode? {
        characterNodes[id]
    }

    /// Forces all character nodes to reload textures from provider.
    func refreshAllCharacterTextures() {
        for node in characterNodes.values {
            node.refreshTextures()
        }
    }

    /// 현재 휴게실에 있는 (wander 중인) 다른 캐릭터들의 위치 — 분산 로직용.
    fileprivate func otherIdlePositions(excluding node: PixelCharacterNode?) -> [CGPoint] {
        var positions: [CGPoint] = []
        for (id, n) in characterNodes where n !== node {
            if case .rest = currentZones[id] {
                positions.append(n.position)
            }
        }
        return positions
    }

    // MARK: - Zone logic

    private func isWorkStatus(_ status: AgentStatus) -> Bool {
        switch status {
        case .working, .thinking, .error: return true
        default: return false
        }
    }

    /// 에이전트가 미팅룸에 가야 하는지 판단
    /// - 서브에이전트 본인이면 → 미팅룸
    /// - waitingApproval 상태면 → 미팅룸
    /// - 부모 세션: 현재 **실행 중인 서브에이전트가 하나라도 있을 때만** 미팅룸 (팀 미팅)
    private func isInMeeting(_ agent: Agent) -> Bool {
        if agent.isSubagent { return true }
        if agent.status == .waitingApproval { return true }
        guard agent.status != .idle else { return false }
        return agent.subagents.contains { $0.status != .idle }
    }

    private func zoneForAgent(_ agent: Agent, workSlot: Int) -> Zone {
        if isInMeeting(agent) { return .wait }
        switch agent.status {
        case .idle:                         return .rest
        case .working, .thinking, .error:   return .work(slot: workSlot)
        case .waitingApproval:              return .wait
        }
    }

    private func zone(for status: AgentStatus, workSlot: Int) -> Zone {
        switch status {
        case .idle: return .rest
        case .waitingApproval: return .wait
        case .working, .thinking, .error: return .work(slot: workSlot)
        }
    }

    /// 두 존 사이 이동 경유지(문 통과 지점) 반환
    private func doorWaypoints(from: Zone, to: Zone) -> [CGPoint] {
        let sY = Self.splitY
        let sX = Self.splitX
        let lX = Self.hDoorLeftX   // 수평벽 왼쪽 문 X
        let rX = Self.hDoorRightX  // 수평벽 오른쪽 문 X
        let vY = Self.vDoorY       // 수직벽 문 Y

        switch (from, to) {
        // 일하는방 ↔ 휴게실: 수평벽 왼쪽 문
        case (.work, .rest), (.rest, .work):
            return [CGPoint(x: lX, y: sY)]
        // 미팅룸 ↔ 휴게실: 수평벽 오른쪽 문
        case (.wait, .rest), (.rest, .wait):
            return [CGPoint(x: rX, y: sY)]
        // 일하는방 ↔ 미팅룸: 수직벽 문
        case (.work, .wait), (.wait, .work):
            return [CGPoint(x: sX, y: vY)]
        default:
            return []
        }
    }

    /// 존 + 인덱스에 따른 캐릭터 목적지 좌표
    private func destPoint(for zone: Zone, indexInZone: Int) -> CGPoint {
        switch zone {
        case .rest:
            return CGPoint(x: Self.restCenterX + CGFloat(indexInZone % 3 - 1) * 60,
                           y: Self.restBaseY + CGFloat(indexInZone / 3) * Self.charSpacingY)
        case .wait:
            // composite index = tableIdx*4 + seatIdx
            // seat 0,1 = 아래쪽 좌/우, seat 2,3 = 위쪽 좌/우
            let tableIdx = indexInZone / 4
            let seatIdx  = indexInZone % 4
            let col = seatIdx % 2
            let row = seatIdx / 2
            let count = max(Self.minMeetingTables, meetingGroupCount)
            let tableY = Self.meetingTableY(index: tableIdx, groupCount: count)
            let pitch  = Self.meetingPitch(groupCount: count)
            let xOff: CGFloat = col == 0 ? -Self.waitColSpacing : Self.waitColSpacing
            let yOff: CGFloat = row == 0 ? -pitch * 0.25 : pitch * 0.25
            return CGPoint(x: Self.waitCenterX + xOff, y: tableY + yOff)
        case .work(let slot):
            let col = slot % 2   // 0=왼쪽, 1=오른쪽
            let row = slot / 2   // 0=하단, 1=상단
            let charX = col == 0 ? Self.workLeftCharX : Self.workRightCharX
            let charY = Self.workBaseY + CGFloat(row) * Self.workRowSpacing + Self.workCharOffsetY
            return CGPoint(x: charX, y: charY)
        }
    }

    // MARK: - Floor setup

    private func setupFloor() {
        let container = SKNode()
        container.zPosition = -10
        container.name = "floorContainer"

        let sH = size.height
        let sY = Self.splitY
        let sX = Self.splitX
        let restH = sH - sY

        // 휴게실: 상단 전체 — 나무
        let restTex = Self.makeWoodPlankTexture(width: 64, height: 16)
        container.addChild(Self.makeTileRoom(
            texture: restTex, tileW: 64, tileH: 16,
            rect: CGRect(x: 0, y: sY, width: sX * 2, height: restH), stagger: true))

        // 일하는방: 좌하단 — 콘크리트
        let workTex = Self.makeConcreteTexture(tileSize: 20)
        container.addChild(Self.makeTileRoom(
            texture: workTex, tileW: 20, tileH: 20,
            rect: CGRect(x: 0, y: 0, width: sX, height: sY)))

        // 미팅룸: 우하단 — 체커
        let meetTex = Self.makeCheckerTexture(tileSize: 20)
        container.addChild(Self.makeTileRoom(
            texture: meetTex, tileW: 40, tileH: 40,
            rect: CGRect(x: sX, y: 0, width: sX, height: sY)))

        addChild(container)
        floorNode = container
    }

    /// 타일을 단일 CGContext로 미리 합성하여 하나의 SKSpriteNode로 반환.
    /// 개별 SKSpriteNode ~수백 개 대신 노드 1개 + 텍스처 1개로 GPU draw call 절감.
    private static func makeTileRoom(
        texture: SKTexture,
        tileW: Int, tileH: Int,
        rect: CGRect,
        stagger: Bool = false
    ) -> SKNode {
        let w = Int(ceil(rect.width))
        let h = Int(ceil(rect.height))
        guard w > 0, h > 0 else { return SKNode() }

        let tileImage = texture.cgImage()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            // Fallback: single placeholder node
            return SKNode()
        }

        // CGContext origin is bottom-left; tile rows go bottom-up to match SpriteKit coords
        let cols = Int(ceil(CGFloat(w) / CGFloat(tileW))) + 2
        let rows = Int(ceil(CGFloat(h) / CGFloat(tileH))) + 1
        for row in 0..<rows {
            let offsetX: CGFloat = stagger && (row % 2 != 0) ? CGFloat(tileW) / 2 : 0
            for col in 0..<cols {
                let dx = CGFloat(col * tileW) - offsetX
                let dy = CGFloat(row * tileH)
                let destRect = CGRect(x: dx, y: dy, width: CGFloat(tileW), height: CGFloat(tileH))
                ctx.draw(tileImage, in: destRect)
            }
        }

        guard let composited = ctx.makeImage() else { return SKNode() }
        let compositedTex = SKTexture(cgImage: composited)
        compositedTex.filteringMode = .nearest

        let sprite = SKSpriteNode(texture: compositedTex,
                                  size: CGSize(width: CGFloat(w), height: CGFloat(h)))
        sprite.anchorPoint = .zero
        sprite.position = rect.origin
        return sprite
    }

    // 회색 콘크리트 타일
    private static func makeConcreteTexture(tileSize: Int) -> SKTexture {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: tileSize, height: tileSize,
            bitsPerComponent: 8, bytesPerRow: tileSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return SKTexture() }

        ctx.setFillColor(NSColor(white: 0.45, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: tileSize, height: tileSize))
        // grout lines
        ctx.setFillColor(NSColor(white: 0.28, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: tileSize - 1, width: tileSize, height: 1))
        ctx.fill(CGRect(x: tileSize - 1, y: 0, width: 1, height: tileSize))
        // highlight
        ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: tileSize, height: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: tileSize))

        guard let img = ctx.makeImage() else { return SKTexture() }
        let tex = SKTexture(cgImage: img)
        tex.filteringMode = .nearest
        return tex
    }

    // 따뜻한 오크 나무 판자
    private static func makeWoodPlankTexture(width: Int, height: Int) -> SKTexture {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return SKTexture() }

        ctx.setFillColor(NSColor(red: 0.72, green: 0.52, blue: 0.30, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let grainColor = NSColor(red: 0.62, green: 0.44, blue: 0.24, alpha: 1).cgColor
        ctx.setFillColor(grainColor)
        for gy in [height / 4, height / 2, height * 3 / 4] {
            ctx.fill(CGRect(x: 0, y: gy, width: width, height: 1))
        }
        ctx.setFillColor(NSColor(red: 0.45, green: 0.30, blue: 0.15, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: height - 1, width: width, height: 1))
        ctx.fill(CGRect(x: width - 1, y: 0, width: 1, height: height))
        ctx.setFillColor(NSColor(red: 0.82, green: 0.62, blue: 0.38, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 1))

        guard let img = ctx.makeImage() else { return SKTexture() }
        let tex = SKTexture(cgImage: img)
        tex.filteringMode = .nearest
        return tex
    }

    // 베이지 체커보드 타일
    private static func makeCheckerTexture(tileSize: Int) -> SKTexture {
        let s = tileSize * 2  // 2x2 체커 패턴을 한 텍스처에
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: s, height: s,
            bitsPerComponent: 8, bytesPerRow: s * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return SKTexture() }

        let light = NSColor(red: 0.88, green: 0.82, blue: 0.72, alpha: 1).cgColor
        let dark  = NSColor(red: 0.72, green: 0.66, blue: 0.56, alpha: 1).cgColor
        ctx.setFillColor(light)
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        ctx.setFillColor(dark)
        ctx.fill(CGRect(x: 0, y: 0, width: tileSize, height: tileSize))
        ctx.fill(CGRect(x: tileSize, y: tileSize, width: tileSize, height: tileSize))
        // grout
        ctx.setFillColor(NSColor(white: 0.5, alpha: 0.3).cgColor)
        ctx.fill(CGRect(x: 0, y: s - 1, width: s, height: 1))
        ctx.fill(CGRect(x: s - 1, y: 0, width: 1, height: s))

        guard let img = ctx.makeImage() else { return SKTexture() }
        let tex = SKTexture(cgImage: img)
        tex.filteringMode = .nearest
        return tex
    }

    // MARK: - Room dividers (T자형)

    private static let wallThickness: CGFloat = 12

    private func setupRoomDividers() {
        let t = Self.wallThickness
        let sY = Self.splitY
        let sX = Self.splitX
        let sW = Self.sceneW
        let d  = Self.doorSize

        // 수평 벽 (Y=splitY): 3구간 — 왼쪽 문, 오른쪽 문 비움
        // [0 ~ hDoorLeftX-d/2] [hDoorLeftX+d/2 ~ hDoorRightX-d/2] [hDoorRightX+d/2 ~ sceneW]
        let hSegs: [(CGFloat, CGFloat)] = [
            (0,                            Self.hDoorLeftX - d / 2),
            (Self.hDoorLeftX + d / 2,      Self.hDoorRightX - d / 2),
            (Self.hDoorRightX + d / 2,     sW)
        ]
        for (x0, x1) in hSegs where x1 > x0 {
            let w = x1 - x0
            let tex = Self.makeBrickWallTexture(width: Int(w), height: Int(t))
            let seg = SKSpriteNode(texture: tex, size: CGSize(width: w, height: t))
            seg.anchorPoint = CGPoint(x: 0, y: 0.5)
            seg.position = CGPoint(x: x0, y: sY)
            seg.zPosition = 5
            addChild(seg)
        }

        // 수직 벽 (X=splitX, Y=0~splitY): 2구간 — 중간 문 비움
        let vSegs: [(CGFloat, CGFloat)] = [
            (0,                        Self.vDoorY - d / 2),
            (Self.vDoorY + d / 2,      sY)
        ]
        for (y0, y1) in vSegs where y1 > y0 {
            let h = y1 - y0
            let tex = Self.makeBrickWallTexture(width: Int(t), height: Int(h))
            let seg = SKSpriteNode(texture: tex, size: CGSize(width: t, height: h))
            seg.anchorPoint = CGPoint(x: 0.5, y: 0)
            seg.position = CGPoint(x: sX, y: y0)
            seg.zPosition = 5
            addChild(seg)
        }
    }

    // MARK: - Wall faces (벽 앞면 패널)

    private static let wallFaceH: CGFloat = 40

    private func setupWallFaces() {
        let t  = Self.wallThickness
        let sY = Self.splitY
        let sW = Self.sceneW
        let d  = Self.doorSize
        // 벽 하단 = splitY - t/2, 앞면은 그 아래로 wallFaceH만큼
        let faceBottom = sY - t / 2 - Self.wallFaceH
        let faceColor  = NSColor(red: 0.88, green: 0.84, blue: 0.78, alpha: 1)

        // 수평 벽과 동일한 3구간 (문 갭 유지)
        let hSegs: [(CGFloat, CGFloat)] = [
            (0,                            Self.hDoorLeftX  - d / 2),
            (Self.hDoorLeftX  + d / 2,     Self.hDoorRightX - d / 2),
            (Self.hDoorRightX + d / 2,     sW)
        ]
        for (x0, x1) in hSegs where x1 > x0 {
            let w = x1 - x0
            let panel = SKSpriteNode(color: faceColor, size: CGSize(width: w, height: Self.wallFaceH))
            panel.anchorPoint = CGPoint(x: 0, y: 0)
            panel.position    = CGPoint(x: x0, y: faceBottom)
            panel.zPosition   = 0   // 바닥(-10) 위, 가구(1)·캐릭터(2) 아래
            addChild(panel)

            // 패널 상단 그림자 선 (벽 하단과 이어지는 느낌)
            let shadow = SKSpriteNode(color: NSColor(white: 0.35, alpha: 0.4),
                                      size: CGSize(width: w, height: 1.5))
            shadow.anchorPoint = CGPoint(x: 0, y: 1)
            shadow.position    = CGPoint(x: x0, y: faceBottom + Self.wallFaceH)
            shadow.zPosition   = 0
            addChild(shadow)

            // 패널 하단 그림자 선
            let baseShadow = SKSpriteNode(color: NSColor(white: 0.2, alpha: 0.3),
                                          size: CGSize(width: w, height: 1))
            baseShadow.anchorPoint = CGPoint(x: 0, y: 0)
            baseShadow.position    = CGPoint(x: x0, y: faceBottom)
            baseShadow.zPosition   = 0
            addChild(baseShadow)
        }
    }

    private static func makeBrickWallTexture(width: Int, height: Int) -> SKTexture {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return SKTexture() }

        // Base wall color
        ctx.setFillColor(NSColor(red: 0.55, green: 0.50, blue: 0.45, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Brick rows (every 8px)
        let brickH = 8
        let mortar = NSColor(red: 0.35, green: 0.32, blue: 0.28, alpha: 1).cgColor
        let brickLight = NSColor(red: 0.62, green: 0.56, blue: 0.50, alpha: 1).cgColor
        ctx.setFillColor(mortar)
        var row = 0
        while row < height {
            // horizontal mortar line
            ctx.fill(CGRect(x: 0, y: row, width: width, height: 1))
            // vertical mortar — staggered per row
            let offset = ((row / brickH) % 2 == 0) ? 0 : width / 2
            ctx.fill(CGRect(x: offset, y: row, width: 1, height: brickH))
            row += brickH
        }

        // left/right edge shadow
        ctx.setFillColor(NSColor(white: 0.0, alpha: 0.25).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: height))
        ctx.fill(CGRect(x: width - 1, y: 0, width: 1, height: height))

        // highlight on second pixel from left
        ctx.setFillColor(brickLight)
        ctx.fill(CGRect(x: 1, y: 0, width: 1, height: height))

        guard let img = ctx.makeImage() else { return SKTexture() }
        let tex = SKTexture(cgImage: img)
        tex.filteringMode = .nearest
        return tex
    }

    // MARK: - REST ZONE setup (상단 전체)

    private func setupRestZone() {
        let cx = Self.restCenterX
        // 소파/화분: 휴게실 맨 위쪽에 배치
        let topY = Self.splitY + 150

        // SOFA_FRONT: 정면 바라보는 소파
        let sofaTex = SKTexture(imageNamed: "SOFA_FRONT")
        sofaTex.filteringMode = .nearest

        // 소파 1 (왼쪽)
        let sofa1 = SKSpriteNode(texture: sofaTex, size: CGSize(width: 96, height: 48))
        sofa1.anchorPoint = CGPoint(x: 0.5, y: 0)
        sofa1.position = CGPoint(x: cx - 80, y: topY)
        sofa1.zPosition = 1
        addChild(sofa1)
        restZoneNodes.append(sofa1)

        // 소파 2 (오른쪽)
        let sofa2 = SKSpriteNode(texture: sofaTex, size: CGSize(width: 96, height: 48))
        sofa2.anchorPoint = CGPoint(x: 0.5, y: 0)
        sofa2.position = CGPoint(x: cx + 80, y: topY)
        sofa2.zPosition = 1
        addChild(sofa2)
        restZoneNodes.append(sofa2)

        // CUSHIONED_BENCH (테이블): 소파들 사이
        let benchTex = SKTexture(imageNamed: "CUSHIONED_BENCH")
        benchTex.filteringMode = .nearest
        let bench = SKSpriteNode(texture: benchTex, size: CGSize(width: 64, height: 32))
        bench.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        bench.position = CGPoint(x: cx, y: topY + 10)
        bench.zPosition = 1
        addChild(bench)
        restZoneNodes.append(bench)

        // 화분: 소파 바깥쪽 양끝 (맨 위)
        let plantSize = CGSize(width: 22, height: 34)
        let plantLeftTex = SKTexture(imageNamed: "PLANT_LEFT")
        plantLeftTex.filteringMode = .nearest
        let plantLeft = SKSpriteNode(texture: plantLeftTex, size: plantSize)
        plantLeft.anchorPoint = CGPoint(x: 0.5, y: 0)
        plantLeft.position = CGPoint(x: cx - 80 - 70, y: topY)
        plantLeft.zPosition = 1
        addChild(plantLeft)
        restZoneNodes.append(plantLeft)

        let plantRightTex = SKTexture(imageNamed: "PLANT_RIGHT")
        plantRightTex.filteringMode = .nearest
        let plantRight = SKSpriteNode(texture: plantRightTex, size: plantSize)
        plantRight.anchorPoint = CGPoint(x: 0.5, y: 0)
        plantRight.position = CGPoint(x: cx + 80 + 70, y: topY)
        plantRight.zPosition = 1
        addChild(plantRight)
        restZoneNodes.append(plantRight)

        // 냉장고: 자판기 왼쪽
        let fridgeTex = SKTexture(imageNamed: "FRIDGE")
        fridgeTex.filteringMode = .nearest
        let fridge = SKSpriteNode(texture: fridgeTex, size: CGSize(width: 32, height: 64))
        fridge.anchorPoint = CGPoint(x: 0.5, y: 0)
        fridge.position = CGPoint(x: Self.sceneW - 24 - 40, y: Self.splitY + 80)
        fridge.zPosition = 1
        addChild(fridge)
        restZoneNodes.append(fridge)

        // 자판기: 휴게실 우측 벽 코너 (하단)
        let vendingTex = SKTexture(imageNamed: "VENDING_MACHINE")
        vendingTex.filteringMode = .nearest
        let vending = SKSpriteNode(texture: vendingTex, size: CGSize(width: 32, height: 64))
        vending.anchorPoint = CGPoint(x: 0.5, y: 0)
        vending.position = CGPoint(x: Self.sceneW - 24, y: Self.splitY + 80)
        vending.zPosition = 1
        addChild(vending)
        restZoneNodes.append(vending)
    }

    // MARK: - Meeting zone setup (우하단)

    private func setupMeetingRoom() {
        // 초기 테이블: 세션이 없어도 기본 N개는 보이도록 배치.
        // 이후 세션 그룹 수에 맞춰 rebuildMeetingTables()에서 증감.
        rebuildMeetingTables(count: Self.minMeetingTables)

        // 벽 앞면 패널 중앙 Y: splitY - wallThickness/2 - wallFaceH/2
        let wallFaceCenterY = Self.splitY - Self.wallThickness / 2 - Self.wallFaceH / 2

        // 액자 (작은): 미팅룸 상단 벽 중간 구간 왼쪽, 원본 16×23 → 1배
        let frameSmallTex = SKTexture(imageNamed: "FRAME_SMALL")
        frameSmallTex.filteringMode = .nearest
        let frameSmall = SKSpriteNode(texture: frameSmallTex, size: CGSize(width: 16, height: 23))
        frameSmall.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        frameSmall.position = CGPoint(x: Self.splitX + 30, y: wallFaceCenterY)
        frameSmall.zPosition = 2
        addChild(frameSmall)
        meetingZoneNodes.append(frameSmall)

        // 액자 (큰): 미팅룸 상단 벽 우측 구간 중앙, 원본 32×32 → 1배
        let frameLargeTex = SKTexture(imageNamed: "FRAME_LARGE")
        frameLargeTex.filteringMode = .nearest
        let frameLarge = SKSpriteNode(texture: frameLargeTex, size: CGSize(width: 32, height: 32))
        frameLarge.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        frameLarge.position = CGPoint(x: (Self.hDoorRightX + Self.doorSize / 2 + Self.sceneW) / 2,
                                      y: wallFaceCenterY)
        frameLarge.zPosition = 2
        addChild(frameLarge)
        meetingZoneNodes.append(frameLarge)
    }

    /// 미팅 테이블을 그룹 수에 맞춰 재생성 (동적 레이아웃).
    private func rebuildMeetingTables(count: Int) {
        for node in meetingTableNodes { node.removeFromParent() }
        meetingTableNodes.removeAll()
        guard count > 0 else { return }

        let tableTex = SKTexture(imageNamed: "MEETING_TABLE")
        tableTex.filteringMode = .nearest
        let tableSize = CGSize(width: 45, height: 72)

        for i in 0..<count {
            let tableY = Self.meetingTableY(index: i, groupCount: count)
            let table = SKSpriteNode(texture: tableTex, size: tableSize)
            table.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            table.position = CGPoint(x: Self.waitCenterX, y: tableY)
            table.zPosition = 1
            addChild(table)
            meetingTableNodes.append(table)
        }
    }

    // MARK: - Work zone setup (permanent desks)

    private func setupWorkZone() {
        // 2×2 그리드: slot 0=왼쪽하단, 1=오른쪽하단, 2=왼쪽상단, 3=오른쪽상단
        // col 0 (왼쪽): xScale=-1 (책상/PC 왼쪽 향함), 캐릭터 오른쪽에 위치
        // col 1 (오른쪽): xScale=+1 (180° 회전, 오른쪽 향함), 캐릭터 왼쪽에 위치
        let deskTex = SKTexture(imageNamed: "DESK_SIDE")
        deskTex.filteringMode = .nearest
        let pcTex = SKTexture(imageNamed: "PC_SIDE")
        pcTex.filteringMode = .nearest

        let colXs: [CGFloat] = [Self.workLeftDeskX, Self.workRightDeskX]

        for slot in 0..<Self.workDeskSlots {
            let col = slot % 2   // 0=왼쪽, 1=오른쪽
            let row = slot / 2   // 0=하단, 1=상단
            let cx = colXs[col]
            let charY = Self.workBaseY + CGFloat(row) * Self.workRowSpacing
            let deskY = charY - 40
            let isRight = col == 1

            let group = SKNode()
            group.position = CGPoint(x: cx, y: deskY)
            group.zPosition = 1

            let desk = SKSpriteNode(texture: deskTex, size: CGSize(width: 32, height: 128))
            desk.anchorPoint = CGPoint(x: 0.5, y: 0)
            desk.xScale = isRight ? 1 : -1
            desk.position = .zero
            desk.zPosition = 0
            group.addChild(desk)

            let pc = SKSpriteNode(texture: pcTex, size: CGSize(width: 32, height: 64))
            pc.anchorPoint = CGPoint(x: 0.5, y: 0)
            pc.xScale = isRight ? 1 : -1
            pc.position = CGPoint(x: 0, y: 32)
            pc.zPosition = 1
            group.addChild(pc)

            addChild(group)
            workDeskNodes.append(group)
        }

        // 책장 2개: 왼쪽 위 벽앞 (수평 벽 안쪽, 왼쪽 구석)
        // z=-1: wall face(z=0)가 책장 위에 그려져 자연스러운 깊이감
        // shelfY: 책장 상단이 벽돌 벽 하단(splitY - wallThickness/2 = 342) 안에 들어오도록 설정
        let shelfTex = SKTexture(imageNamed: "BOOKSHELF")
        shelfTex.filteringMode = .nearest
        let shelfSize = CGSize(width: 32, height: 64)  // 원본 16×32 → 2배
        // 상단 = shelfY + 64 ≤ 342 → shelfY ≤ 278. 여유 10px: 268
        let shelfY = Self.splitY - Self.wallThickness / 2 - 74

        for i in 0..<2 {
            let shelf = SKSpriteNode(texture: shelfTex, size: shelfSize)
            shelf.anchorPoint = CGPoint(x: 0.5, y: 0)
            shelf.position = CGPoint(x: CGFloat(15 + i * 34), y: shelfY)
            shelf.zPosition = 1
            addChild(shelf)
            workDeskNodes.append(shelf)
        }
    }

    private func updateFurnitureForZone(
        agentID: String, zone: Zone, x: CGFloat, status: AgentStatus
    ) {
        // Desks are permanent — nothing to create or remove
    }

    private func repositionWorkFurniture(allAgents: [Agent]) {
        // Desks are fixed at init — no repositioning needed
        _ = allAgents
    }

    // MARK: - Character size calculation

    /// Returns character size in points. Reduces below 32 when count >= 10 (min 24).
    func characterSize(forCount count: Int) -> Int {
        let defaultSize = 32
        let minSize = 24
        guard count >= 10 else { return defaultSize }

        // For 10+ characters, scale down to fit scene width.
        // Factor 0.65 ensures 10 chars in 480px → 31 (< 32) while staying >= minSize.
        let sceneWidth = CGFloat(size.width)
        let proposed = Int(sceneWidth / CGFloat(count) * 0.65)
        return max(min(proposed, defaultSize - 1), minSize)
    }

    // MARK: - Energy saving

    override func update(_ currentTime: TimeInterval) {
        guard !characterNodes.isEmpty else { return }

        let allIdle = characterNodes.values.allSatisfy {
            $0.currentStatus == .idle || $0.currentStatus == .thinking
        }

        if allIdle {
            if allIdleSince == nil { allIdleSince = Date() }
            if let since = allIdleSince,
                Date().timeIntervalSince(since) > Self.idlePauseThreshold
            {
                isPaused = true
            }
        } else {
            allIdleSince = nil
        }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        // No-op: zone positions are recalculated on next synchronize
    }
}
