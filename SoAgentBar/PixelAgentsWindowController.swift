import AppKit
import SwiftUI
import Combine

// MARK: - PixelAgentsWindowController

/// Manages the lifecycle of the floating pixel agents window.
@MainActor
final class PixelAgentsWindowController: NSWindowController {

    private let store: AgentStore
    private let scene: PixelAgentsScene
    private let provider = SpriteSheetPixelProvider()
    private var cancellables = Set<AnyCancellable>()

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

        let skView = SKViewRepresentable(scene: scene)
        win.contentView = NSHostingView(rootView: skView)

        self.window = win
        observeWindowFrame()
    }

    // MARK: - Store binding

    private func bindToStore() {
        // Show/hide based on visibility flag and agent count
        store.$isPixelWindowVisible
            .combineLatest(store.$agents)
            .receive(on: RunLoop.main)
            .sink { [weak self] visible, agents in
                guard let self else { return }
                if visible && !agents.isEmpty {
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
                self.scene.refreshAllCharacterTextures()
            }
            .store(in: &cancellables)
    }

    // MARK: - Show / Hide

    func showWindow() {
        window?.orderFront(nil)
    }

    func hideWindow() {
        window?.orderOut(nil)
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
        // Default: bottom-right of main screen
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: screen.maxX - 420 - 20,
            y: screen.minY + 20,
            width: 420,
            height: 560
        )
    }
}
