import SwiftUI

// MARK: - UsageView (다중 섹션 컨테이너, design.md 컴포넌트 1)
//
// coordinator.providers (고정 순서 Claude→Codex→Gemini) 를
// ProviderUsageSection으로 렌더한다.
// Claude 1개뿐이면 기존 시각과 동일 (NFR5 회귀 방지).

struct UsageView: View {
    @ObservedObject var coordinator: UsageCoordinator
    @ObservedObject var store: AgentStore

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            ForEach(Array(coordinator.providers.enumerated()), id: \.element.id) { index, usage in
                if index > 0 {
                    Divider().padding(.leading, 16)
                }
                ProviderUsageSection(usage: usage, store: store) {
                    coordinator.refresh(usage.id)
                }
            }
        }
    }
}
