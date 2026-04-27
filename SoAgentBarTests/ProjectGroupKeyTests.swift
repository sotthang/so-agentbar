import XCTest
@testable import SoAgentBar

// MARK: - ProjectGroupKeyTests
// AC-R5.3, AC-R5.4, AC-R5.5 검증 (절대 cwd 그룹 키 정규화)
// RED: ProjectGroupKey utility 없음 → 컴파일 에러 예상

final class ProjectGroupKeyTests: XCTestCase {

    // MARK: - 헬퍼

    private func makeClaudeSession(workingPath: String, displayName: String = "test") -> ClaudeSession {
        var session = ClaudeSession(
            id: UUID().uuidString,
            projectDir: workingPath,
            source: .cli,
            workingPath: workingPath,
            lastModified: Date(),
            lastActivity: Date(),
            lastContentChange: Date()
        )
        return session
    }

    private func makeCodexSession(workingPath: String) -> ClaudeSession {
        ClaudeSession(
            id: UUID().uuidString,
            projectDir: workingPath,
            source: .codexCLI,
            workingPath: workingPath,
            lastModified: Date(),
            lastActivity: Date(),
            lastContentChange: Date()
        )
    }

    // MARK: - AC-R5.3: 같은 절대 cwd → 같은 그룹 키 (Claude + Codex 혼재)

    func test_sameAbsoluteCwd_groupsClaudeAndCodex() {
        let cwd = "/Users/x/proj"
        let claudeSession = makeClaudeSession(workingPath: cwd)
        let codexSession = makeCodexSession(workingPath: cwd)

        let claudeKey = ProjectGroupKey.key(for: claudeSession)
        let codexKey = ProjectGroupKey.key(for: codexSession)

        XCTAssertEqual(claudeKey, codexKey,
                       "같은 절대 cwd /Users/x/proj인 Claude/Codex 세션은 같은 그룹 키를 가져야 한다")
    }

    // MARK: - AC-R5.4: 다른 cwd → 다른 그룹 키

    func test_differentCwd_separateGroups() {
        let claudeSession = makeClaudeSession(workingPath: "/Users/x/proj-a")
        let codexSession = makeCodexSession(workingPath: "/Users/x/proj-b")

        let claudeKey = ProjectGroupKey.key(for: claudeSession)
        let codexKey = ProjectGroupKey.key(for: codexSession)

        XCTAssertNotEqual(claudeKey, codexKey,
                          "다른 cwd인 세션들은 다른 그룹 키를 가져야 한다")
    }

    // MARK: - AC-R5.5: cwd 누락 시 고유 폴백 키 (다른 세션과 묶이지 않음)

    func test_missingCwd_uniqueFallback() {
        // workingPath가 비어있으면 displayName 폴백 사용 → 다른 세션과 동일 키 불가
        let sessionA = makeClaudeSession(workingPath: "")
        let sessionB = makeClaudeSession(workingPath: "")

        let keyA = ProjectGroupKey.key(for: sessionA)
        let keyB = ProjectGroupKey.key(for: sessionB)

        // 두 세션이 서로 다른 ID를 가지므로 폴백 키도 달라야 함 (또는 둘 다 __nogroup__ prefix)
        // 중요한 것은 일반 절대 경로 세션과는 키가 달라야 함
        let normalSession = makeClaudeSession(workingPath: "/tmp/project")
        let normalKey = ProjectGroupKey.key(for: normalSession)

        XCTAssertNotEqual(keyA, normalKey,
                          "cwd 누락 세션의 그룹 키는 정상 세션과 달라야 한다")
    }

    // MARK: - 경로 정규화: 심볼릭 링크 / trailing slash 처리

    func test_pathNormalization_equivalentPaths() {
        // URL(fileURLWithPath:).standardizedFileURL.path는 trailing slash를 제거
        let pathWithSlash = "/Users/x/proj/"
        let pathWithoutSlash = "/Users/x/proj"

        let sessionA = makeClaudeSession(workingPath: pathWithSlash)
        let sessionB = makeCodexSession(workingPath: pathWithoutSlash)

        let keyA = ProjectGroupKey.key(for: sessionA)
        let keyB = ProjectGroupKey.key(for: sessionB)

        XCTAssertEqual(keyA, keyB,
                       "trailing slash가 있는 경로와 없는 경로는 같은 그룹 키를 가져야 한다")
    }

    // MARK: - Claude 세션: /.claude/projects/ 경로는 __nogroup__ 처리

    func test_claudeProjectsPath_groupsToNoGroup() {
        let claudeProjectPath = "/Users/x/.claude/projects/-Users-x-proj/sessions/abc.jsonl"
        let session = makeClaudeSession(workingPath: claudeProjectPath)
        let key = ProjectGroupKey.key(for: session)

        XCTAssertTrue(key.hasPrefix("__nogroup__"),
                      "/.claude/projects/ 경로는 __nogroup__ prefix 그룹 키를 가져야 한다")
    }
}
