import SwiftUI

struct AgentListView: View {
    @ObservedObject var store: AgentStore
    @State private var showSettings = false
    @State private var showStats = false
    @State private var emojiPickerAgentId: String? = nil

    var body: some View {
        Group {
            if showSettings {
                SettingsView(store: store, isPresented: $showSettings)
            } else if showStats {
                StatsView(statsStore: store.statsStore, store: store, isPresented: $showStats)
            } else if let agentId = emojiPickerAgentId {
                EmojiPickerView(agentId: agentId, store: store, isPresented: .init(
                    get: { emojiPickerAgentId != nil },
                    set: { if !$0 { emojiPickerAgentId = nil } }
                ))
            } else {
                mainView
            }
        }
        .frame(width: 360, height: 500)
        .clipped()
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var mainView: some View {
        VStack(spacing: 0) {
            header
            Divider()
            agentList
            UsageView(monitor: store.usageMonitor, store: store)
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Text("AgentBar")
                .font(.headline)
                .fontWeight(.semibold)
            Spacer()
            let activeCount = store.agents.filter { $0.status == .working || $0.status == .thinking }.count
            Text("\(activeCount) \(store.t("활성", "active"))")
                .font(.caption)
                .foregroundColor(.secondary)
            Button(action: { store.isPinned.toggle() }) {
                Image(systemName: store.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 13))
                    .foregroundColor(store.isPinned ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(store.t("팝오버 고정", "Pin popover"))
            Button(action: { showStats = true }) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(store.t("통계", "Statistics"))
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var agentList: some View {
        Group {
            if store.agents.isEmpty {
                VStack(spacing: 8) {
                    Text("🔍")
                        .font(.system(size: 32))
                    Text(store.t("실행 중인 claude 세션 없음", "No running claude sessions"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(store.agents) { agent in
                            AgentRowView(agent: agent, store: store, onEmojiTap: {
                                emojiPickerAgentId = agent.id
                            })
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(store.t("CLI + Xcode 세션 감지 중", "Monitoring CLI + Xcode sessions"))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button(action: { NSApp.terminate(nil) }) {
                Text(store.t("종료", "Quit"))
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct AgentRowView: View {
    let agent: Agent
    @ObservedObject var store: AgentStore
    var onEmojiTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Text(store.displayEmoji(for: agent))
                    .font(.system(size: 28))
                StatusDot(status: agent.status)
                    .offset(x: 2, y: 2)
            }
            .frame(width: 36, height: 36)
            .onTapGesture { onEmojiTap() }
            .help(store.t("이모지 변경", "Change emoji"))

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    if agent.status == .working {
                        Text(agent.elapsedDisplay)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Text(agent.currentTask)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if agent.status == .idle, agent.lastActivity > Date(timeIntervalSince1970: 0) {
                    Text(store.relativeTime(agent.lastActivity))
                        .font(.system(size: 10))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
            }

            if isHovering {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            } else if agent.totalTokens > 0 {
                Text(formatTokens(agent.totalTokens))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(NSColor.quaternaryLabelColor))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            isHovering
                ? Color(NSColor.selectedContentBackgroundColor).opacity(0.1)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { store.openProject(agent.workingPath, source: agent.source) }
        .help(agent.lastResponse.isEmpty
              ? agent.workingPath
              : agent.lastResponse)
    }

    private func formatTokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }
}

struct TokenBadge: View {
    let input: Int
    let output: Int

    var body: some View {
        HStack(spacing: 4) {
            Label("\(formatK(input))", systemImage: "arrow.down.circle")
                .font(.system(size: 10))
            Label("\(formatK(output))", systemImage: "arrow.up.circle")
                .font(.system(size: 10))
        }
        .foregroundColor(.secondary)
    }

    private func formatK(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n)/1000) : "\(n)"
    }
}
