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
    let agentId: String
    @ObservedObject var store: AgentStore
    @Binding var isPresented: Bool

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 4), count: 8)

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
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(presetEmojis, id: \.self) { emoji in
                        Button(action: { selectEmoji(emoji) }) {
                            Text(emoji)
                                .font(.system(size: 20))
                                .frame(width: 32, height: 32)
                                .background(
                                    store.projectEmojis[agentId] == emoji
                                        ? Color.accentColor.opacity(0.2)
                                        : Color.clear
                                )
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if store.projectEmojis[agentId] != nil {
                    Divider()
                    Button(store.t("초기화", "Reset")) {
                        store.resetEmoji(for: agentId)
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
    }

    private func selectEmoji(_ emoji: String) {
        store.setEmoji(emoji, for: agentId)
        isPresented = false
    }
}
