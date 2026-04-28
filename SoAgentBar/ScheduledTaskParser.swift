import Foundation

/// Claude Cowork에서 scheduled task 실행 시 wrap되는 `<scheduled-task name="..." file="...">...</scheduled-task>`
/// 컨텐트에서 task 이름과 사용자 프롬프트를 추출한다.
enum ScheduledTaskParser {

    struct Result: Equatable {
        let name: String?
        let prompt: String

        var displayTitle: String {
            if let name, !name.isEmpty {
                return "📅 [\(name)] \(prompt)"
            }
            return "📅 \(prompt)"
        }
    }

    static func parse(_ content: String) -> Result? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<scheduled-task") else { return nil }
        guard let openTagEnd = trimmed.firstIndex(of: ">") else { return nil }

        let openTag = String(trimmed[trimmed.startIndex...openTagEnd])
        let name = extractAttribute("name", from: openTag)

        let bodyStart = trimmed.index(after: openTagEnd)
        var body = String(trimmed[bodyStart...])
        if let closeRange = body.range(of: "</scheduled-task>", options: .backwards) {
            body = String(body[..<closeRange.lowerBound])
        }

        let prompt = extractPrompt(from: body)
        return Result(name: name, prompt: prompt)
    }

    /// body에서 boilerplate를 제거하고 실제 프롬프트만 추출.
    /// - 단락 구분자 `\n\n`로 split → 마지막 비어있지 않은 단락 반환
    /// - 단락이 1개면 그대로 반환
    private static func extractPrompt(from body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let paragraphs = trimmed.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.last ?? trimmed
    }

    /// 태그 문자열에서 `attr="value"` 형태의 속성 값을 추출.
    private static func extractAttribute(_ attr: String, from tag: String) -> String? {
        guard let range = tag.range(of: "\(attr)=\"") else { return nil }
        let valueStart = range.upperBound
        guard let endQuote = tag[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(tag[valueStart..<endQuote])
    }
}
