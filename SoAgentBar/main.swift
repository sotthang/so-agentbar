import Cocoa

// SPEC-004 R9.6 2번 — 새 프로세스 권한 확인 단축 경로. NSApplication·AppDelegate보다 반드시 먼저다(AC9.13).
if DockPinPolicy.isTrustCheckInvocation(arguments: CommandLine.arguments) {
    DockPinTrustCheckCommand.runAndExit()
}

// SPEC-004 R9.6 1번(r6.1, VULN-001) — 새 프로세스 확인 전 코드 신원 비교의 기준을 프로세스 시작 때 고정한다.
DockPinRunningCodeBaseline.recordAtLaunch()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
