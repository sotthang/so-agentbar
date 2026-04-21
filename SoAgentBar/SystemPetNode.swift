import SpriteKit

// MARK: - Math helpers

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}

// MARK: - SystemPetNode

/// Agent 파이프라인과 완전히 분리된 펫 노드.
/// PixelCharacterNode 를 상속하지 않음 (D1).
final class SystemPetNode: SKNode {

    // MARK: - Parameters
    // CPU 100% 에서도 최소 3초 대기, 0% 에서는 15초 대기 — 펫이 너무 자주 움직이지 않도록.
    static let minWaitBetweenSteps: TimeInterval = 3.0
    static let maxWaitBetweenSteps: TimeInterval = 15.0
    static let minWalkSpeed: CGFloat = 80
    static let maxWalkSpeed: CGFloat = 240
    static let memoryZoneHopProbability: Double = 0.35

    // MARK: - Identity
    let kind: SystemPetKind

    // MARK: - Private state
    private var _currentWaitTime: TimeInterval
    private var _currentWalkSpeed: CGFloat
    private var _lastZoneVisited: SystemPetZone

    // MARK: - Visual children
    private let sprite: SKSpriteNode
    private let spriteSheet: SKTexture?
    private let renderSize: Int
    private var badgeLabel: SKLabelNode?
    private let badgePrefix: String

    // MARK: - Wander state
    private var cpuBounds: CGRect = .zero
    private var cpuInterestPoints: [CGPoint] = []
    private var memoryZoneBounds: [SystemPetZone: CGRect] = [:]
    private var memoryForbiddenRects: [CGRect] = []
    private var memoryDoorWaypoints: (SystemPetZone, SystemPetZone) -> [CGPoint] = { _, _ in [] }
    private enum WanderMode { case none, cpu, memory }
    private var wanderMode: WanderMode = .none

    // MARK: - Sprite sheet constants (PIPOYA 32×32, 3×4)
    private static let sheetCols: Int = 3
    private static let sheetRows: Int = 4
    private static let rowDown = 0, rowLeft = 1, rowRight = 2, rowUp = 3

    // MARK: - Init

    init(kind: SystemPetKind,
         provider: PixelCharacterProvider,
         spriteIndex: Int,
         characterSize: Int = 24) {
        self.kind = kind
        self._currentWaitTime = Self.maxWaitBetweenSteps
        self._currentWalkSpeed = Self.minWalkSpeed
        self._lastZoneVisited = .rest
        self.badgePrefix = kind == .cpu ? "CPU" : "MEM"

        self.renderSize = characterSize * 3 / 2

        // Animal sprite sheet — bundled as asset (cat_01 for CPU, dog_01 for Memory).
        // Falls back to provider-rendered texture when the asset is absent (tests).
        let imageName = kind == .cpu ? "cat_01" : "dog_01"
        let sheet = SKTexture(imageNamed: imageName)
        sheet.filteringMode = .nearest
        let sheetSize = sheet.size()
        if sheetSize.width > 0 && sheetSize.height > 0 {
            self.spriteSheet = sheet
            let idleTexture = Self.frameTexture(sheet: sheet, row: Self.rowDown, col: 1)
            self.sprite = SKSpriteNode(texture: idleTexture,
                                       size: CGSize(width: renderSize, height: renderSize))
        } else {
            self.spriteSheet = nil
            let fallbackID = "system-pet-\(kind == .cpu ? "cpu" : "memory")-\(spriteIndex)"
            let tex = provider.textures(for: .idle, agentID: fallbackID, size: characterSize).first ?? SKTexture()
            self.sprite = SKSpriteNode(texture: tex,
                                       size: CGSize(width: renderSize, height: renderSize))
        }
        self.sprite.zPosition = 0

        super.init()
        addChild(sprite)
        addKindBadge()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func addKindBadge() {
        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.text = "\(badgePrefix) 100%"   // 최대 길이로 측정하여 레이아웃 고정
        label.fontSize = 8
        label.fontColor = .white
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .baseline
        label.zPosition = 2

        let glyphFrame = label.calculateAccumulatedFrame()
        let padX: CGFloat = 4
        let padY: CGFloat = 2
        let bgW = glyphFrame.width + padX * 2
        let bgH = glyphFrame.height + padY * 2
        let centerY = CGFloat(renderSize) / 2 + 2 + bgH / 2
        let rect = CGRect(x: -bgW / 2, y: -bgH / 2, width: bgW, height: bgH)
        let badge = SKShapeNode(path: CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
        badge.fillColor = NSColor(white: 0, alpha: 0.65)
        badge.strokeColor = .clear
        badge.zPosition = 1
        badge.position = CGPoint(x: 0, y: centerY)
        addChild(badge)

        // glyph 박스 중앙을 badge 중앙(centerY) 에 맞추기 위해 baseline 을 보정한다
        label.text = badgePrefix
        label.position = CGPoint(x: 0, y: centerY - glyphFrame.midY)
        addChild(label)
        badgeLabel = label
    }

    // MARK: - Public API

    func updateMetric(_ value: Double) {
        let clamped = min(max(value, 0), 100)
        let t = clamped / 100.0
        _currentWaitTime = lerp(Self.maxWaitBetweenSteps, Self.minWaitBetweenSteps, t)
        _currentWalkSpeed = CGFloat(lerp(Double(Self.minWalkSpeed), Double(Self.maxWalkSpeed), t))
        badgeLabel?.text = "\(badgePrefix) \(Int(clamped.rounded()))%"
    }

    func forceZoneHop(to zone: SystemPetZone) {
        _lastZoneVisited = zone
    }

    func stopAllMovement() {
        removeAllActions()
        sprite.removeAction(forKey: "walk")
    }

    /// CPU pet: 주어진 bounds 안에서만 wander. interestPoints 가 비어있지 않으면 40% 확률로 선택.
    func startCPUWandering(bounds: CGRect, interestPoints: [CGPoint]) {
        wanderMode = .cpu
        cpuBounds = bounds
        cpuInterestPoints = interestPoints
        scheduleNextCPUStep(initial: true)
    }

    /// Memory pet: 여러 존을 순회. 각 스텝에서 확률적으로 존 이동 또는 현재 존 내 이동.
    /// - Parameter doorWaypointsBetween: 두 존 사이 이동 시 경유해야 할 문 좌표를 반환. 벽 통과 방지.
    func startMemoryWandering(
        zoneBounds: [SystemPetZone: CGRect],
        forbiddenRects: [CGRect],
        doorWaypointsBetween: @escaping (SystemPetZone, SystemPetZone) -> [CGPoint] = { _, _ in [] }
    ) {
        wanderMode = .memory
        memoryZoneBounds = zoneBounds
        memoryForbiddenRects = forbiddenRects
        memoryDoorWaypoints = doorWaypointsBetween
        scheduleNextMemoryStep(initial: true)
    }

    /// 씬 재활성 시 직전 wander mode 재시작.
    func resumeMovement() {
        switch wanderMode {
        case .cpu:    scheduleNextCPUStep(initial: true)
        case .memory: scheduleNextMemoryStep(initial: true)
        case .none:   break
        }
    }

    // MARK: - CPU wander scheduling

    private func scheduleNextCPUStep(initial: Bool) {
        let wait = initial ? Double.random(in: 0.5...2.0) : _currentWaitTime
        let action = SKAction.sequence([
            SKAction.wait(forDuration: wait),
            SKAction.run { [weak self] in self?.cpuStep() }
        ])
        run(action, withKey: "wanderTimer")
    }

    private func cpuStep() {
        guard wanderMode == .cpu else { return }
        let target = pickCPUTarget()
        walk(to: target) { [weak self] in
            guard let self, self.wanderMode == .cpu else { return }
            self.scheduleNextCPUStep(initial: false)
        }
    }

    private func pickCPUTarget() -> CGPoint {
        if !cpuInterestPoints.isEmpty && Double.random(in: 0..<1) < 0.4 {
            return cpuInterestPoints.randomElement()!
        }
        return CGPoint(
            x: CGFloat.random(in: cpuBounds.minX...cpuBounds.maxX),
            y: CGFloat.random(in: cpuBounds.minY...cpuBounds.maxY)
        )
    }

    // MARK: - Memory wander scheduling

    private func scheduleNextMemoryStep(initial: Bool) {
        let wait = initial ? Double.random(in: 0.5...2.0) : _currentWaitTime
        let action = SKAction.sequence([
            SKAction.wait(forDuration: wait),
            SKAction.run { [weak self] in self?.memoryStep() }
        ])
        run(action, withKey: "wanderTimer")
    }

    private func memoryStep() {
        guard wanderMode == .memory else { return }
        guard !memoryZoneBounds.isEmpty else { return }

        let fromZone = _lastZoneVisited
        let hopToNewZone = Double.random(in: 0..<1) < Self.memoryZoneHopProbability
        let targetZone: SystemPetZone
        if hopToNewZone, let next = pickDifferentZone(from: fromZone) {
            targetZone = next
        } else {
            targetZone = fromZone
        }
        _lastZoneVisited = targetZone

        guard let bounds = memoryZoneBounds[targetZone] else {
            scheduleNextMemoryStep(initial: false)
            return
        }
        let target = pickMemoryTarget(in: bounds)
        let waypoints = fromZone == targetZone ? [] : memoryDoorWaypoints(fromZone, targetZone)
        walkPath(through: waypoints, to: target) { [weak self] in
            guard let self, self.wanderMode == .memory else { return }
            self.scheduleNextMemoryStep(initial: false)
        }
    }

    private func walkPath(through waypoints: [CGPoint], to destination: CGPoint, completion: @escaping () -> Void) {
        guard let first = waypoints.first else {
            walk(to: destination, completion: completion)
            return
        }
        walk(to: first) { [weak self] in
            self?.walkPath(through: Array(waypoints.dropFirst()), to: destination, completion: completion)
        }
    }

    private func pickDifferentZone(from current: SystemPetZone) -> SystemPetZone? {
        let others = memoryZoneBounds.keys.filter { $0 != current }
        return others.randomElement()
    }

    private func pickMemoryTarget(in bounds: CGRect) -> CGPoint {
        for _ in 0..<10 {
            let candidate = CGPoint(
                x: CGFloat.random(in: bounds.minX...bounds.maxX),
                y: CGFloat.random(in: bounds.minY...bounds.maxY)
            )
            if !memoryForbiddenRects.contains(where: { $0.contains(candidate) }) {
                return candidate
            }
        }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    // MARK: - Walk helper + directional animation

    private func walk(to destination: CGPoint, completion: @escaping () -> Void) {
        let dx = destination.x - position.x
        let dy = destination.y - position.y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 1 else {
            position = destination
            completion()
            return
        }
        let row = walkRow(dx: dx, dy: dy)
        playWalkAnimation(row: row)

        let duration = TimeInterval(dist / _currentWalkSpeed)
        let move = SKAction.move(to: destination, duration: duration)
        run(move) { [weak self] in
            guard let self else { completion(); return }
            self.sprite.removeAction(forKey: "walk")
            if let sheet = self.spriteSheet {
                self.sprite.texture = Self.frameTexture(sheet: sheet, row: row, col: 1)
            }
            completion()
        }
    }

    private func walkRow(dx: CGFloat, dy: CGFloat) -> Int {
        if abs(dx) >= abs(dy) {
            return dx < 0 ? Self.rowLeft : Self.rowRight
        }
        return dy > 0 ? Self.rowUp : Self.rowDown
    }

    private func playWalkAnimation(row: Int) {
        guard let sheet = spriteSheet else { return }
        let frames = (0..<Self.sheetCols).map {
            Self.frameTexture(sheet: sheet, row: row, col: $0)
        }
        let anim = SKAction.animate(with: frames, timePerFrame: 0.18)
        sprite.removeAction(forKey: "walk")
        sprite.run(SKAction.repeatForever(anim), withKey: "walk")
    }

    private static func frameTexture(sheet: SKTexture, row: Int, col: Int) -> SKTexture {
        let w: CGFloat = 1.0 / CGFloat(sheetCols)
        let h: CGFloat = 1.0 / CGFloat(sheetRows)
        // SpriteKit uses bottom-left origin; row 0 is top of image.
        let v = 1.0 - h * CGFloat(row + 1)
        let u = w * CGFloat(col)
        let rect = CGRect(x: u, y: v, width: w, height: h)
        let t = SKTexture(rect: rect, in: sheet)
        t.filteringMode = .nearest
        return t
    }

    // MARK: - Test hooks (R17)

    var currentWaitTime: TimeInterval { _currentWaitTime }
    var currentWalkSpeed: CGFloat { _currentWalkSpeed }
    var lastZoneVisited: SystemPetZone { _lastZoneVisited }
}
