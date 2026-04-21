import Foundation
import Combine
import IOKit.pwr_mgt

// MARK: - KeepAwakeMode

enum KeepAwakeMode: String, CaseIterable, Codable {
    case off
    case always
    case auto

    /// Click order: off → always → auto → off
    var next: KeepAwakeMode {
        switch self {
        case .off:    return .always
        case .always: return .auto
        case .auto:   return .off
        }
    }
}

// MARK: - PowerAssertionProvider

protocol PowerAssertionProvider {
    func createAssertion(type: String, name: String) -> Bool
    func releaseAssertion(type: String)
    var isSystemAssertionHeld: Bool { get }
    var isDisplayAssertionHeld: Bool { get }
}

// MARK: - IOKit real implementation

final class IOKitPowerAssertionProvider: PowerAssertionProvider {
    private var systemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private(set) var isSystemAssertionHeld: Bool = false
    private(set) var isDisplayAssertionHeld: Bool = false

    func createAssertion(type: String, name: String) -> Bool {
        var success = true
        if type.contains("SystemSleep") && !isSystemAssertionHeld {
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                name as CFString,
                &systemAssertionID
            )
            if result == kIOReturnSuccess { isSystemAssertionHeld = true } else { success = false }
        }
        if type.contains("DisplaySleep") && !isDisplayAssertionHeld {
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                name as CFString,
                &displayAssertionID
            )
            if result == kIOReturnSuccess { isDisplayAssertionHeld = true } else { success = false }
        }
        return success
    }

    func releaseAssertion(type: String) {
        if type.contains("SystemSleep") && isSystemAssertionHeld {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
            isSystemAssertionHeld = false
        }
        if type.contains("DisplaySleep") && isDisplayAssertionHeld {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
            isDisplayAssertionHeld = false
        }
    }
}

// MARK: - KeepAwakeManager

@MainActor
final class KeepAwakeManager: ObservableObject {

    @Published private(set) var isAssertionActive: Bool = false

    @Published var mode: KeepAwakeMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Keys.mode)
            reconcile()
        }
    }

    private let assertionProvider: PowerAssertionProvider
    private let defaults: UserDefaults
    private var activeSessions: Int = 0

    private enum Keys {
        static let mode = "keepAwakeMode"
    }

    init(
        initialMode: KeepAwakeMode = .off,
        assertionProvider: PowerAssertionProvider? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.assertionProvider = assertionProvider ?? IOKitPowerAssertionProvider()
        self.mode = initialMode
        reconcile()
    }

    /// Called by AgentStore whenever the active-session count changes.
    func updateActiveSessionCount(_ count: Int) {
        activeSessions = count
        reconcile()
    }

    func applyAutoState(sessionsActive: Bool) {
        updateActiveSessionCount(sessionsActive ? 1 : 0)
    }

    /// Explicit teardown on applicationWillTerminate.
    func releaseAll() {
        assertionProvider.releaseAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep)
        assertionProvider.releaseAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep)
        isAssertionActive = false
    }

    // MARK: - Private

    private func reconcile() {
        let shouldBeActive: Bool
        switch mode {
        case .off:
            shouldBeActive = false
        case .always:
            shouldBeActive = true
        case .auto:
            shouldBeActive = activeSessions > 0
        }

        if shouldBeActive {
            enable()
        } else {
            disable()
        }
    }

    private func enable() {
        let name = "so-agentbar Keep Awake"
        _ = assertionProvider.createAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep, name: name)
        _ = assertionProvider.createAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep, name: name)
        isAssertionActive = assertionProvider.isSystemAssertionHeld && assertionProvider.isDisplayAssertionHeld
    }

    private func disable() {
        assertionProvider.releaseAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep)
        assertionProvider.releaseAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep)
        isAssertionActive = false
    }
}
