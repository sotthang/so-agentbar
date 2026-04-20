import SwiftUI
import AppKit
import Carbon
import Combine
import UserNotifications
import Sparkle

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, SPUStandardUserDriverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var store = AgentStore()
    private var iconUpdateTimer: Timer?
    private var hotkeyRef: EventHotKeyRef?
    private var pixelHotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var cancellables = Set<AnyCancellable>()
    private(set) var updaterController: SPUStandardUpdaterController!
    private var pixelWindowController: PixelAgentsWindowController?

    private static let showPopoverNotification = Notification.Name("com.sotthang.so-agentbar.showPopover")
    nonisolated static let updateNotificationIdentifier = "SparkleUpdateAvailable"

    // 가능한 가장 이른 시점에 delegate 설정 — 새 인스턴스 런치 방지
    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - SPUStandardUserDriverDelegate (Gentle Reminders)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // 즉시 포커스일 때만 Sparkle 기본 모달 표시, 아니면 gentle reminder로 처리
        return immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // Sparkle이 직접 처리하는 경우 (즉시 포커스) → 추가 알림 불필요
        guard !handleShowingUpdate else { return }

        // 백그라운드 업데이트 감지 → macOS 알림센터로 알림
        let content = UNMutableNotificationContent()
        content.title = "so-agentbar Update Available"
        content.body = "Version \(update.displayVersionString) is now available"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: Self.updateNotificationIdentifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        // 사용자가 업데이트에 주목 → 알림 제거
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [Self.updateNotificationIdentifier]
        )
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [Self.updateNotificationIdentifier]
        )
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

        // 런루프가 완전히 준비된 후 상태바 아이템 생성 — 첫 실행 시 메뉴바 미표시 방지
        DispatchQueue.main.async { [self] in
            pixelWindowController = PixelAgentsWindowController(store: store)
            setupStatusItem()
            setupPopover()
            startIconUpdateTimer()
            setupHotkey()
            observePinState()
        }
    }

    // 앱이 실행 중일 때 알림을 클릭하면 새 인스턴스 없이 이 메서드가 호출됨
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let userInfo = response.notification.request.content.userInfo

        // Sparkle 업데이트 알림 클릭 → 업데이트 확인 창 열기
        if identifier == Self.updateNotificationIdentifier,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                self.updaterController.checkForUpdates(nil)
            }
            completionHandler()
            return
        }

        let path = userInfo["workingPath"] as? String
        let sourceStr = userInfo["source"] as? String

        Task { @MainActor in
            if let path, let sourceStr {
                let source: SessionSource
                switch sourceStr {
                case "xcode":         source = .xcode
                case "desktopCode":   source = .desktopCode
                case "desktopCowork": source = .desktopCowork
                default:              source = .cli
                }
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
        // agents 또는 menubarStyle 변경 감지 → 아이콘 업데이트
        store.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] agents in
                self?.updateIcon()
                let needsTimer = agents.contains { $0.status == .working || $0.status == .waitingApproval }
                self?.adjustTimerForActivity(hasWorking: needsTimer)
            }
            .store(in: &cancellables)

        store.$menubarStyle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
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
        let approvalCount = agents.filter { $0.status == .waitingApproval }.count
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

        // 승인 대기 중인 세션이 있으면 느낌표 뱃지 추가
        // .emoji 모드: 각 에이전트 이모지에 이미 상태가 표현됨(⏳ 또는 커스텀+❗) → 글로벌 뱃지 불필요
        // .emojiCount: 첫 에이전트만 보여지므로, 그 외 승인 대기가 있으면 글로벌 뱃지 필요
        // .countOnly: 이모지 없음 → 항상 글로벌 뱃지 필요
        switch store.menubarStyle {
        case .emoji:
            button.title = agents.prefix(4).map { store.menuBarEmoji(for: $0) }.joined()
        case .emojiCount:
            let emoji = agents.first.map { store.menuBarEmoji(for: $0) } ?? "🤖"
            let firstIsWaiting = agents.first?.status == .waitingApproval
            // 첫 에이전트에 이미 대기 표시가 있으면 중복 방지
            let needsBadge = approvalCount > 0 && !firstIsWaiting
            button.title = "\(emoji) \(agents.count)" + (needsBadge ? "❗" : "")
        case .countOnly:
            button.title = "\(agents.count)" + (approvalCount > 0 ? "❗" : "")
        }

        if approvalCount > 0 {
            button.toolTip = "so-agentbar — \(approvalCount) \(store.t("개 승인 대기", "awaiting approval"))"
        } else {
            button.toolTip = "so-agentbar — \(activeCount) \(store.t("개 에이전트 실행 중", "agents running"))"
        }
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
        // Carbon 이벤트 핸들러 1회 설치 — 핫키 ID로 동작 분기
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let paramStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard paramStatus == noErr else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    switch hotKeyID.id {
                    case 1: delegate.togglePopoverFromHotkey()
                    case 2: delegate.togglePixelWindowFromHotkey()
                    default: break
                    }
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        // 초기 핫키 등록
        registerCurrentHotkey()
        registerCurrentPixelHotkey()

        // 팝오버 핫키 설정 변경 감시
        store.$hotkeyKeyCode
            .combineLatest(store.$hotkeyModifiers, store.$hotkeyEnabled)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.unregisterHotkey()
                self?.registerCurrentHotkey()
            }
            .store(in: &cancellables)

        // 픽셀 핫키 설정 변경 감시
        store.$pixelHotkeyKeyCode
            .combineLatest(store.$pixelHotkeyModifiers, store.$pixelHotkeyEnabled)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.unregisterPixelHotkey()
                self?.registerCurrentPixelHotkey()
            }
            .store(in: &cancellables)
    }

    private func registerCurrentHotkey() {
        guard store.hotkeyEnabled else { return }
        let hotkeyID = EventHotKeyID(signature: OSType(0x4142_4152), id: 1)
        let status = RegisterEventHotKey(
            UInt32(store.hotkeyKeyCode),
            UInt32(store.hotkeyModifiers),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        if status != noErr {
            NSLog("[SoAgentBar] 팝오버 핫키 등록 실패 (OSStatus: %d) — 다른 앱과 충돌할 수 있습니다", status)
        }
    }

    private func unregisterHotkey() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
    }

    private func registerCurrentPixelHotkey() {
        guard store.pixelHotkeyEnabled else { return }
        let hotkeyID = EventHotKeyID(signature: OSType(0x4142_4152), id: 2)
        let status = RegisterEventHotKey(
            UInt32(store.pixelHotkeyKeyCode),
            UInt32(store.pixelHotkeyModifiers),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &pixelHotkeyRef
        )
        if status != noErr {
            NSLog("[SoAgentBar] 픽셀 핫키 등록 실패 (OSStatus: %d) — 다른 앱과 충돌할 수 있습니다", status)
        }
    }

    private func unregisterPixelHotkey() {
        if let ref = pixelHotkeyRef {
            UnregisterEventHotKey(ref)
            pixelHotkeyRef = nil
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

    fileprivate func togglePixelWindowFromHotkey() {
        store.isPixelWindowVisible.toggle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        iconUpdateTimer?.invalidate()
        unregisterHotkey()
        unregisterPixelHotkey()
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
    }
}
