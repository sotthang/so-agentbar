import SwiftUI

// SwiftUI 상태 점 뷰
struct StatusDot: View {
    let status: AgentStatus

    var color: Color {
        switch status {
        case .idle:             return .gray
        case .thinking:         return .orange
        case .working:          return .green
        case .waitingApproval:  return .yellow
        case .error:            return .red
        }
    }

    private var isPulsing: Bool {
        status == .working || status == .waitingApproval
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.3), lineWidth: 2)
                    .scaleEffect(isPulsing ? 1.5 : 1.0)
                    .opacity(isPulsing ? 1 : 0)
                    .animation(
                        isPulsing
                            ? .easeInOut(duration: 1).repeatForever(autoreverses: true)
                            : .default,
                        value: isPulsing
                    )
            )
    }
}
