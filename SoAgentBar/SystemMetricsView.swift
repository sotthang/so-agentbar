import SwiftUI

// MARK: - SystemMetricsView

/// Compact one-line CPU · MEM · DSK with mini progress bars.
struct SystemMetricsView: View {
    @ObservedObject var monitor: SystemMetricsMonitor
    @ObservedObject var store: AgentStore

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            if let m = monitor.metrics {
                HStack(spacing: 12) {
                    compactMetric(label: "CPU", percent: m.cpuPercent)
                    compactMetric(label: "MEM", percent: m.memoryPercent)
                    compactMetric(label: "DSK", percent: m.diskPercent)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            } else {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5)
                    Text(store.t("시스템 지표 로딩 중...", "Loading system metrics..."))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }

    private func compactMetric(label: String, percent: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
            miniBar(percent: percent)
                .frame(width: 40, height: 3)
            Text("\(Int(percent))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(barColor(percent))
                .frame(width: 26, alignment: .leading)
        }
    }

    private func miniBar(percent: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(NSColor.quaternaryLabelColor))
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(percent))
                    .frame(width: max(0, geo.size.width * percent / 100))
            }
        }
    }

    private func barColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .green
    }
}
