import SpriteKit

// MARK: - PixelCharacterNode

/// Represents a single pixel character in the SpriteKit scene.
final class PixelCharacterNode: SKNode {

    // MARK: - Public

    let agentID: String
    private(set) var currentStatus: AgentStatus

    // MARK: - Private

    private let provider: PixelCharacterProvider
    private let spriteNode: SKSpriteNode
    private var bubbleNode: SKSpriteNode?
    private var nameLabel: SKLabelNode?
    private var nameBadgeNode: SKShapeNode?
    private var speechBubbleNode: SKNode?
    private var currentSize: Int

    /// Current session badge color, or nil if no badge is shown. Exposed for tests.
    var sessionBadgeColor: NSColor? { nameBadgeNode?.fillColor }

    /// Name badge frame in this node's coordinate space. Nil when no badge.
    var nameBadgeFrame: CGRect? { nameBadgeNode?.calculateAccumulatedFrame() }

    /// Speech bubble frame (including tail) in this node's coordinate space. Nil when hidden.
    var speechBubbleFrame: CGRect? { speechBubbleNode?.calculateAccumulatedFrame() }

    /// Sprite render size: 1.5× the logical character size (keeps pixel art crisp at integer-ish scale).
    private var renderSize: Int { currentSize * 3 / 2 }
    private var spriteHalfHeight: CGFloat { CGFloat(renderSize) / 2 }

    // MARK: - Init

    /// Convenience init for tests — name and task default to empty string.
    convenience init(agentID: String, status: AgentStatus,
                     provider: PixelCharacterProvider, characterSize: Int) {
        self.init(agentID: agentID, name: "", status: status, task: "",
                  provider: provider, characterSize: characterSize)
    }

    init(agentID: String, name: String, status: AgentStatus, task: String,
         provider: PixelCharacterProvider, characterSize: Int,
         sessionColor: NSColor? = nil) {
        self.agentID = agentID
        self.currentStatus = status
        self.provider = provider
        self.currentSize = characterSize

        let textures = provider.textures(for: status, agentID: agentID, size: characterSize)
        let firstTexture = textures.first ?? SKTexture()
        let render = characterSize * 3 / 2
        self.spriteNode = SKSpriteNode(texture: firstTexture,
                                       size: CGSize(width: render, height: render))
        super.init()

        addChild(spriteNode)
        applyAnimation(for: status)

        if status == .waitingApproval {
            showBubble()
        }
        if status == .working {
            showSpeechBubble(task: task)
        }

        setupNameLabel(name: name, sessionColor: sessionColor)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Public API

    /// Convenience update for tests — task defaults to empty string.
    func update(status: AgentStatus) {
        update(status: status, task: "")
    }

    /// Updates the character to a new status and current task.
    func update(status: AgentStatus, task: String) {
        let statusChanged = status != currentStatus
        currentStatus = status
        if statusChanged {
            applyAnimation(for: status)
        }

        if status == .waitingApproval {
            showBubble()
        } else {
            hideBubble()
        }

        if status == .working {
            showSpeechBubble(task: task)
        } else {
            hideSpeechBubble()
        }
    }

    /// Forces texture reload — call when provider data changes (e.g. character override).
    func refreshTextures() {
        applyAnimation(for: currentStatus)
    }

    // MARK: - Wander (rest zone idle roaming)

    private var isWandering = false
    private var wanderBounds: CGRect = .zero
    private var wanderPoints: [CGPoint] = []
    private var otherIdlePositionsProvider: (() -> [CGPoint])?

    /// 다른 idle 캐릭터와 너무 가까운 목적지 재시도 판정용 최소 거리
    private static let wanderMinSpacing: CGFloat = 40

    /// Starts roaming randomly within `bounds`, occasionally targeting `interestPoints`.
    /// - Parameter otherIdlePositions: 다른 idle 캐릭터들의 현재 위치 (분산 로직용)
    func startWandering(
        bounds: CGRect,
        interestPoints: [CGPoint],
        otherIdlePositions: @escaping () -> [CGPoint] = { [] }
    ) {
        guard !isWandering else { return }
        isWandering = true
        wanderBounds = bounds
        wanderPoints = interestPoints
        otherIdlePositionsProvider = otherIdlePositions
        scheduleNextWanderStep(initialDelay: Double.random(in: 0.5...3))
    }

    /// Stops wandering and cancels in-flight walk.
    func stopWandering() {
        guard isWandering else { return }
        isWandering = false
        removeAllActions()
        spriteNode.removeAction(forKey: "walkAnim")
        applyAnimation(for: currentStatus)
    }

    private func scheduleNextWanderStep(initialDelay: TimeInterval) {
        let wait = SKAction.wait(forDuration: initialDelay)
        let step = SKAction.run { [weak self] in self?.wanderStep() }
        run(SKAction.sequence([wait, step]), withKey: "wanderTimer")
    }

    private func wanderStep() {
        guard isWandering else { return }
        let others = otherIdlePositionsProvider?() ?? []
        let target = pickWanderTarget(avoiding: others)
        walk(to: target) { [weak self] in
            guard let self, self.isWandering else { return }
            self.scheduleNextWanderStep(initialDelay: Double.random(in: 3...8))
        }
    }

    /// 다른 idle 캐릭터들과 최소 간격 이상 떨어진 후보를 우선 선택.
    /// 5회 재시도 후에도 적절한 후보가 없으면 마지막 후보를 그대로 사용 (수용).
    private func pickWanderTarget(avoiding others: [CGPoint]) -> CGPoint {
        var candidate: CGPoint = .zero
        for _ in 0..<5 {
            if !wanderPoints.isEmpty && Double.random(in: 0..<1) < 0.4 {
                candidate = wanderPoints.randomElement()!
            } else {
                candidate = CGPoint(
                    x: CGFloat.random(in: wanderBounds.minX...wanderBounds.maxX),
                    y: CGFloat.random(in: wanderBounds.minY...wanderBounds.maxY)
                )
            }
            let tooClose = others.contains { hypot($0.x - candidate.x, $0.y - candidate.y) < Self.wanderMinSpacing }
            if !tooClose { return candidate }
        }
        return candidate
    }

    /// Resizes the character sprite.
    func resize(to characterSize: Int) {
        currentSize = characterSize
        let render = characterSize * 3 / 2
        spriteNode.size = CGSize(width: render, height: render)
        applyAnimation(for: currentStatus)
    }

    /// Walks through waypoints then to final destination.
    func walkPath(through waypoints: [CGPoint], to destination: CGPoint, completion: (() -> Void)? = nil) {
        guard !waypoints.isEmpty else {
            walk(to: destination, completion: completion)
            return
        }
        walk(to: waypoints[0]) { [weak self] in
            self?.walkPath(through: Array(waypoints.dropFirst()), to: destination, completion: completion)
        }
    }

    /// Walks to destination with a walking animation, then calls completion.
    func walk(to destination: CGPoint, completion: (() -> Void)? = nil) {
        let dx = destination.x - position.x
        let dy = destination.y - position.y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 1 else {
            position = destination
            completion?()
            return
        }

        let walkSpeed: CGFloat = 160  // points per second
        let duration = TimeInterval(dist / walkSpeed)

        // 이동 방향에 따라 스프라이트 행 선택 (RPG Maker MV 규칙)
        // row 0 = 아래, row 1 = 왼쪽, row 2 = 오른쪽, row 3 = 위
        spriteNode.xScale = 1
        let row: Int
        if abs(dx) >= abs(dy) {
            row = dx < 0 ? SpriteSheetPixelProvider.rowLeft : SpriteSheetPixelProvider.rowRight
        } else if dy > 0 {
            row = SpriteSheetPixelProvider.rowUp
        } else {
            row = SpriteSheetPixelProvider.rowDown
        }

        spriteNode.removeAllActions()
        let walkFrames = provider.walkTextures(row: row, agentID: agentID, size: currentSize)
        let walkAnim = SKAction.animate(with: walkFrames, timePerFrame: 0.1)
        spriteNode.run(SKAction.repeatForever(walkAnim), withKey: "walkAnim")

        let moveAction = SKAction.move(to: destination, duration: duration)
        run(moveAction) { [weak self] in
            guard let self = self else { return }
            // xScale 유지 (이동 방향 그대로)
            self.spriteNode.removeAction(forKey: "walkAnim")
            self.applyAnimation(for: self.currentStatus)
            completion?()
        }
    }

    /// Fades out and removes from parent.
    func fadeOutAndRemove(duration: TimeInterval = 0.3) {
        let fade = SKAction.fadeOut(withDuration: duration)
        let remove = SKAction.removeFromParent()
        run(SKAction.sequence([fade, remove]))
    }

    // MARK: - Private

    private func applyAnimation(for status: AgentStatus) {
        spriteNode.removeAllActions()
        let textures = provider.textures(for: status, agentID: agentID, size: currentSize)
        guard !textures.isEmpty else { return }

        if textures.count == 1 {
            spriteNode.texture = textures[0]
        } else {
            let interval: TimeInterval
            switch status {
            case .idle, .thinking: interval = 0.8
            case .working:         interval = 0.25
            case .waitingApproval: interval = 0.4
            case .error:           interval = 0.3
            }
            let animate = SKAction.animate(with: textures, timePerFrame: interval)
            spriteNode.run(SKAction.repeatForever(animate))
        }

        // idle/thinking: 위아래 가벼운 bob (호흡 느낌)
        if status == .idle || status == .thinking {
            spriteNode.position = .zero
            let bob = SKAction.sequence([
                SKAction.moveBy(x: 0, y: 2, duration: 0.7),
                SKAction.moveBy(x: 0, y: -2, duration: 0.7)
            ])
            spriteNode.run(SKAction.repeatForever(bob))
        }
    }

    private static let nameBadgeHeight: CGFloat = 14
    private var nameBadgeCenterY: CGFloat { spriteHalfHeight + 2 + Self.nameBadgeHeight / 2 }

    private func setupNameLabel(name: String, sessionColor: NSColor?) {
        let text = name.count > 15 ? String(name.prefix(15)) + "…" : name

        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.text = text
        label.fontSize = 10
        label.fontColor = .white
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.zPosition = 4
        label.position = CGPoint(x: 0, y: nameBadgeCenterY)
        addChild(label)
        nameLabel = label

        updateSessionColor(sessionColor)
    }

    /// Adds, updates, or removes the name-background badge to match the current session color.
    /// Call on every sync so a node can gain/lose its badge when its parent's team changes.
    func updateSessionColor(_ sessionColor: NSColor?) {
        guard let sessionColor else {
            nameBadgeNode?.removeFromParent()
            nameBadgeNode = nil
            return
        }
        if let badge = nameBadgeNode {
            badge.fillColor = sessionColor
            return
        }
        let textWidth = nameLabel?.calculateAccumulatedFrame().width ?? 0
        let padX: CGFloat = 5
        let bgW = max(textWidth + padX * 2, 24)
        let bgH = Self.nameBadgeHeight
        let rect = CGRect(x: -bgW / 2, y: -bgH / 2, width: bgW, height: bgH)
        let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        let badge = SKShapeNode(path: path)
        badge.fillColor = sessionColor
        badge.strokeColor = .clear
        badge.alpha = 0.85
        badge.zPosition = 3
        badge.position = CGPoint(x: 0, y: nameBadgeCenterY)
        addChild(badge)
        nameBadgeNode = badge
    }

    // MARK: - Speech bubble

    private func showSpeechBubble(task: String) {
        hideSpeechBubble()

        let text = task.count > 14 ? String(task.prefix(14)) + "…" : task
        guard !text.isEmpty else { return }

        let container = SKNode()
        container.zPosition = 5

        // 텍스트 라벨 먼저 만들어 크기 측정
        let label = SKLabelNode(fontNamed: "Menlo")
        label.text = text
        label.fontSize = 8
        label.fontColor = NSColor(white: 0.1, alpha: 1)
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.position = CGPoint(x: 0, y: 1)

        let hPad: CGFloat = 6
        let vPad: CGFloat = 4
        let bubbleW = max(label.frame.width + hPad * 2, 36)
        let bubbleH: CGFloat = 14

        // 말풍선 배경 (둥근 사각형)
        let bgRect = CGRect(x: -bubbleW / 2, y: -bubbleH / 2, width: bubbleW, height: bubbleH)
        let bgPath = CGMutablePath()
        bgPath.addRoundedRect(in: bgRect, cornerWidth: 4, cornerHeight: 4)

        let bg = SKShapeNode(path: bgPath)
        bg.fillColor = NSColor.white
        bg.strokeColor = NSColor(white: 0.35, alpha: 1)
        bg.lineWidth = 0.8

        // 꼬리 (아래 방향 삼각형)
        let tailPath = CGMutablePath()
        tailPath.move(to: CGPoint(x: -4, y: -bubbleH / 2))
        tailPath.addLine(to: CGPoint(x: 4, y: -bubbleH / 2))
        tailPath.addLine(to: CGPoint(x: 0, y: -bubbleH / 2 - 5))
        tailPath.closeSubpath()

        let tail = SKShapeNode(path: tailPath)
        tail.fillColor = NSColor.white
        tail.strokeColor = NSColor(white: 0.35, alpha: 1)
        tail.lineWidth = 0.8

        // 배치: 이름 배지 위쪽 (꼬리 끝이 배지 상단을 덮지 않도록 간격 확보)
        // nameBadge top = spriteHalfHeight + 2 + nameBadgeHeight = spriteHalfHeight + 16
        // tail tip Y in container = -bubbleH/2 - 5 = -12, 4px gap → container.y = spriteHalfHeight + 32
        let nameBadgeTop = spriteHalfHeight + 2 + Self.nameBadgeHeight
        let gap: CGFloat = 4
        let tailDepth: CGFloat = bubbleH / 2 + 5
        container.position = CGPoint(x: 0, y: nameBadgeTop + gap + tailDepth)

        container.addChild(bg)
        container.addChild(tail)
        bg.addChild(label)

        addChild(container)
        speechBubbleNode = container
    }

    private func hideSpeechBubble() {
        speechBubbleNode?.removeFromParent()
        speechBubbleNode = nil
    }

    // MARK: - Approval bubble

    private func showBubble() {
        guard bubbleNode == nil else { return }
        let texture = provider.bubbleTexture(size: currentSize)
        let bubble = SKSpriteNode(texture: texture,
                                   size: CGSize(width: currentSize / 2, height: currentSize / 2))
        bubble.name = "bubbleNode"
        bubble.position = CGPoint(x: spriteHalfHeight * 0.7,
                                   y: spriteHalfHeight * 0.85)
        addChild(bubble)
        bubbleNode = bubble
    }

    private func hideBubble() {
        bubbleNode?.removeFromParent()
        bubbleNode = nil
    }
}
