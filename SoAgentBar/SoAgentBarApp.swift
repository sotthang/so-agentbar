import SwiftUI
import AppKit
import Carbon
import Combine
import UserNotifications
import Sparkle

@main
struct SoAgentBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Dock 없이 메뉴바 전용으로 동작 (Info.plist의 LSUIElement가 처리)
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var store = AgentStore()
    private var iconUpdateTimer: Timer?
    private var hotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var cancellables = Set<AnyCancellable>()
    let updaterController: SPUStandardUpdaterController

    private static let showPopoverNotification = Notification.Name("com.sotthang.so-agentbar.showPopover")

    // 가능한 가장 이른 시점에 delegate 설정 — 새 인스턴스 런치 방지
    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 번들ID 기반으로 이미 실행 중인 인스턴스 감지 (파일 락보다 확실)
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let otherInstances = running.filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !otherInstances.isEmpty {
            // 기존 인스턴스에 팝오버 표시 요청 보내고 즉시 종료
            DistributedNotificationCenter.default().postNotificationName(
                Self.showPopoverNotification, object: nil
            )
            // terminate보다 빠르게 종료 — UI가 생성되기 전에 프로세스 제거
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 다른 인스턴스가 보낸 팝오버 표시 요청 수신
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showPopoverFromOtherInstance),
            name: Self.showPopoverNotification,
            object: nil
        )

        setupStatusItem()
        setupPopover()
        startIconUpdateTimer()
        setupHotkey()
        observePinState()
    }

    // 앱이 실행 중일 때 알림을 클릭하면 새 인스턴스 없이 이 메서드가 호출됨
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let path = userInfo["workingPath"] as? String
        let sourceStr = userInfo["source"] as? String

        Task { @MainActor in
            if let path, let sourceStr {
                let source: SessionSource = sourceStr == "xcode" ? .xcode : .cli
                self.store.openProject(path, source: source)
            } else {
                self.showPopover()
            }
        }
        completionHandler()
    }

    // 앱이 foreground일 때 알림 표시 허용
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func showPopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        if !popover.isShown {
            store.popoverOpenCount += 1
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.async {
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    @objc private func showPopoverFromOtherInstance() {
        showPopover()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateIcon()
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 500)
        popover.behavior = .transient
        popover.animates = true

        let contentView = AgentListView(store: store, updater: updaterController.updater)
        popover.contentViewController = NSHostingController(rootView: contentView)

        self.popover = popover
    }

    private var previousAgentCount = 0

    private func startIconUpdateTimer() {
        // agents 변경 감지 → 타이머 자동 관리
        store.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] agents in
                self?.updateIcon()
                self?.adjustTimerForActivity(hasWorking: agents.contains { $0.status == .working })
            }
            .store(in: &cancellables)
    }

    private func adjustTimerForActivity(hasWorking: Bool) {
        if hasWorking {
            // 활성 세션 있으면 1초 타이머 (경과 시간 표시용)
            guard iconUpdateTimer == nil else { return }
            iconUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateIcon() }
            }
        } else {
            // 활성 세션 없으면 타이머 해제 (agents 변경 시만 업데이트)
            iconUpdateTimer?.invalidate()
            iconUpdateTimer = nil
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        button.image = nil

        let agents = store.agents
        let activeCount = agents.filter { $0.status == .working }.count
        if agents.isEmpty {
            if let img = NSImage(named: "logo") {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = false
                button.image = img
                button.title = ""
            } else {
                button.title = "🤖"
            }
            button.toolTip = "so-agentbar — \(store.t("실행 중인 세션 없음", "No running sessions"))"
            return
        }

        switch store.menubarStyle {
        case .emoji:
            button.title = agents.prefix(4).map { store.displayEmoji(for: $0) }.joined()
        case .emojiCount:
            let emoji = agents.first.map { store.displayEmoji(for: $0) } ?? "🤖"
            button.title = "\(emoji) \(agents.count)"
        case .countOnly:
            button.title = "\(agents.count)"
        }

        button.toolTip = "so-agentbar — \(activeCount) \(store.t("개 에이전트 실행 중", "agents running"))"
    }

    @objc func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    // MARK: - 팝오버 고정 모드

    private func observePinState() {
        store.$isPinned
            .receive(on: RunLoop.main)
            .sink { [weak self] pinned in
                self?.popover?.behavior = pinned ? .applicationDefined : .transient
            }
            .store(in: &cancellables)
    }

    // MARK: - 글로벌 핫키 — Carbon API (접근성 권한 불필요)

    private func setupHotkey() {
        // Carbon 이벤트 핸들러 1회 설치
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { delegate.togglePopoverFromHotkey() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        // 초기 핫키 등록
        registerCurrentHotkey()

        // 설정 변경 감시 → 핫키 재등록
        store.$hotkeyKeyCode
            .combineLatest(store.$hotkeyModifiers, store.$hotkeyEnabled)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.unregisterHotkey()
                self?.registerCurrentHotkey()
            }
            .store(in: &cancellables)
    }

    private func registerCurrentHotkey() {
        guard store.hotkeyEnabled else { return }
        let hotkeyID = EventHotKeyID(signature: OSType(0x4142_4152), id: 1)
        RegisterEventHotKey(
            UInt32(store.hotkeyKeyCode),
            UInt32(store.hotkeyModifiers),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
    }

    private func unregisterHotkey() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
    }

    fileprivate func togglePopoverFromHotkey() {
        guard let popover = popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        iconUpdateTimer?.invalidate()
        unregisterHotkey()
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
    }
}
