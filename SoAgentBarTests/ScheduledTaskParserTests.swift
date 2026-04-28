import XCTest
@testable import SoAgentBar

final class ScheduledTaskParserTests: XCTestCase {

    func test_parse_returnsNil_whenNotScheduledTask() {
        let result = ScheduledTaskParser.parse("그냥 일반 메시지입니다")
        XCTAssertNil(result)
    }

    func test_parse_extractsNameAndPrompt_fromTypicalContent() {
        let content = """
        <scheduled-task name="agent-gcp-log-monitoring" file="/path/to/SKILL.md">
        This is an automated run of a scheduled task. The user is not present to answer questions. For implementation details, execute autonomously without asking clarifying questions — make reasonable choices and note them in your output. "write" actions (e.g. MCP tools that send, post, create, update, or delete), only take them if the task file asks for that specific action. When in doubt, producing a report of what you found is the correct output.

        GCP 로그 조회해서 에러, 경고 파악하고 분석해서 알려줘
        </scheduled-task>
        """
        let result = ScheduledTaskParser.parse(content)
        XCTAssertEqual(result?.name, "agent-gcp-log-monitoring")
        XCTAssertEqual(result?.prompt, "GCP 로그 조회해서 에러, 경고 파악하고 분석해서 알려줘")
    }

    func test_parse_extractsName_whenAttributeOrderReversed() {
        let content = """
        <scheduled-task file="/path/to/SKILL.md" name="my-task">
        boilerplate text here.

        실제 프롬프트
        </scheduled-task>
        """
        let result = ScheduledTaskParser.parse(content)
        XCTAssertEqual(result?.name, "my-task")
        XCTAssertEqual(result?.prompt, "실제 프롬프트")
    }

    func test_parse_returnsEntireBody_whenNoBoilerplateSeparator() {
        let content = """
        <scheduled-task name="quick-task">
        단일 단락 프롬프트
        </scheduled-task>
        """
        let result = ScheduledTaskParser.parse(content)
        XCTAssertEqual(result?.name, "quick-task")
        XCTAssertEqual(result?.prompt, "단일 단락 프롬프트")
    }

    func test_parse_handlesMultilinePromptParagraph() {
        let content = """
        <scheduled-task name="multi">
        boilerplate line.

        프롬프트 첫줄
        프롬프트 둘째줄
        </scheduled-task>
        """
        let result = ScheduledTaskParser.parse(content)
        XCTAssertEqual(result?.name, "multi")
        XCTAssertEqual(result?.prompt, "프롬프트 첫줄\n프롬프트 둘째줄")
    }

    func test_parse_returnsNilName_whenNameAttributeMissing() {
        let content = """
        <scheduled-task file="/some/path">
        boilerplate.

        프롬프트
        </scheduled-task>
        """
        let result = ScheduledTaskParser.parse(content)
        XCTAssertNil(result?.name)
        XCTAssertEqual(result?.prompt, "프롬프트")
    }

    func test_displayTitle_combinesNameAndPrompt() {
        let parsed = ScheduledTaskParser.Result(name: "agent-gcp", prompt: "로그 조회해줘")
        XCTAssertEqual(parsed.displayTitle, "📅 [agent-gcp] 로그 조회해줘")
    }

    func test_displayTitle_omitsBracketsWhenNameNil() {
        let parsed = ScheduledTaskParser.Result(name: nil, prompt: "로그 조회해줘")
        XCTAssertEqual(parsed.displayTitle, "📅 로그 조회해줘")
    }
}
