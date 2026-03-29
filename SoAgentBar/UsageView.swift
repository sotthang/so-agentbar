import SwiftUI

struct UsageView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var store: AgentStore

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            if monitor.isLoading && monitor.usage == nil {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text(store.t("쿼터 로딩 중...", "Loading quota..."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            } else if let err = monitor.errorMessage, monitor.usage == nil {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(action: { Task { await monitor.fetch() } }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            } else if let u = monitor.usage {
                VStack(spacing: 8) {
                    // 헤더
                    HStack {
                        Text(store.t("Claude 쿼터", "Claude Quota"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        if let plan = u.planName {
                            Text(plan)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .cornerRadius(4)
                        }
                        Spacer()
                        Button(action: { Task { await monitor.fetch() } }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                        }
                        .buttonStyle(.plain)
                    }

                    // 세션 (5시간)
                    quotaRow(
                        label: store.t("세션 (5h)", "Session (5h)"),
                        utilization: u.sessionUtilization,
                        resetsAt: u.sessionResetsAt
                    )

                    // 주간
                    quotaRow(
                        label: store.t("주간", "Weekly"),
                        utilization: u.weeklyUtilization,
                        resetsAt: u.weeklyResetsAt
                    )

                    // Extra Usage
                    if u.extraEnabled {
                        HStack {
                            Text(store.t("추가 사용", "Extra"))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("$\(String(format: "%.2f", u.extraSpentDollars)) / $\(String(format: "%.0f", u.extraLimitDollars))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private func quotaRow(label: String, utilization: Double, resetsAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(utilization))% \(store.t("사용", "used"))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(barColor(utilization))
                if let resetsAt {
                    Text("· \(resetLabel(resetsAt))")
                        .font(.system(size: 10))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(NSColor.quaternaryLabelColor))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(utilization))
                        .frame(width: max(0, geo.size.width * utilization / 100), height: 4)
                }
            }
            .frame(height: 4)
        }
    }

    private func barColor(_ utilization: Double) -> Color {
        if utilization >= 90 { return .red }
        if utilization >= 70 { return .orange }
        return .green
    }

    private func resetLabel(_ date: Date) -> String {
        let diff = date.timeIntervalSince(Date())
        guard diff > 0 else { return store.t("리셋 중", "resetting") }
        let h = Int(diff / 3600)
        let m = Int((diff.truncatingRemainder(dividingBy: 3600)) / 60)
        if h >= 24 { return store.t("\(h/24)일 후", "in \(h/24)d") }
        if h > 0   { return store.t("\(h)h \(m)m 후", "in \(h)h \(m)m") }
        return store.t("\(m)m 후", "in \(m)m")
    }
}
