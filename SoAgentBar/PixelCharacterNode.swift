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
    private var speechBubbleNode: SKNode?
    private var currentSize: Int

    // MARK: - Init

    /// Convenience init for tests — name and task default to empty string.
    convenience init(agentID: String, status: AgentStatus,
                     provider: PixelCharacterProvider, characterSize: Int) {
        self.init(agentID: agentID, name: "", status: status, task: "",
                  provider: provider, characterSize: characterSize)
    }

    init(agentID: String, name: String, status: AgentStatus, task: String,
         provider: PixelCharacterProvider, characterSize: Int) {
        self.agentID = agentID
        self.currentStatus = status
        self.provider = provider
        self.currentSize = characterSize

        let textures = provider.textures(for: status, agentID: agentID, size: characterSize)
        let firstTexture = textures.first ?? SKTexture()
        self.spriteNode = SKSpriteNode(texture: firstTexture,
                                       size: CGSize(width: characterSize, height: characterSize * 2))
        super.init()

        addChild(spriteNode)
        applyAnimation(for: status)

        if status == .waitingApproval {
            showBubble()
        }
        if status == .working {
            showSpeechBubble(task: task)
        }

        setupNameLabel(name: name, characterSize: characterSize)
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

    /// Resizes the character sprite.
    func resize(to characterSize: Int) {
        currentSize = characterSize
        spriteNode.size = CGSize(width: characterSize, height: characterSize * 2)
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

        // 이동 방향에 따라 스프라이트 행 선택
        // row 0 = 정면(아래), row 1 = 옆면(좌우), row 2 = 뒷면(위)
        let row: Int
        if abs(dx) >= abs(dy) {
            row = 1                                  // 좌우 이동 → 옆면
            spriteNode.xScale = dx < 0 ? -1 : 1
        } else if dy > 0 {
            row = 2                                  // 위로 이동 → 뒷면
            spriteNode.xScale = 1
        } else {
            row = 0                                  // 아래로 이동 → 정면
            spriteNode.xScale = 1
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
    }

    private func setupNameLabel(name: String, characterSize: Int) {
        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.text = name.count > 15 ? String(name.prefix(15)) + "…" : name
        label.fontSize = 10
        label.fontColor = .white
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .bottom
        label.position = CGPoint(x: 0, y: CGFloat(characterSize) + 2)
        label.zPosition = 3
        addChild(label)
        nameLabel = label
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

        // 배치: 이름 라벨 위쪽
        // 스프라이트 상단(+currentSize) + 이름 라벨(~12px) + 여백
        container.position = CGPoint(x: 0, y: CGFloat(currentSize) + 26)

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
        bubble.position = CGPoint(x: CGFloat(currentSize) * 0.35,
                                   y: CGFloat(currentSize) * 0.85)
        addChild(bubble)
        bubbleNode = bubble
    }

    private func hideBubble() {
        bubbleNode?.removeFromParent()
        bubbleNode = nil
    }
}
