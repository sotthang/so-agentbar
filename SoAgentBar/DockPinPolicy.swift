import CoreGraphics
import Foundation

// SPEC-004 Dock Pin — 정책 순수 함수 (arch §2.5, 커밋 4)
// activation(R4.1), requiredTimers(R4.4), isDisplayConfigChange(R4.8), isUserOverride(R7.4),
// relocationDecision(R8.2), 재시도 일정(R5.9, R8.7), status(R11.7), presentation(R11.1–11.2, S5),
// 문구 카탈로그(R11.2–11.3, R11.6, S2, S6), 잠금 판정(R10.3), 테스트 호스트 판정(R12.3)
// 이 파일은 CoreGraphics / Foundation 만 import 한다 (AC13.1). AppLanguage는 같은 모듈의 값 타입이다.

/// R8.2 — 되돌리기 시작 판정 입력
struct DockPinRelocationInputs: Equatable, Sendable {
    var activation: DockPinActivation
    /// nil = 조회 전 → .skip(.dockNotFound)
    var placement: DockPinPlacement?
    var anchorID: CGDirectDisplayID?
    var phase: DockPinRelocationPhase
    var retryScheduled: Bool
    var trigger: DockPinTrigger
    var isUserOverride: Bool
    var hasRelocationTarget: Bool
    var session: DockPinSessionState
    var anyButtonDown: Bool
    var secondsSinceInput: TimeInterval
}

/// R11.7 — 상태 판정 입력
struct DockPinStatusInputs: Equatable, Sendable {
    var activation: DockPinActivation
    var tapState: DockPinTapState
    var phase: DockPinRelocationPhase
    /// nil = 조회 전 → .checking
    var placement: DockPinPlacement?
    var anchorID: CGDirectDisplayID?
    var anchorName: String
    /// nil = 오버라이드 아님
    var overrideDisplayName: String?
    var hasRelocationTarget: Bool
}

/// R4.8 (C8) — 비교 대상. baseLayout은 오버라이드 없이(overrideDisplayID: nil) 계산한 것(arch §12 I3).
struct DockPinConfigFingerprint: Equatable, Sendable {
    let baseLayout: DockPinLayout?
    let inputs: DockPinActivationInputs
}

enum DockPinTone: Equatable, Sendable { case gray, orange, red, green, blue }

/// R11.1, 디자인 [C]
struct DockPinPresentation: Equatable, Sendable {
    let text: String
    /// S5: .off/.needsPermission/.inactive(*)에서는 항상 nil
    let fallbackNote: String?
    let tone: DockPinTone
    /// AC11.3: .needsPermission에서만
    let showsOpenPermissionSettings: Bool
    /// AC11.2
    let moveBackEnabled: Bool
    /// "Dock 고정 상태: {text}. {note}" / "Dock Pin status: {text}. {note}"
    let accessibilityLabel: String
}

/// 사용자 문구 카탈로그. 모든 문구를 (ko, en) 쌍으로 둔다(= store.t와 같은 의미).
/// AC11.5 테스트가 전체를 열거할 수 있게 하려고 뷰가 아닌 순수 파일에 둔다(arch §12 I8).
enum DockPinText {
    static func t(_ ko: String, _ en: String, _ language: AppLanguage) -> String {
        language == .korean ? ko : en
    }

    /// "Dock 고정" / "Dock Pin"
    static func sectionTitle(_ l: AppLanguage) -> String { t("Dock 고정", "Dock Pin", l) }
    static func toggleTitle(_ l: AppLanguage) -> String {
        t("Dock을 한 모니터에 고정", "Keep the Dock on one display", l)
    }
    static func toggleDescription(_ l: AppLanguage) -> String {
        t("보조 모니터 아래쪽에 마우스를 대도 Dock이 넘어가지 않아요. 손쉬운 사용 권한이 필요해요.",
          "The Dock won't jump to other displays when you touch their bottom edge. Requires Accessibility permission.", l)
    }
    /// 접근성 레이블로도 쓴다
    static func pickerTitle(_ l: AppLanguage) -> String { t("Dock을 둘 모니터", "Keep the Dock on", l) }
    /// S6 "Open Permission Settings"
    static func openPermissionSettings(_ l: AppLanguage) -> String {
        t("권한 설정 열기", "Open Permission Settings", l)
    }
    static func moveBackNow(_ l: AppLanguage) -> String { t("지금 되돌리기", "Move Dock back now", l) }
    static func helpOption(_ l: AppLanguage) -> String {
        t("Option 키를 누른 채로 대면 Dock을 옮길 수 있어요", "Hold Option to let the Dock move", l)
    }
    /// S6 영어 확정
    static func helpPermissionCaution(_ l: AppLanguage) -> String {
        t("손쉬운 사용 권한을 끄기 전에 Dock 고정을 끄거나 앱을 종료하세요",
          "Turn off Dock Pin or quit the app before turning off Accessibility permission", l)
    }
    static func fallbackNote(_ l: AppLanguage) -> String {
        t("선택한 모니터가 연결돼 있지 않아 주 모니터를 쓰는 중",
          "Selected display isn't connected — using the main display", l)
    }

    /// AC11.5 — 위 정적 문구 + 모든 상태 문구(샘플 이름) + 모든 선택지 제목(S2 포함) + 접근성 레이블
    static func allUserFacingStrings(_ l: AppLanguage) -> [String] {
        let name = "Color LCD"
        let statics = [sectionTitle(l), toggleTitle(l), toggleDescription(l), pickerTitle(l),
                       openPermissionSettings(l), moveBackNow(l), helpOption(l), helpPermissionCaution(l),
                       fallbackNote(l)]
        let statuses: [DockPinStatus] = [
            .off, .needsPermission, .inactive(.singleDisplay), .inactive(.spacesOff),
            .inactive(.dockNotBottom(.left)), .inactive(.dockNotBottom(.right)), .tapFailed(attempt: 1),
            .checking, .dockNotFound, .noFreeEdge(displayName: name), .pinned(displayName: name),
            .waiting(.userActive, displayName: name), .relocating(displayName: name),
            .movedByUser(displayName: name), .failed(attempts: DockPinTuning.maxAttempts),
        ]
        let presentations = statuses.flatMap { status in
            [false, true].map { DockPinPolicy.presentation(for: status, usingFallbackAnchor: $0, language: l) }
        }
        let choices: [DockPinTargetChoice.Kind] = [.main, .connected(name: name),
                                                   .disconnected(lastName: name), .disconnected(lastName: nil)]
        let choiceTitles = choices.map {
            DockPinPolicy.choiceTitle(DockPinTargetChoice(id: "sample", target: .main, kind: $0), language: l)
        }
        return statics + presentations.map(\.text) + choiceTitles + presentations.map(\.accessibilityLabel)
    }
}

enum DockPinPolicy {
    /// R4.1
    static func activation(_ inputs: DockPinActivationInputs) -> DockPinActivation {
        if !inputs.enabled { return .inactive(.off) }
        if !inputs.hasPermission { return .inactive(.needsPermission) }
        if inputs.activeDisplayCount < 2 { return .inactive(.singleDisplay) }
        if !inputs.separateSpaces { return .inactive(.spacesOff) }
        switch inputs.orientation {
        case .bottom: return .active
        case .left: return .inactive(.dockNotBottom(.left))
        case .right: return .inactive(.dockNotBottom(.right))
        }
    }

    /// R4.4
    static func requiredTimers(activation: DockPinActivation,
                               tapState: DockPinTapState) -> Set<DockPinRepeatingTimer> {
        switch activation {
        case .inactive(.off), .inactive(.singleDisplay):
            return []
        case .inactive(.needsPermission):
            return [.permissionPoll]
        case .inactive(.spacesOff), .inactive(.dockNotBottom):
            return [.prefsPoll]
        case .active:
            switch tapState {
            case .running: return [.permissionPoll, .dockPoll, .tapWatchdog]
            case .retrying: return [.permissionPoll, .tapRetry]
            case .none: return [.permissionPoll]
            }
        }
    }

    /// R4.8
    static func isDisplayConfigChange(previous: DockPinConfigFingerprint?,
                                      current: DockPinConfigFingerprint) -> Bool {
        previous != current
    }

    /// R7.4
    static func isUserOverride(dockDisplay: CGDirectDisplayID, anchor: CGDirectDisplayID,
                               optionPasses: [CGDirectDisplayID: TimeInterval],
                               lastConfirmedOnAnchorAt: TimeInterval?, now: TimeInterval,
                               window: TimeInterval = DockPinTuning.optionOverrideWindow) -> Bool {
        guard dockDisplay != anchor, let passedAt = optionPasses[dockDisplay] else { return false }
        return passedAt > (lastConfirmedOnAnchorAt ?? -.infinity) && now - passedAt <= window
    }

    /// R8.2 — 위에서 처음 걸리는 행
    static func relocationDecision(_ inputs: DockPinRelocationInputs) -> DockPinRelocationDecision {
        guard inputs.activation == .active else { return .skip(.inactive) }
        guard case .display(let dockID)? = inputs.placement else { return .skip(.dockNotFound) }
        if dockID == inputs.anchorID { return .skip(.alreadyPinned) }
        if case .failed = inputs.phase, inputs.trigger != .event { return .skip(.failedUntilEvent) }
        if inputs.retryScheduled, inputs.trigger != .retryTimer { return .skip(.retryScheduled) }
        if inputs.isUserOverride { return .skip(.userOverride) }
        if !inputs.hasRelocationTarget { return .skip(.noFreeEdge) }
        if inputs.session.asleep { return .wait(.asleep) }
        if inputs.session.locked { return .wait(.locked) }
        if !inputs.session.onConsole { return .wait(.notOnConsole) }
        if inputs.anyButtonDown { return .wait(.buttonDown) }
        if inputs.secondsSinceInput < DockPinTuning.idleBeforeRelocation { return .wait(.userActive) }
        return .go
    }

    /// 1→1, 2→3, 3→10, ≥4→nil
    static func relocationRetryDelay(afterFailures n: Int) -> TimeInterval? {
        let delays = DockPinTuning.retryDelays
        guard n >= 1, n <= delays.count else { return nil }
        return delays[n - 1]
    }

    /// 1→1, 2→2, 3→5, 4→10, ≥5→30
    static func tapRetryDelay(attempt: Int) -> TimeInterval {
        let delays = DockPinTuning.tapRetryDelays
        guard attempt >= 1, attempt <= delays.count else { return DockPinTuning.tapRetryTail }
        return delays[attempt - 1]
    }

    /// R11.7 — 위에서 처음 걸리는 것
    static func status(_ inputs: DockPinStatusInputs) -> DockPinStatus {
        let name = inputs.anchorName
        switch inputs.activation {
        case .inactive(.off): return .off
        case .inactive(.needsPermission): return .needsPermission
        case .inactive(let reason): return .inactive(reason)
        case .active: break
        }
        if case .retrying(let attempt) = inputs.tapState { return .tapFailed(attempt: attempt) }
        switch inputs.phase {
        case .driving, .verifying: return .relocating(displayName: name)
        case .waiting(let reason): return .waiting(reason, displayName: name)
        case .failed(let attempts): return .failed(attempts: attempts)
        case .idle: break
        }
        if let overrideName = inputs.overrideDisplayName { return .movedByUser(displayName: overrideName) }
        if !inputs.hasRelocationTarget { return .noFreeEdge(displayName: name) }
        switch inputs.placement {
        case nil: return .checking
        case .unknown?: return .dockNotFound
        case .display(let id)? where id == inputs.anchorID: return .pinned(displayName: name)
        case .display?: return .waiting(.userActive, displayName: name)
        }
    }

    /// R11.1
    static func presentation(for status: DockPinStatus, usingFallbackAnchor: Bool,
                             language: AppLanguage) -> DockPinPresentation {
        let text = statusText(status, language)
        let note = usingFallbackAnchor && allowsFallbackNote(status) ? DockPinText.fallbackNote(language) : nil
        var label = DockPinText.t("Dock 고정 상태: ", "Dock Pin status: ", language) + text
        if let note { label += ". " + note }
        return DockPinPresentation(text: text, fallbackNote: note, tone: tone(status),
                                   showsOpenPermissionSettings: status == .needsPermission,
                                   moveBackEnabled: moveBackEnabled(status),
                                   accessibilityLabel: label)
    }

    /// R2.5, S2
    static func choiceTitle(_ choice: DockPinTargetChoice, language: AppLanguage) -> String {
        switch choice.kind {
        case .main:
            return DockPinText.t("주 모니터 (기본)", "Main display (default)", language)
        case .connected(let name):
            return name
        case .disconnected(let lastName):
            let name = lastName ?? DockPinText.t("알 수 없는 모니터", "Unknown display", language)
            return name + DockPinText.t(" (연결 안 됨)", " (not connected)", language)
        }
    }

    /// R10.3 / AC10.4: 키 없음 → false
    static func isScreenLocked(sessionInfo: [String: Any]?) -> Bool {
        (sessionInfo?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// R12.3 — 세 환경 키 중 하나 또는 xcTestClassLoaded. 함수 안에서 NSClassFromString을 부르지 않는다(N13)
    static func isTestHost(environment: [String: String], xcTestClassLoaded: Bool) -> Bool {
        let keys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
        return xcTestClassLoaded || keys.contains { environment[$0] != nil }
    }

    // MARK: - R11.2 표

    private static func statusText(_ status: DockPinStatus, _ l: AppLanguage) -> String {
        switch status {
        case .off:
            return DockPinText.t("꺼짐", "Off", l)
        case .needsPermission:
            return DockPinText.t("손쉬운 사용 권한이 필요해요", "Accessibility permission required", l)
        case .inactive(.singleDisplay):
            return DockPinText.t("대기 중 — 모니터가 하나뿐이에요. 연결하면 자동으로 켜져요",
                                 "Waiting — only one display. Turns on automatically when you connect another", l)
        case .inactive(.spacesOff):
            return DockPinText.t("대기 중 — '디스플레이마다 별도의 Spaces'가 꺼져 있어요",
                                 "Waiting — \"Displays have separate Spaces\" is off", l)
        case .inactive(.dockNotBottom(.left)):
            return DockPinText.t("대기 중 — Dock이 왼쪽에 있어요(아래쪽일 때만 동작)",
                                 "Waiting — Dock is on the left (works only when it's at the bottom)", l)
        case .inactive(.dockNotBottom(.right)):
            return DockPinText.t("대기 중 — Dock이 오른쪽에 있어요(아래쪽일 때만 동작)",
                                 "Waiting — Dock is on the right (works only when it's at the bottom)", l)
        case .inactive(.off):
            return statusText(.off, l)
        case .inactive(.needsPermission):
            return statusText(.needsPermission, l)
        case .tapFailed:
            return DockPinText.t("오류 — 마우스 이벤트 감시를 시작하지 못했어요. 다시 시도 중… 계속되면 앱을 다시 시작해 보세요",
                                 "Error — couldn't start watching pointer events. Retrying… Restart the app if this persists", l)
        case .checking:
            return DockPinText.t("Dock 위치 확인 중…", "Checking where the Dock is…", l)
        case .dockNotFound:
            return DockPinText.t("Dock 위치를 확인할 수 없어요", "Can't find where the Dock is", l)
        case .noFreeEdge(let name):
            return DockPinText.t("\(name) 아래쪽이 다른 모니터에 맞닿아 있어 Dock을 둘 수 없어요",
                                 "The bottom of \(name) touches another display, so the Dock can't be placed there", l)
        case .pinned(let name):
            return DockPinText.t("Dock이 \(name)에 고정됨", "Dock pinned to \(name)", l)
        case .waiting(_, let name):
            return DockPinText.t("Dock을 \(name)(으)로 되돌릴 준비 중…", "Waiting to move the Dock back to \(name)…", l)
        case .relocating(let name):
            return DockPinText.t("Dock을 \(name)(으)로 되돌리는 중…", "Moving the Dock back to \(name)…", l)
        case .movedByUser(let name):
            return DockPinText.t("Option으로 \(name)에 옮겼어요 — '지금 되돌리기'로 돌아갈 수 있어요",
                                 "Moved to \(name) with Option — use \"Move Dock back now\" to return", l)
        case .failed(let attempts):
            return DockPinText.t("Dock을 되돌리지 못했어요(\(attempts)회 시도)",
                                 "Couldn't move the Dock back (\(attempts) tries)", l)
        }
    }

    private static func tone(_ status: DockPinStatus) -> DockPinTone {
        switch status {
        case .off, .inactive, .checking: return .gray
        case .needsPermission, .dockNotFound, .noFreeEdge: return .orange
        case .tapFailed, .failed: return .red
        case .pinned: return .green
        case .waiting, .relocating, .movedByUser: return .blue
        }
    }

    private static func moveBackEnabled(_ status: DockPinStatus) -> Bool {
        switch status {
        case .dockNotFound, .waiting, .movedByUser, .failed: return true
        default: return false
        }
    }

    /// S5 — off·needsPermission·inactive에서는 보조 줄을 붙이지 않는다
    private static func allowsFallbackNote(_ status: DockPinStatus) -> Bool {
        switch status {
        case .off, .needsPermission, .inactive: return false
        default: return true
        }
    }
}
