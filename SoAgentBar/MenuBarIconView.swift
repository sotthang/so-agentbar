import SwiftUI

// SwiftUI 상태 점 뷰
struct StatusDot: View {
    let status: AgentStatus

    var color: Color {
        switch status {
        case .idle: return .gray
        case .thinking: return .orange
        case .working: return .green
        case .error: return .red
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.3), lineWidth: 2)
                    .scaleEffect(status == .working ? 1.5 : 1.0)
                    .opacity(status == .working ? 1 : 0)
                    .animation(
                        status == .working
                            ? .easeInOut(duration: 1).repeatForever(autoreverses: true)
                            : .default,
                        value: status == .working
                    )
            )
    }
}
