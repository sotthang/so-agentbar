import SwiftUI
import AppKit
import Carbon
import Combine
import UserNotifications
import Sparkle

// [SPEC-003 R0.3] 이미지 출처 결정 결과. AppDelegate 밖 파일 최상위에 둔다
// (extension 안에 넣으면 AppDelegate.MenubarIconSource가 되어 테스트 가독성이 떨어짐 — arch §10-3.4).
enum MenubarIconSource: Equatable {
    case none
    case legacyLogo
    case animatedFrame
}

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
    // [SPEC-003 C4] 로고 바운스 애니메이션 컨트롤러. NSImage(named:"logo")를 1회만 취득하며
    // 공유 캐시 인스턴스를 변이시키지 않는다(R3.5) — makeLegacyLogoImage()와 같은 원칙.
    private lazy var animationController = MenubarAnimationController()
    // [SPEC-003 R9] 슬립/웨이크 옵저버 — applicationWillTerminate에서 해제한다(R9.4).
    private var workspaceObservers: [NSObjectProtocol] = []
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
        // 메뉴바 앱은 포커스가 없으므로 immediateFocus가 항상 false —
        // 항상 Sparkle 기본 모달을 표시해야 업데이트 알림이 사용자에게 전달됨
        return true
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
            installMainMenu()
            setupStatusItem()
            setupPopover()
            startIconUpdateTimer()
            setupHotkey()
            observePinState()
            observeSleepWake()
            presentAutomaticUpdatesPromptIfNeeded()
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
        // [SPEC-003 R2.10] 기본값 의존을 없애는 방어. 레거시 18x18 이미지는 콘텐츠 rect 안에
        // 들어가므로 .scaleNone에서도 육안 변화가 없다(AC41).
        button.imageScaling = .scaleNone

        // [SPEC-003 R7.9/R8.2] 타이머 tick마다 button.image만 교체한다. updateIcon() 전체를
        // 재실행하지 않는다(R7.12) — usage 조회/문자열 빌드까지 7fps로 돌면 안 된다.
        animationController.onFrame = { [weak self] image in
            self?.statusItem?.button?.image = image
        }

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

    /// [SPEC-003 R8.4] agents/style 변경 시 컨트롤러 갱신 공통 경로 — $agents/$menubarStyle
    /// sink에서 중복되던 `animationController.update(...)` 호출을 하나로 모은 것(동작 변경 없음).
    private func updateAnimationController(agents: [Agent], style: MenubarStyle) {
        animationController.update(
            style: style,
            runningCount: MenubarActivityIndicator.runningCount(in: agents),
            isSustaining: MenubarActivityIndicator.hasSustainingActivity(in: agents),
            now: Date()
        )
    }

    private func startIconUpdateTimer() {
        // agents 또는 menubarStyle 변경 감지 → 아이콘 업데이트
        // [SPEC-003 R8.4] ① controller.update(...) 가 먼저 — updateIcon()이 이번 tick의
        // 최신 currentImage를 읽어야 한다(§3-3 순서 계약). controller.update(...)는 onFrame을
        // 방출하지 않으므로, 순서가 뒤집히면 updateIcon()이 낡은 프레임을 대입한다.
        store.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] agents in
                guard let self else { return }
                self.updateAnimationController(agents: agents, style: self.store.menubarStyle)
                self.updateIcon()
                // ③ 1초 타이머 유지 조건 — 현행 그대로(최상위 한정, R1.2 회귀 금지)
                let needsTimer = agents.contains { $0.status == .working || $0.status == .waitingApproval }
                self.adjustTimerForActivity(hasWorking: needsTimer)
            }
            .store(in: &cancellables)

        store.$menubarStyle
            .receive(on: RunLoop.main)
            .sink { [weak self] style in
                guard let self else { return }
                self.updateAnimationController(agents: self.store.agents, style: style)
                self.updateIcon()
            }
            .store(in: &cancellables)

        store.usageCoordinator.$menubarUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        store.$sessionAlertThreshold
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

    // MARK: - 쿼터 suffix 빌더 (순수 함수 — 단위 테스트 가능)

    nonisolated static func buildQuotaSuffix(
        util: (session: Double, weekly: Double)?,
        mode: MenubarStyle
    ) -> String {
        guard let util else { return "" }
        let s = Int(util.session)
        let w = Int(util.weekly)
        switch mode {
        case .quotaSession:          return "S\(s)%"
        case .quotaSessionAndWeekly: return "S\(s)%/W\(w)%"
        default:                     return ""
        }
    }

    // MARK: - 메뉴바 attributed string 빌더 (순수 함수 — 단위 테스트 가능)

    nonisolated static func buildMenubarAttributedTitle(
        body: String,
        suffix: String,
        sessionUtil: Int?,
        weeklyUtil: Int?,
        threshold: Double
    ) -> NSAttributedString {
        let full = body + suffix
        let mutable = NSMutableAttributedString(string: full)
        let fullRange = NSRange(full.startIndex..., in: full)

        mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        guard !suffix.isEmpty else { return mutable }

        let bodyLen = (body as NSString).length
        let suffixNS = suffix as NSString
        let thresholdInt = Int(threshold)

        // suffix 내에서 "X{n}%" 형태의 토큰을 찾아 NSRange(전체 문자열 기준)로 반환
        func tokenRange(prefix: String, searchFrom: Int) -> (range: NSRange, nextSearchFrom: Int)? {
            let prefixRange = suffixNS.range(of: prefix, range: NSRange(location: searchFrom, length: suffixNS.length - searchFrom))
            guard prefixRange.location != NSNotFound else { return nil }
            let afterPrefix = prefixRange.location + prefixRange.length
            let percentRange = suffixNS.range(of: "%", range: NSRange(location: afterPrefix, length: suffixNS.length - afterPrefix))
            guard percentRange.location != NSNotFound else { return nil }
            let range = NSRange(location: bodyLen + prefixRange.location, length: percentRange.location + 1 - prefixRange.location)
            return (range, percentRange.location + 1)
        }

        var searchFrom = 0

        if let (range, next) = tokenRange(prefix: "S", searchFrom: searchFrom) {
            if let sUtil = sessionUtil, sUtil >= thresholdInt {
                mutable.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range)
            }
            searchFrom = next
        }

        if let wUtil = weeklyUtil, let (range, _) = tokenRange(prefix: "W", searchFrom: searchFrom) {
            if wUtil >= thresholdInt {
                mutable.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range)
            }
        }

        return mutable
    }

    // MARK: - 멀티 프로바이더 메뉴바 suffix 빌더 (순수 함수 — AC-X.5, TDD 대상)

    /// 선택 프로바이더의 ProviderUsage → 메뉴바 suffix 문자열.
    /// - mode가 쿼터 모드 아니거나 usage==nil/state!=.data → ""
    /// - usage.id==.claude → buildQuotaSuffix(util: (session,weekly), mode:)  [기존 경로]
    /// - isEstimate: costDollars 있으면 "~$X.X", 없고 토큰>0이면 "~{N}k", 둘 다 없으면 ""
    nonisolated static func buildUsageSuffix(
        usage: ProviderUsage?,
        mode: MenubarStyle
    ) -> String {
        // 쿼터 모드 아니면 항상 빈 문자열
        guard mode == .quotaSession || mode == .quotaSessionAndWeekly else { return "" }
        // usage nil → 빈 문자열
        guard let usage else { return "" }
        // state가 .data 아니면 빈 문자열
        guard case .data = usage.state else { return "" }

        switch usage.id {
        case .claude:
            // 기존 buildQuotaSuffix 경로 (회귀 없음)
            guard let quota = usage.quota else { return "" }
            let util = (session: quota.sessionUtilization, weekly: quota.weeklyUtilization)
            return buildQuotaSuffix(util: util, mode: mode)

        case .codex, .gemini:
            // 추정 suffix
            guard let estimate = usage.estimate else { return "" }
            if let cost = estimate.costDollars, cost > 0 {
                // 비용 있음 → "~$X.X" (소수점 1자리)
                return String(format: "~$%.1f", cost)
            } else if estimate.totalTokens > 0 {
                // 비용 추정 불가, 토큰만 → "~{N}k"
                let kTokens = estimate.totalTokens / 1000
                return "~\(kTokens)k"
            } else {
                return ""
            }

        case .cursor:
            // [SPEC-002 재설계] usage-summary 기반 퍼센트 suffix
            // 0%도 데이터가 있으면 표시하지 않음 (의미 없으므로 > 0 조건)
            guard let p = usage.cursorPercent, p.totalPercentUsed > 0 else { return "" }
            return "\(Int(p.totalPercentUsed))%"  // 예: "6%"
        }
    }

    // MARK: - [SPEC-003 R0] iconSource / buildMenubarBody — 아이콘/본문 결정 순수 함수

    /// R0.3 — 이미지 출처 결정. R1.4의 3줄 규칙을 이 함수 하나로 통일한다.
    /// C4부터 `resolveImage(for:)`가 `.animatedFrame`을 `animationController.currentImage`로
    /// 분기시킨다(R1.4) — `.legacyLogo`와 더 이상 동일하지 않다.
    nonisolated static func iconSource(agentsIsEmpty: Bool, isQuotaMode: Bool) -> MenubarIconSource {
        switch (agentsIsEmpty, isQuotaMode) {
        case (true, false):  return .legacyLogo
        case (true, true):   return .animatedFrame
        case (false, true):  return .animatedFrame
        case (false, false): return .none
        }
    }

    /// R0.1 — 메뉴바 본문 문자열 결정. R0.2 표 10행을 그대로 옮긴 것.
    /// - didSetIconImage: "이번 updateIcon() 호출에서 button.image에 non-nil을 세팅했는가"이지
    ///   "로고를 로드했는가"가 아니다 (R0.1 주의).
    /// - emoji: store.menuBarEmoji(for:)가 인스턴스 메서드이므로 클로저로 주입한다.
    nonisolated static func buildMenubarBody(
        agents: [Agent],
        style: MenubarStyle,
        approvalCount: Int,
        didSetIconImage: Bool,
        emoji: (Agent) -> String
    ) -> String {
        if agents.isEmpty { return didSetIconImage ? "" : "🤖" }
        switch style {
        case .emoji:
            return agents.prefix(4).map(emoji).joined()
        case .emojiCount:
            let e = agents.first.map(emoji) ?? "🤖"
            let firstIsWaiting = agents.first?.status == .waitingApproval
            let needsBadge = approvalCount > 0 && !firstIsWaiting
            return "\(e) \(agents.count)" + (needsBadge ? "❗" : "")
        case .countOnly:
            return "\(agents.count)" + (approvalCount > 0 ? "❗" : "")
        case .quotaSession, .quotaSessionAndWeekly:
            return didSetIconImage ? "" : "🤖"
        }
    }

    // MARK: - 첫 실행 자동 업데이트 프롬프트

    /// 첫 실행 시 자동 업데이트 프롬프트 표시 여부를 기록하는 UserDefaults 키
    static let didAskAutomaticUpdatesKey = "didAskAutomaticUpdatesPermission"

    /// 아직 한 번도 물어본 적 없으면 true. 한 번 물어보면 다시 묻지 않는다.
    static func shouldAskAutomaticUpdatesPermission(defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: didAskAutomaticUpdatesKey)
    }

    /// 첫 실행 시 자동 업데이트 여부를 체크박스 창으로 물어보고, 선택을
    /// Sparkle updater에 적용한 뒤 "물어봤음"을 기록한다.
    /// 이미 물어봤으면 아무것도 하지 않는다.
    private func presentAutomaticUpdatesPromptIfNeeded() {
        let defaults = UserDefaults.standard
        guard Self.shouldAskAutomaticUpdatesPermission(defaults: defaults) else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = store.t("so-agentbar에 오신 것을 환영합니다", "Welcome to so-agentbar")
        alert.informativeText = store.t(
            "새 버전이 나오면 자동으로 확인할까요? 이 설정은 나중에 설정 화면에서 변경할 수 있습니다.",
            "Automatically check for new versions when they're released? You can change this later in Settings.")

        let checkbox = NSButton(
            checkboxWithTitle: store.t("새 버전을 자동으로 확인", "Automatically check for new versions"),
            target: nil,
            action: nil)
        checkbox.state = .on
        alert.accessoryView = checkbox
        alert.addButton(withTitle: store.t("시작", "Continue"))

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()

        updaterController.updater.automaticallyChecksForUpdates = (checkbox.state == .on)
        defaults.set(true, forKey: Self.didAskAutomaticUpdatesKey)
    }

    // MARK: - Edit 메뉴 (LSUIElement 앱의 Cmd+C/V/X/A 라우팅 복원)

    /// 표준 편집 항목을 담은 Edit 메뉴를 구성한다.
    /// LSUIElement(.accessory) 앱은 기본 메인 메뉴가 없어 표준 편집
    /// 단축키가 first responder로 전달되지 않는다. 이 메뉴를 메인 메뉴에
    /// 설치하면 팝오버 내 TextEditor에서 복사/붙여넣기가 동작한다.
    static func buildEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")

        let undo = menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        undo.keyEquivalentModifierMask = [.command]
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())

        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        return menu
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        editItem.submenu = Self.buildEditMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    /// [SPEC-003 R1.4/R8.2] 이미지 출처 → 실제 NSImage. quota 모드(`.animatedFrame`)는
    /// 애니메이션 컨트롤러의 현재 tick 프레임을 쓴다 — 프레임 0으로 되돌리거나 tick을
    /// 리셋하지 않는다(R8.2). 없으면(로고 로드 실패 등) nil → didSetIconImage == false로
    /// 이어져 기존 폴백("🤖")으로 되돌아간다(R3.6).
    private func resolveImage(for source: MenubarIconSource) -> NSImage? {
        switch source {
        case .none:          return nil
        case .legacyLogo:    return makeLegacyLogoImage()
        case .animatedFrame: return animationController.currentImage
        }
    }

    /// [SPEC-003 R0.6] 공유 캐시 인스턴스(`NSImage(named:)`)를 변이시키지 않는다.
    /// `AgentListView.swift:73`이 같은 공유 인스턴스를 쓰므로, 복제 후 리사이즈한다.
    private func makeLegacyLogoImage() -> NSImage? {
        guard let img = NSImage(named: "logo")?.copy() as? NSImage else { return nil }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = false
        return img
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        let agents = store.agents
        let style = store.menubarStyle
        let isQuotaMode = (style == .quotaSession || style == .quotaSessionAndWeekly)
        // [SPEC-003 R1.2 예외/AC37] 최상위만 세던 것을 트리 전체(서브에이전트 포함) 집계로 정정.
        // 아이콘 티어(controller)와 툴팁 숫자가 동일한 runningCount(in:)에서 나오도록 통일한다(NFR6).
        let activeCount = MenubarActivityIndicator.runningCount(in: agents)
        let approvalCount = agents.filter { $0.status == .waitingApproval }.count

        // 1) 이미지 결정 — 호출당 정확히 1회 대입 (R0.5 / R8.3)
        let source = Self.iconSource(agentsIsEmpty: agents.isEmpty, isQuotaMode: isQuotaMode)
        let image = resolveImage(for: source)
        button.image = image
        let didSetIconImage = (image != nil)

        // 2) 본문 빌드 (R0.1)
        let body = Self.buildMenubarBody(
            agents: agents,
            style: style,
            approvalCount: approvalCount,
            didSetIconImage: didSetIconImage,
            emoji: { self.store.menuBarEmoji(for: $0) }
        )

        // 3) 툴팁 — 현행 3분기 구조·문구 그대로 보존
        if agents.isEmpty {
            button.toolTip = "so-agentbar — \(store.t("실행 중인 세션 없음", "No running sessions"))"
        } else if approvalCount > 0 {
            button.toolTip = "so-agentbar — \(approvalCount) \(store.t("개 승인 대기", "awaiting approval"))"
        } else {
            button.toolTip = "so-agentbar — \(activeCount) \(store.t("개 에이전트 실행 중", "agents running"))"
        }

        // 4) suffix 결정 — menubarUsage 기반 (선택 프로바이더, RX.4)
        // buildUsageSuffix: 쿼터 모드 아니거나 usage nil/에러 → ""
        let menubarUsage = store.usageCoordinator.menubarUsage
        let suffix = Self.buildUsageSuffix(usage: menubarUsage, mode: style)

        // 5) attributedTitle 일원화
        // Claude 선택 시: quota.sessionUtilization/weeklyUtilization → 임계 빨강 적용
        // Codex/Gemini 선택 시: sessionUtil/weeklyUtil=nil → 빨강 분기 타지 않음
        let sessionUtil: Int?
        let weeklyUtil: Int?
        if isQuotaMode, let mu = menubarUsage, case .data = mu.state, mu.id == .claude,
           let quota = mu.quota {
            sessionUtil = Int(quota.sessionUtilization)
            weeklyUtil = (style == .quotaSessionAndWeekly) ? Int(quota.weeklyUtilization) : nil
        } else {
            sessionUtil = nil
            weeklyUtil = nil
        }
        button.attributedTitle = Self.buildMenubarAttributedTitle(
            body: body,
            suffix: suffix,
            sessionUtil: sessionUtil,
            weeklyUtil: weeklyUtil,
            threshold: store.sessionAlertThreshold
        )
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

    // MARK: - 슬립/웨이크 (SPEC-003 R9)

    /// R9.1 — `NSWorkspace.shared.notificationCenter`의 공개 알림 4개만 등록한다.
    /// `com.apple.screenIsLocked` 등 비공개 알림은 쓰지 않는다(R9.2).
    private func observeSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter
        let sleepNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification
        ]
        let wakeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification
        ]
        for name in sleepNames {
            let observer = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.animationController.suspend() }
            }
            workspaceObservers.append(observer)
        }
        for name in wakeNames {
            let observer = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.animationController.resume(now: Date()) }
            }
            workspaceObservers.append(observer)
        }
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
        // [SPEC-003 R9.4] 옵저버 해제는 deinit이 아니라 여기서 한다 — AppDelegate는 앱 수명
        // 동안 살아있어 deinit이 사실상 호출되지 않는다.
        animationController.suspend()
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { nc.removeObserver($0) }
        workspaceObservers.removeAll()

        iconUpdateTimer?.invalidate()
        unregisterHotkey()
        unregisterPixelHotkey()
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }

        // Utility cleanup
        store.keepAwakeManager.releaseAll()
        store.clipboardMonitor.stop()
        store.quickNoteStore.flush()
    }
}
