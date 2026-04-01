import SwiftUI

private let presetEmojis: [String] = [
    "🚀", "🏢", "💡", "🔥", "⚡", "🌟", "🎯", "🛠",
    "📦", "🔧", "🎨", "🌈", "🦄", "🐉", "🏆", "💎",
    "🔮", "🌙", "☀️", "🌊", "🎭", "🎮", "🤖", "🦊",
    "🐼", "🐸", "🦁", "🐯", "🦋", "🌺", "🍎", "🍕",
    "🏄", "🎸", "🎵", "🧩", "🔑", "🗂", "📡", "🧠",
    "👾", "🕹", "🧬", "⚗️", "🔭", "🛸", "🌍", "🏔"
]

struct EmojiPickerView: View {
    let agent: Agent
    @ObservedObject var store: AgentStore
    @Binding var isPresented: Bool
    var initialApplyToProject: Bool = true
    @State private var applyToProject = true

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 4), count: 8)

    /// 같은 프로젝트에 세션이 여러 개인지
    private var hasMultipleSessions: Bool {
        store.agents.filter { $0.projectDir == agent.projectDir }.count > 1
    }

    /// 현재 선택된 이모지
    private var currentEmoji: String? {
        if applyToProject {
            return store.projectEmojis[agent.projectDir]
        } else {
            return store.sessionEmojis[agent.id]
        }
    }

    /// 현재 범위(프로젝트/세션)에 커스텀 이모지가 설정되어 있는지
    private var hasCustomEmoji: Bool {
        if applyToProject {
            return store.projectEmojis[agent.projectDir] != nil
        } else {
            return store.sessionEmojis[agent.id] != nil
        }
    }

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

                Text(store.t("이모지 선택", "Choose Emoji"))
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                // 세션이 여러 개일 때만 적용 범위 선택 표시
                if hasMultipleSessions {
                    Picker("", selection: $applyToProject) {
                        Text(store.t("프로젝트 전체", "Entire project")).tag(true)
                        Text(store.t("이 세션만", "This session only")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(presetEmojis, id: \.self) { emoji in
                        Button(action: { selectEmoji(emoji) }) {
                            Text(emoji)
                                .font(.system(size: 20))
                                .frame(width: 32, height: 32)
                                .background(
                                    currentEmoji == emoji
                                        ? Color.accentColor.opacity(0.2)
                                        : Color.clear
                                )
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if hasCustomEmoji {
                    Divider()
                    Button(store.t("초기화", "Reset")) {
                        if applyToProject {
                            store.resetProjectEmoji(for: agent)
                        } else {
                            store.resetEmoji(for: agent)
                        }
                        isPresented = false
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                }
            }
            .padding(12)

            Spacer()
        }
        .frame(width: 360)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { applyToProject = initialApplyToProject }
    }

    private func selectEmoji(_ emoji: String) {
        store.setEmoji(emoji, for: agent, projectWide: applyToProject)
        isPresented = false
    }
}
