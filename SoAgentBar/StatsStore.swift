import Foundation

// MARK: - 통계 모델

struct ProjectStats: Codable {
    var sessions: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0

    var totalTokens: Int { inputTokens + outputTokens }
}

struct DailyStats: Codable {
    var sessionCount: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var projects: [String: ProjectStats] = [:]
    var cliSessions: Int = 0
    var xcodeSessions: Int = 0
    /// 시간대별 세션 수 (key: "0"~"23")
    var hourlyActivity: [String: Int] = [:]
    /// 일별 비용 합계 ($). 기본값 0.0으로 기존 stats.json 하위 호환성 보장.
    var estimatedCost: Double = 0.0

    var totalTokens: Int { inputTokens + outputTokens }
}

struct StatsData: Codable {
    var daily: [String: DailyStats] = [:]  // key: "2026-03-27"
}

// MARK: - StatsStore

@MainActor
class StatsStore: ObservableObject {
    @Published var data = StatsData()

    private static let dirURL: URL = {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".agentbar")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static var fileURL: URL {
        dirURL.appendingPathComponent("stats.json")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        load()
        pruneOldData()
    }

    // MARK: - 세션 완료 시 통계 기록

    func record(agent: Agent) {
        let key = Self.dateFormatter.string(from: Date())
        var day = data.daily[key] ?? DailyStats()

        day.sessionCount += 1
        day.inputTokens += agent.inputTokens
        day.outputTokens += agent.outputTokens

        // 프로젝트별
        let projectName = URL(fileURLWithPath: agent.workingPath).lastPathComponent
        var proj = day.projects[projectName] ?? ProjectStats()
        proj.sessions += 1
        proj.inputTokens += agent.inputTokens
        proj.outputTokens += agent.outputTokens
        day.projects[projectName] = proj

        // 소스별
        switch agent.source {
        case .cli, .desktopCode:           day.cliSessions += 1
        case .xcode:                       day.xcodeSessions += 1
        case .desktopCowork:               day.cliSessions += 1
        case .codexCLI, .codexVSCode:      day.cliSessions += 1
        }

        // 시간대별 활동 기록
        let hour = Calendar.current.component(.hour, from: Date())
        day.hourlyActivity["\(hour)", default: 0] += 1

        // 비용 누적
        if let cost = agent.estimatedCost {
            day.estimatedCost += cost
        }

        data.daily[key] = day
        save()
    }

    // MARK: - 조회 헬퍼

    func today() -> DailyStats {
        let key = Self.dateFormatter.string(from: Date())
        return data.daily[key] ?? DailyStats()
    }

    func recentDays(_ count: Int) -> [(date: String, stats: DailyStats)] {
        let cal = Calendar.current
        return (0..<count).compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            let key = Self.dateFormatter.string(from: date)
            return (date: key, stats: data.daily[key] ?? DailyStats())
        }.reversed()
    }

    /// 최근 N일 시간대별 세션 합계 반환 (key: 0~23)
    func hourlyActivitySummary(days: Int = 7) -> [Int: Int] {
        var result = [Int: Int]()
        let cal = Calendar.current
        for offset in 0..<days {
            guard let date = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let key = Self.dateFormatter.string(from: date)
            guard let day = data.daily[key] else { continue }
            for (hourStr, count) in day.hourlyActivity {
                if let hour = Int(hourStr) {
                    result[hour, default: 0] += count
                }
            }
        }
        return result
    }

    func topProjects(days: Int = 7, limit: Int = 5) -> [(name: String, tokens: Int, sessions: Int)] {
        var merged: [String: ProjectStats] = [:]
        let cal = Calendar.current

        for offset in 0..<days {
            guard let date = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let key = Self.dateFormatter.string(from: date)
            guard let day = data.daily[key] else { continue }
            for (name, proj) in day.projects {
                var m = merged[name] ?? ProjectStats()
                m.sessions     += proj.sessions
                m.inputTokens  += proj.inputTokens
                m.outputTokens += proj.outputTokens
                merged[name] = m
            }
        }

        return merged
            .map { (name: $0.key, tokens: $0.value.totalTokens, sessions: $0.value.sessions) }
            .sorted { $0.tokens > $1.tokens }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - 영속화

    private func load() {
        guard let jsonData = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode(StatsData.self, from: jsonData)
        else { return }
        data = decoded
    }

    private func save() {
        guard let jsonData = try? JSONEncoder().encode(data) else { return }
        try? jsonData.write(to: Self.fileURL, options: .atomic)
    }

    private func pruneOldData() {
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -30, to: Date()) else { return }
        let cutoffKey = Self.dateFormatter.string(from: cutoff)

        let before = data.daily.count
        data.daily = data.daily.filter { $0.key >= cutoffKey }
        if data.daily.count < before { save() }
    }
}
