import Cocoa

// SPEC-004 R9.6 2번 — 새 프로세스 권한 확인 단축 경로. NSApplication·AppDelegate보다 반드시 먼저다(AC9.13).
if DockPinPolicy.isTrustCheckInvocation(arguments: CommandLine.arguments) {
    DockPinTrustCheckCommand.runAndExit()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
