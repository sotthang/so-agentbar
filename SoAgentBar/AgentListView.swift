import SwiftUI
import Sparkle

struct AgentListView: View {
    @ObservedObject var store: AgentStore
    let updater: SPUUpdater
    @State private var showSettings = false
    @State private var showStats = false
    @State private var emojiPickerAgent: Agent? = nil
    @State private var emojiPickerProjectWide: Bool = true

    var body: some View {
        Group {
            if showSettings {
                SettingsView(store: store, updater: updater, isPresented: $showSettings)
            } else if showStats {
                StatsView(statsStore: store.statsStore, store: store, isPresented: $showStats)
            } else if let agent = emojiPickerAgent {
                EmojiPickerView(agent: agent, store: store, isPresented: .init(
                    get: { emojiPickerAgent != nil },
                    set: { if !$0 { emojiPickerAgent = nil } }
                ), initialApplyToProject: emojiPickerProjectWide)
            } else {
                mainView
            }
        }
        .frame(width: 360, height: 500)
        .clipped()
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: store.popoverOpenCount) {
            showSettings = false
            showStats = false
            emojiPickerAgent = nil
        }
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
            Text("so-agentbar")
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
                        switch store.listStyle {
                        case .flat:
                            flatList
                        case .grouped:
                            groupedList
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
        }
    }

    private var flatList: some View {
        ForEach(store.agents) { agent in
            AgentRowView(agent: agent, store: store, onEmojiTap: {
                emojiPickerProjectWide = true
                emojiPickerAgent = agent
            })
        }
    }

    private var groupedList: some View {
        let grouped = Dictionary(grouping: store.agents, by: \.projectDir)
        // 그룹 내 최신 세션 기준으로 프로젝트 정렬
        let sortedKeys = grouped.keys.sorted { a, b in
            let aDate = grouped[a]?.first?.lastActivity ?? .distantPast
            let bDate = grouped[b]?.first?.lastActivity ?? .distantPast
            return aDate > bDate
        }
        return ForEach(sortedKeys, id: \.self) { projectDir in
            if let sessions = grouped[projectDir] {
                ProjectGroupView(
                    sessions: sessions,
                    store: store,
                    onProjectEmojiTap: { agent in
                        emojiPickerProjectWide = true
                        emojiPickerAgent = agent
                    },
                    onSessionEmojiTap: { agent in
                        emojiPickerProjectWide = false
                        emojiPickerAgent = agent
                    }
                )
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
        VStack(alignment: .leading, spacing: 0) {
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
                        Text(agent.modeDisplayName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(agent.permissionMode == "acceptEdits" || agent.permissionMode == "auto" ? .green : .orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                (agent.permissionMode == "acceptEdits" || agent.permissionMode == "auto" ? Color.green : Color.orange)
                                    .opacity(0.15)
                            )
                            .cornerRadius(3)
                        if !agent.modelDisplayName.isEmpty {
                            Text(agent.modelDisplayName)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color(NSColor.quaternaryLabelColor))
                                .cornerRadius(3)
                        }
                        Spacer()
                        if agent.status == .working || agent.status == .waitingApproval {
                            Text(agent.elapsedDisplay)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(agent.status == .waitingApproval ? .orange : .secondary)
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

            // 호버 시 마지막 응답 미리보기
            if isHovering, !agent.lastResponse.isEmpty {
                Text(agent.lastResponse)
                    .font(.system(size: 10))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.top, 4)
                    .padding(.leading, 46) // 이모지(36) + spacing(10) 정렬
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
    }

    private func formatTokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }
}

// MARK: - 프로젝트 그룹 뷰 (트리형)

struct ProjectGroupView: View {
    let sessions: [Agent]
    @ObservedObject var store: AgentStore
    var onProjectEmojiTap: (Agent) -> Void
    var onSessionEmojiTap: (Agent) -> Void
    @State private var isExpanded = false

    private var projectName: String {
        // "#1" 등의 세션 번호 제거하여 프로젝트명만 추출
        let name = sessions.first?.name ?? ""
        return name.replacingOccurrences(of: #" #\d+$"#, with: "", options: .regularExpression)
    }

    private var activeCount: Int {
        sessions.filter { $0.status == .working || $0.status == .thinking }.count
    }

    private var projectEmoji: String {
        if let agent = sessions.first {
            return store.projectEmojis[agent.projectDir] ?? "📁"
        }
        return "📁"
    }

    var body: some View {
        VStack(spacing: 0) {
            // 프로젝트 헤더
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 10)

                    Text(projectEmoji)
                        .font(.system(size: 14))
                        .onTapGesture {
                            if let agent = sessions.first {
                                onProjectEmojiTap(agent)
                            }
                        }
                        .help(store.t("프로젝트 이모지 변경", "Change project emoji"))

                    Text(projectName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    Text("(\(sessions.count))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Spacer()

                    if activeCount > 0 {
                        Text("\(activeCount) \(store.t("활성", "active"))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(sessions) { agent in
                    AgentRowView(agent: agent, store: store, onEmojiTap: {
                        onSessionEmojiTap(agent)
                    })
                }
            }
        }
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
