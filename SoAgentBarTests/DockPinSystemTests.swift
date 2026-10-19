import XCTest
@testable import SoAgentBar

// MARK: - DockPinSystemTests
//
// SPEC-004 커밋 11d(r6) — 새 프로세스 권한 확인의 부작용 계층(DockPinSystem.swift) 테스트.
// 커버: AC9.13 중 단위로 볼 수 있는 부분(DockPinTrustCheckCommand.run: 1회 읽기, 한 줄 출력, 종료 0),
//       AC9.15(a) 동작 수준(자식 환경 [:], stdin·stderr nullDevice, 인자 정확히 1개),
//       AC9.15(c) 어댑터 수준(식별자가 바뀌면 run() 없이 completion(nil) 1번, lastFreshFailure == .executableChanged),
//       R9.6 3번(해석 → nil 사유 N20), R9.6 4번(completion은 메인), arch §2.6 cancel 계약(자식 종료 + completion 0번),
//       arch §5 FakeDockPinPermission 새 멤버의 자체 검증.
//
// arch §8은 AC9.13·AC9.15(a, c)를 "단위 테스트 아님"으로 두었다. 이 파일은 Tester가 덧붙인 안전한 범위의 검증이다:
// - DockPinLivePermission(executableURL:)에 **임시 /bin/sh 스크립트**만 넣는다. 앱 실행 파일·AX·CG·Dock은 건드리지 않는다.
//   (실제 앱 바이너리로 하는 확인은 AC9.13 세션 안 CLI 스크립트가 맡는다.)
// - 실제 시간 대기가 있다(자식 실행·종료 왕복). 테스트 하나당 상한 3초, 대부분 0.1초 안팎이다.
// - DockPinTrustCheckCommand.runAndExit()는 프로세스를 끝내므로 부르지 않는다. 이음새 run(trusted:output:)만 본다.
//
// RED 확인: 스텁은 run → 1(아무것도 안 씀), readExecutableIdentity → nil, freshTrustCheck → 실행·응답 없음,
// lastFreshFailure → .launchFailed 이다. 그래서 가짜 자체 검증(MARK: Fake)을 뺀 테스트는 전부 실패하는 것이 정상이다.

@MainActor
final class DockPinSystemTests: XCTestCase {

    private static let timeout: TimeInterval = 3
    private static let parentOnlyEnvKey = "DOCKPIN_11D_PARENT_ONLY"

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DockPinSystemTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        unsetenv(Self.parentOnlyEnvKey)
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - 도우미

    /// `#!/bin/sh` 스크립트를 만들고 실행 권한을 준다(executable == false면 644)
    @discardableResult
    private func makeScript(_ body: String, name: String = "fake-app", executable: Bool = true) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    /// 같은 경로에 파일을 새로 만든다(지우고 다시 쓰기 → 새 inode)
    private func replaceScript(at url: URL, _ body: String) throws {
        try FileManager.default.removeItem(at: url)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private struct FreshOutcome {
        var results: [Bool?] = []
        var onMainThread: [Bool] = []
    }

    /// freshTrustCheck 1회 → completion을 기다린다(정확히 1번이어야 한다, 초과 호출은 XCTest가 실패 처리)
    private func runFresh(_ permission: DockPinLivePermission, file: StaticString = #filePath, line: UInt = #line) -> FreshOutcome {
        let done = expectation(description: "fresh completion")
        var outcome = FreshOutcome()
        let handle = permission.freshTrustCheck { result in
            outcome.results.append(result)
            outcome.onMainThread.append(Thread.isMainThread)
            done.fulfill()
        }
        wait(for: [done], timeout: Self.timeout)
        _ = handle
        return outcome
    }

    /// 짧게 더 돌려 늦게 오는 두 번째 completion이 없는지 본다
    private func drainMainQueue(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    // MARK: - AC9.13 단위부 — DockPinTrustCheckCommand.run (R9.6 1번·2번)

    func test_AC9_13_command_trusted_writesOneLine1_exitZero() {
        var reads = 0
        var lines: [String] = []
        let code = DockPinTrustCheckCommand.run(trusted: { reads += 1; return true }, output: { lines.append($0) })

        XCTAssertEqual(code, 0, "종료 코드 0")
        XCTAssertEqual(lines, ["1\n"], "표준 출력 정확히 한 줄 \"1\"")
        XCTAssertEqual(reads, 1, "AXIsProcessTrusted 1회")
    }

    func test_AC9_13_command_untrusted_writesOneLine0_exitZero() {
        var reads = 0
        var lines: [String] = []
        let code = DockPinTrustCheckCommand.run(trusted: { reads += 1; return false }, output: { lines.append($0) })

        XCTAssertEqual(code, 0, "untrusted여도 종료 코드는 0(값은 출력으로만 알린다)")
        XCTAssertEqual(lines, ["0\n"])
        XCTAssertEqual(reads, 1)
    }

    func test_AC9_13_command_outputRoundTripsThroughParser() {
        // 자식이 쓰는 형식과 부모의 해석(R9.6 3번)이 맞물린다
        for trusted in [true, false] {
            var text = ""
            let code = DockPinTrustCheckCommand.run(trusted: { trusted }, output: { text += $0 })
            XCTAssertEqual(DockPinPolicy.parseFreshTrustOutput(exitStatus: code, stdout: text), trusted, "trusted=\(trusted)")
        }
    }

    // MARK: - N17 — 실행 파일 식별자 읽기

    func test_N17_readExecutableIdentity_existingFile_matchesInode() throws {
        let url = try makeScript("echo 1")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let expectedInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value

        let identity = DockPinLivePermission.readExecutableIdentity(atPath: url.path)

        XCTAssertNotNil(identity)
        XCTAssertEqual(identity?.inode, expectedInode)
    }

    func test_N17_readExecutableIdentity_sameFileTwice_equal() throws {
        let url = try makeScript("echo 1")
        let first = DockPinLivePermission.readExecutableIdentity(atPath: url.path)
        let second = DockPinLivePermission.readExecutableIdentity(atPath: url.path)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    func test_N17_readExecutableIdentity_missingFile_nil() throws {
        let existing = try makeScript("echo 1")
        XCTAssertNil(DockPinLivePermission.readExecutableIdentity(atPath: tempDir.appendingPathComponent("nope").path))
        XCTAssertNotNil(DockPinLivePermission.readExecutableIdentity(atPath: existing.path), "짝: 있는 파일은 읽힌다")
    }

    func test_N17_readExecutableIdentity_replacedFile_differs() throws {
        let url = try makeScript("echo 1")
        let keep = tempDir.appendingPathComponent("keep-inode-busy")
        try FileManager.default.linkItem(at: url, to: keep)       // 옛 inode를 붙잡아 새 파일이 같은 번호를 받지 않게 한다
        let before = DockPinLivePermission.readExecutableIdentity(atPath: url.path)

        try replaceScript(at: url, "echo 1")
        let after = DockPinLivePermission.readExecutableIdentity(atPath: url.path)

        XCTAssertNotNil(before)
        XCTAssertNotNil(after)
        XCTAssertNotEqual(before?.inode, after?.inode, "바꿔 넣은 파일은 inode가 다르다")
        XCTAssertNotEqual(before, after)
    }

    func test_N17_readExecutableIdentity_modificationDateChanged_differs() throws {
        let url = try makeScript("echo 1")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                              ofItemAtPath: url.path)
        let before = DockPinLivePermission.readExecutableIdentity(atPath: url.path)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)],
                                              ofItemAtPath: url.path)
        let after = DockPinLivePermission.readExecutableIdentity(atPath: url.path)

        XCTAssertNotNil(before)
        XCTAssertEqual(before?.inode, after?.inode, "같은 파일")
        XCTAssertNotEqual(before, after, "수정 시각만 달라도 다르다")
    }

    // MARK: - R9.6 1번·3번·4번 — 정상 결과

    func test_R9_6_freshTrustCheck_childPrints1_completesTrueOnceOnMain() throws {
        let permission = DockPinLivePermission(executableURL: try makeScript("echo 1"))

        let outcome = runFresh(permission)
        drainMainQueue()

        XCTAssertEqual(outcome.results, [true])
        XCTAssertEqual(outcome.onMainThread, [true], "R9.6 4번: 결과 값만 메인으로")
        XCTAssertNil(permission.lastFreshFailure, "정상 결과면 사유 nil")
    }

    func test_R9_6_freshTrustCheck_childPrints0_completesFalse() throws {
        let permission = DockPinLivePermission(executableURL: try makeScript("echo 0"))

        let outcome = runFresh(permission)

        XCTAssertEqual(outcome.results, [false])
        XCTAssertNil(permission.lastFreshFailure)
    }

    func test_R9_6_freshTrustCheck_passesExactlyTrustCheckArgument() throws {
        // 자식은 인자가 정확히 1개이고 그것이 --dockpin-trust-check일 때만 1을 쓴다
        let script = """
        if [ "$#" = "1" ] && [ "$1" = "\(DockPinPolicy.trustCheckArgument)" ]; then echo 1; else echo 0; fi
        """
        let permission = DockPinLivePermission(executableURL: try makeScript(script))

        XCTAssertEqual(runFresh(permission).results, [true])
    }

    // MARK: - AC9.15(a) 동작 수준 — N16 자식 환경 정리

    func test_AC9_15a_childEnvironment_isEmpty_parentVariableNotInherited() throws {
        setenv(Self.parentOnlyEnvKey, "1", 1)
        XCTAssertEqual(ProcessInfo.processInfo.environment[Self.parentOnlyEnvKey], "1", "전제: 부모에는 있다")
        let script = """
        if [ -z "${\(Self.parentOnlyEnvKey)+x}" ] && [ -z "${HOME+x}" ] && [ -z "${DYLD_INSERT_LIBRARIES+x}" ]; then echo 1; else echo 0; fi
        """
        let permission = DockPinLivePermission(executableURL: try makeScript(script))

        XCTAssertEqual(runFresh(permission).results, [true], "environment = [:] — 부모 변수·HOME·DYLD_*가 없다")
    }

    func test_AC9_15a_childStdin_isNullDevice_readHitsEOF() throws {
        // stdin이 nullDevice면 read가 바로 EOF로 실패한다. 물려받은 입력이면 막히거나 값을 읽는다
        let permission = DockPinLivePermission(executableURL: try makeScript("if read line; then echo 0; else echo 1; fi"))

        XCTAssertEqual(runFresh(permission).results, [true])
    }

    func test_AC9_15a_childStderr_notMixedIntoStdout() throws {
        // stderr는 nullDevice — stdout 파이프에 섞이면 "noise\n1"이 되어 해석이 nil이 된다
        let permission = DockPinLivePermission(executableURL: try makeScript("echo noise 1>&2\necho 1"))

        let outcome = runFresh(permission)

        XCTAssertEqual(outcome.results, [true])
        XCTAssertNil(permission.lastFreshFailure)
    }

    // MARK: - R9.6 3번 / N20 — nil 결과와 사유

    func test_N20_unparsableOutput_nil_reasonUnparsable() throws {
        let permission = DockPinLivePermission(executableURL: try makeScript("echo yes"))

        XCTAssertEqual(runFresh(permission).results, [nil])
        XCTAssertEqual(permission.lastFreshFailure, .unparsable)
    }

    func test_N20_nonZeroExit_nil_reasonUnparsable() throws {
        let permission = DockPinLivePermission(executableURL: try makeScript("echo 1\nexit 3"))

        XCTAssertEqual(runFresh(permission).results, [nil], "종료 코드가 0이 아니면 출력이 1이어도 nil")
        XCTAssertEqual(permission.lastFreshFailure, .unparsable)
    }

    func test_N20_notExecutable_nil_reasonLaunchFailed() throws {
        let permission = DockPinLivePermission(executableURL: try makeScript("echo 1", executable: false))

        XCTAssertEqual(runFresh(permission).results, [nil], "run()이 던지면 nil")
        XCTAssertEqual(permission.lastFreshFailure, .launchFailed)
    }

    func test_N20_failureThenSuccess_reasonClearedToNil() throws {
        let url = try makeScript("echo yes")
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)     // 정수 초 — 되돌릴 때 정밀도 손실이 없다
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        let permission = DockPinLivePermission(executableURL: url)
        XCTAssertEqual(runFresh(permission).results, [nil])
        XCTAssertEqual(permission.lastFreshFailure, .unparsable)

        // 같은 파일(같은 inode)을 덮어쓰고 수정 시각을 되돌려 식별자를 그대로 둔다
        try "#!/bin/sh\necho 1\n".write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)

        XCTAssertEqual(runFresh(permission).results, [true])
        XCTAssertNil(permission.lastFreshFailure, "정상 결과가 오면 사유를 지운다")
    }

    // MARK: - AC9.15(c) 어댑터 수준 — N17 식별자 불일치면 실행하지 않는다

    func test_AC9_15c_executableReplaced_doesNotRun_completesNilOnce() throws {
        let firstMarker = tempDir.appendingPathComponent("ran-first")
        let secondMarker = tempDir.appendingPathComponent("ran-second")
        let url = try makeScript("/usr/bin/touch '\(firstMarker.path)'\necho 1")
        let keep = tempDir.appendingPathComponent("keep-inode-busy")
        try FileManager.default.linkItem(at: url, to: keep)
        let permission = DockPinLivePermission(executableURL: url)

        XCTAssertEqual(runFresh(permission).results, [true], "첫 확인: 식별자를 기록하고 실행한다")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstMarker.path), "짝: 첫 확인은 실제로 실행됐다")

        try replaceScript(at: url, "/usr/bin/touch '\(secondMarker.path)'\necho 1")
        let outcome = runFresh(permission)
        drainMainQueue()

        XCTAssertEqual(outcome.results, [nil], "식별자가 다르면 completion(nil) 1번")
        XCTAssertEqual(outcome.onMainThread, [true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondMarker.path), "run()을 부르지 않는다")
        XCTAssertEqual(permission.lastFreshFailure, .executableChanged)
    }

    func test_AC9_15c_modificationDateChanged_doesNotRun() throws {
        let marker = tempDir.appendingPathComponent("ran")
        let url = try makeScript("echo 1")
        let permission = DockPinLivePermission(executableURL: url)
        XCTAssertEqual(runFresh(permission).results, [true])

        // 같은 inode, 다른 수정 시각(같은 DerivedData 경로에 덮어 빌드한 경우)
        try "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\necho 1\n".write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                              ofItemAtPath: url.path)

        XCTAssertEqual(runFresh(permission).results, [nil])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "run()을 부르지 않는다")
        XCTAssertEqual(permission.lastFreshFailure, .executableChanged)
    }

    func test_AC9_15c_executableRemoved_completesNil_reasonExecutableChanged() throws {
        let url = try makeScript("echo 1")
        let permission = DockPinLivePermission(executableURL: url)
        XCTAssertEqual(runFresh(permission).results, [true])

        try FileManager.default.removeItem(at: url)

        XCTAssertEqual(runFresh(permission).results, [nil], "현재 식별자를 읽지 못하면 실행하지 않는다")
        XCTAssertEqual(permission.lastFreshFailure, .executableChanged)
    }

    func test_AC9_15c_unreadableOnFirstCheck_doesNotRun_thenRecordsWhenReadable() throws {
        let url = tempDir.appendingPathComponent("fake-app")
        let permission = DockPinLivePermission(executableURL: url)

        XCTAssertEqual(runFresh(permission).results, [nil], "처음부터 읽지 못하면(nil, nil) 실행하지 않는다")
        XCTAssertEqual(permission.lastFreshFailure, .executableChanged)

        try makeScript("echo 1")
        XCTAssertEqual(runFresh(permission).results, [true], "읽히게 된 첫 값을 기록하고 실행한다")
        XCTAssertNil(permission.lastFreshFailure)
    }

    func test_N17_sameIdentity_repeatedChecks_allRun() throws {
        let permission = DockPinLivePermission(executableURL: try makeScript("echo 1"))

        let results = (0..<3).flatMap { _ in runFresh(permission).results }

        XCTAssertEqual(results, [true, true, true], "식별자가 그대로면 매번 실행한다")
    }

    // MARK: - arch §2.6 — cancel(): 자식 종료 + completion 0번

    func test_cancel_runningChild_terminatesChild_andNeverCompletes() throws {
        let pidFile = tempDir.appendingPathComponent("child.pid")
        let script = "echo $$ > '\(pidFile.path)'\nexec /bin/sleep 30"     // exec — 같은 pid로 잠들어 고아 프로세스가 남지 않는다
        let permission = DockPinLivePermission(executableURL: try makeScript(script))

        let never = expectation(description: "completion must not be called")
        never.isInverted = true
        let handle = permission.freshTrustCheck { _ in never.fulfill() }

        let started = spin(until: {
            ((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").hasSuffix("\n")
        })
        XCTAssertTrue(started, "전제: 자식이 실행 중이다")
        let pidText = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
        let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        handle.cancel()

        XCTAssertGreaterThan(pid, 0)
        let gone = spin(until: { pid > 0 && kill(pid, 0) != 0 }, timeout: 2)
        XCTAssertTrue(gone, "cancel()이 실행 중인 자식을 terminate한다")
        wait(for: [never], timeout: 0.5)
        if !gone, pid > 0 { kill(pid, SIGKILL) }                 // 실패해도 자식을 남기지 않는다
    }

    func test_cancel_afterCompletion_isHarmless() throws {
        let permission = DockPinLivePermission(executableURL: try makeScript("echo 1"))
        let done = expectation(description: "completion")
        var results: [Bool?] = []
        let handle = permission.freshTrustCheck { results.append($0); done.fulfill() }
        wait(for: [done], timeout: Self.timeout)

        handle.cancel()
        handle.cancel()
        drainMainQueue()

        XCTAssertEqual(results, [true], "응답 뒤 cancel()은 아무 일도 하지 않는다")
    }

    // MARK: - Fake 자체 검증 (arch §5 FakeDockPinPermission — 11e 테스트가 기대는 계약. 지금도 통과해야 한다)

    func test_fake_freshTrustCheck_defaultPending_completeFreshDeliversOnce() {
        let fake = FakeDockPinPermission()
        var results: [Bool?] = []
        _ = fake.freshTrustCheck { results.append($0) }

        XCTAssertEqual(fake.freshCount, 1)
        XCTAssertTrue(fake.isFreshPending)
        XCTAssertEqual(results.count, 0, "기본은 무응답")

        fake.completeFresh(true)
        fake.completeFresh(false)

        XCTAssertEqual(results, [true], "completion은 최대 1번")
        XCTAssertFalse(fake.isFreshPending)
        XCTAssertEqual(fake.freshCancelCount, 0)
    }

    func test_fake_cancel_countsOnce_andLateCompleteIgnored() {
        let fake = FakeDockPinPermission()
        var results: [Bool?] = []
        let handle = fake.freshTrustCheck { results.append($0) }

        handle.cancel()
        handle.cancel()
        fake.completeFresh(true)

        XCTAssertEqual(fake.freshCancelCount, 1)
        XCTAssertFalse(fake.isFreshPending)
        XCTAssertEqual(results.count, 0, "취소된 핸들의 completion은 0번")
    }

    func test_fake_cancelAfterCompletion_notCounted() {
        let fake = FakeDockPinPermission()
        let handle = fake.freshTrustCheck { _ in }
        fake.completeFresh(nil)

        handle.cancel()

        XCTAssertEqual(fake.freshCancelCount, 0)
    }

    func test_fake_autoRespond_callsCompletionSynchronously() {
        let fake = FakeDockPinPermission()
        fake.autoRespondFresh = .some(true)
        var results: [Bool?] = []
        let handle = fake.freshTrustCheck { results.append($0) }

        XCTAssertEqual(results, [true])
        XCTAssertEqual(fake.freshCount, 1)
        XCTAssertFalse(fake.isFreshPending)
        handle.cancel()
        XCTAssertEqual(fake.freshCancelCount, 0, "이미 응답한 핸들")

        fake.autoRespondFresh = .some(nil)
        _ = fake.freshTrustCheck { results.append($0) }
        XCTAssertEqual(results, [true, nil], ".some(nil) = 결과 nil")
    }

    func test_fake_completeFresh_targetsLatestHandle() {
        let fake = FakeDockPinPermission()
        var first: [Bool?] = []
        var second: [Bool?] = []
        let old = fake.freshTrustCheck { first.append($0) }
        old.cancel()
        _ = fake.freshTrustCheck { second.append($0) }

        fake.completeFresh(false)

        XCTAssertEqual(first.count, 0)
        XCTAssertEqual(second, [false])
        XCTAssertEqual(fake.freshCount, 2)
    }

    func test_fake_lastFreshFailure_settable_defaultNil() {
        let fake = FakeDockPinPermission()
        XCTAssertNil(fake.lastFreshFailure)
        fake.lastFreshFailure = .executableChanged
        XCTAssertEqual((fake as DockPinPermissionProviding).lastFreshFailure, .executableChanged)
    }
}
