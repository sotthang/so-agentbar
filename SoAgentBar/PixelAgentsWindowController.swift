import AppKit
import SwiftUI
import SpriteKit
import Combine

// MARK: - PixelAgentsWindowController

/// Manages the lifecycle of the floating pixel agents window.
@MainActor
final class PixelAgentsWindowController: NSWindowController {

    private let store: AgentStore
    private let scene: PixelAgentsScene
    private let provider = SpriteSheetPixelProvider()
    private var cancellables = Set<AnyCancellable>()
    private weak var skView: SKView?

    /// 테스트 전용 scene 접근자.
    var pixelScene: PixelAgentsScene { scene }

    private static let windowFrameKey = "pixelWindowFrame"

    // MARK: - Init

    init(store: AgentStore) {
        self.store = store
        self.scene = PixelAgentsScene(
            size: CGSize(width: 420, height: 560),
            provider: provider
        )
        super.init(window: nil)
        configureWindow()
        scene.spawnSystemPetsIfNeeded()
        bindToStore()
        // 픽셀 창: idle 상태로 10분 초과한 에이전트는 표시 제외
        let pixelAgents = store.$agents
            .map { agents in
                agents.filter { agent in
                    agent.status != .idle ||
                    Date().timeIntervalSince(agent.lastActivity) < 600
                }
            }
            .eraseToAnyPublisher()
        scene.bind(to: pixelAgents)

        // SystemMetrics 구독 → scene에 전달
        store.systemMetricsMonitor.$metrics
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] m in
                self?.scene.applyMetrics(m)
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Window setup

    private func configureWindow() {
        let frame = restoreOrDefaultFrame()
        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        win.level = .floating
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.isMovableByWindowBackground = true

        let view = SKView()
        view.allowsTransparency = true
        view.preferredFramesPerSecond = 20
        view.presentScene(scene)
        win.contentView = view
        self.skView = view

        self.window = win
        observeWindowFrame()
    }

    // MARK: - Store binding

    private func bindToStore() {
        // Show/hide based on visibility flag (AC8: agents.isEmpty 조건 제거)
        store.$isPixelWindowVisible
            .combineLatest(store.$agents)
            .receive(on: RunLoop.main)
            .sink { [weak self] visible, _ in
                guard let self else { return }
                if visible {
                    self.showWindow()
                } else {
                    self.hideWindow()
                }
            }
            .store(in: &cancellables)

        // Opacity
        store.$pixelWindowOpacity
            .receive(on: RunLoop.main)
            .sink { [weak self] opacity in
                self?.window?.alphaValue = CGFloat(opacity)
            }
            .store(in: &cancellables)

        // Character overrides — update provider and refresh all character textures
        store.$pixelCharacterOverrides
            .receive(on: RunLoop.main)
            .sink { [weak self] overrides in
                guard let self else { return }
                self.provider.characterOverrides = overrides
                self.provider.invalidateCache()
                self.scene.refreshAllCharacterTextures()
            }
            .store(in: &cancellables)

        // Reset window frame request from settings
        store.pixelWindowResetRequest
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resetFrame() }
            .store(in: &cancellables)
    }

    // MARK: - Reset

    /// Clears the saved window frame and restores the default position/size.
    func resetFrame() {
        UserDefaults.standard.removeObject(forKey: Self.windowFrameKey)
        guard let win = window else { return }
        let defaultFrame = Self.defaultFrame()
        win.setFrame(defaultFrame, display: true, animate: true)
    }

    private static func defaultFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: screen.maxX - 420 - 20,
            y: screen.minY + 20,
            width: 420,
            height: 560
        )
    }

    // MARK: - Show / Hide

    func showWindow() {
        window?.orderFront(nil)
        skView?.isPaused = false
        scene.resumeSystemPets()
    }

    func hideWindow() {
        window?.orderOut(nil)
        scene.pauseSystemPets()
        skView?.isPaused = true
    }

    // MARK: - Frame persistence

    private func observeWindowFrame() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.saveWindowFrame() }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.saveWindowFrame() }
        }
    }

    private func saveWindowFrame() {
        guard let frame = window?.frame else { return }
        let dict: [String: Double] = [
            "x": frame.origin.x,
            "y": frame.origin.y,
            "w": frame.size.width,
            "h": frame.size.height
        ]
        UserDefaults.standard.set(dict, forKey: Self.windowFrameKey)
    }

    private func restoreOrDefaultFrame() -> NSRect {
        if let dict = UserDefaults.standard.dictionary(forKey: Self.windowFrameKey) as? [String: Double],
           let x = dict["x"], let y = dict["y"], let w = dict["w"], let h = dict["h"] {
            return NSRect(x: x, y: y, width: w, height: h)
        }
        return Self.defaultFrame()
    }
}
