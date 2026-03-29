import SwiftUI

struct StatsView: View {
    @ObservedObject var statsStore: StatsStore
    @ObservedObject var store: AgentStore
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            HStack {
                Button(action: { isPresented = false }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Text(store.t("통계", "Statistics"))
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    todaySection
                    Divider().padding(.leading, 16)
                    weeklyChart
                    Divider().padding(.leading, 16)
                    topProjectsSection
                }
            }

            Spacer()
        }
        .frame(width: 360)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 오늘 요약

    private var todaySection: some View {
        let today = statsStore.today()
        return VStack(alignment: .leading, spacing: 8) {
            Text(store.t("오늘", "Today"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.bottom, 2)

            HStack(spacing: 16) {
                statBadge(
                    icon: "bubble.left.and.bubble.right",
                    value: "\(today.sessionCount)",
                    label: store.t("세션", "Sessions")
                )
                statBadge(
                    icon: "number",
                    value: formatTokens(today.totalTokens),
                    label: store.t("토큰", "Tokens")
                )
                statBadge(
                    icon: "arrow.triangle.branch",
                    value: "\(today.cliSessions)/\(today.xcodeSessions)",
                    label: "CLI/Xcode"
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func statBadge(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 주간 차트

    private var weeklyChart: some View {
        let days = statsStore.recentDays(7)
        let maxSessions = days.map(\.stats.sessionCount).max() ?? 1

        return VStack(alignment: .leading, spacing: 8) {
            Text(store.t("최근 7일", "Last 7 Days"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days, id: \.date) { day in
                    VStack(spacing: 4) {
                        // 바
                        RoundedRectangle(cornerRadius: 3)
                            .fill(day.stats.sessionCount > 0 ? Color.accentColor : Color(NSColor.separatorColor))
                            .frame(
                                width: 32,
                                height: max(4, CGFloat(day.stats.sessionCount) / CGFloat(max(maxSessions, 1)) * 80)
                            )

                        // 세션 수
                        Text("\(day.stats.sessionCount)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)

                        // 요일
                        Text(shortWeekday(day.date))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            // 주간 합계
            let weekTotal = days.reduce(0) { $0 + $1.stats.totalTokens }
            if weekTotal > 0 {
                Text(store.t("주간 총 \(formatTokens(weekTotal)) 토큰", "Weekly total: \(formatTokens(weekTotal)) tokens"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 프로젝트 랭킹

    private var topProjectsSection: some View {
        let projects = statsStore.topProjects()

        return VStack(alignment: .leading, spacing: 8) {
            Text(store.t("프로젝트 (7일)", "Projects (7 days)"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            if projects.isEmpty {
                Text(store.t("아직 데이터 없음", "No data yet"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(projects, id: \.name) { proj in
                    HStack {
                        Text(proj.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text("\(proj.sessions)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(store.t("세션", "sess"))
                            .font(.system(size: 10))
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                        Text(formatTokens(proj.tokens))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 유틸

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }

    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let weekdayKo: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "E"
        f.locale = Locale(identifier: "ko_KR")
        return f
    }()

    private static let weekdayEn: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    private func shortWeekday(_ dateStr: String) -> String {
        guard let date = Self.dateParser.date(from: dateStr) else { return "" }
        return (store.language == .korean ? Self.weekdayKo : Self.weekdayEn).string(from: date)
    }
}
