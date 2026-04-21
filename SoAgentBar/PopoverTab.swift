import SwiftUI

enum PopoverTab: String, CaseIterable, Identifiable {
    case agents
    case clipboard
    case note

    var id: String { rawValue }

    func title(store: AgentStore) -> String {
        switch self {
        case .agents:    return store.t("에이전트", "Agents")
        case .clipboard: return store.t("클립보드", "Clipboard")
        case .note:      return store.t("노트", "Note")
        }
    }

    var sfSymbol: String {
        switch self {
        case .agents:    return "person.2"
        case .clipboard: return "doc.on.clipboard"
        case .note:      return "note.text"
        }
    }
}

struct PopoverTabSwitcher: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PopoverTab.allCases) { tab in
                Button(action: { store.selectedTab = tab }) {
                    HStack(spacing: 4) {
                        Image(systemName: tab.sfSymbol)
                            .font(.system(size: 11))
                        Text(tab.title(store: store))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(
                        store.selectedTab == tab
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
                    .foregroundColor(
                        store.selectedTab == tab ? .accentColor : .secondary
                    )
                    .cornerRadius(6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
