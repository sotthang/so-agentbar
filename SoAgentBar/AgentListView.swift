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
            store.selectedTab = .agents
        }
    }

    private var mainView: some View {
        VStack(spacing: 0) {
            header
            Divider()
            PopoverTabSwitcher(store: store)
            Divider()

            switch store.selectedTab {
            case .agents:
                agentsTab
            case .clipboard:
                ClipboardHistoryView(store: store, monitor: store.clipboardMonitor)
            case .note:
                QuickNoteView(store: store, noteStore: store.quickNoteStore)
            }

            Divider()
            footer
        }
    }

    private var agentsTab: some View {
        VStack(spacing: 0) {
            agentList
            UsageView(monitor: store.usageMonitor, store: store)
            SystemMetricsView(monitor: store.systemMetricsMonitor, store: store)
        }
    }

    private var header: some View {
        HStack {
            if let img = NSImage(named: "logo") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
            }
            Text("so-agentbar")
                .font(.headline)
                .fontWeight(.semibold)
            Spacer()
            let activeCount = store.agents.filter { $0.status == .working || $0.status == .thinking }.count
            Text("\(activeCount) \(store.t("활성", "active"))")
                .font(.caption)
                .foregroundColor(.secondary)
            Button(action: { store.keepAwakeManager.mode = store.keepAwakeManager.mode.next }) {
                Image(systemName: keepAwakeSymbol)
                    .font(.system(size: 13))
                    .foregroundColor(keepAwakeColor)
            }
            .buttonStyle(.plain)
            .help(keepAwakeTooltip)
            Button(action: { store.isPixelWindowVisible.toggle() }) {
                Image(systemName: store.isPixelWindowVisible ? "person.3.fill" : "person.3")
                    .font(.system(size: 13))
                    .foregroundColor(store.isPixelWindowVisible ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(store.t("픽셀 에이전트 윈도우", "Pixel Agents Window"))
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

    private var keepAwakeSymbol: String {
        switch store.keepAwakeManager.mode {
        case .off:    return "cup.and.saucer"
        case .always: return "cup.and.saucer.fill"
        case .auto:   return "moon.zzz.fill"
        }
    }

    private var keepAwakeColor: Color {
        switch store.keepAwakeManager.mode {
        case .off:    return .secondary
        case .always: return .accentColor
        case .auto:   return .orange
        }
    }

    private var keepAwakeTooltip: String {
        switch store.keepAwakeManager.mode {
        case .off:    return store.t("잠자기 방지: 꺼짐", "Keep Awake: Off")
        case .always: return store.t("잠자기 방지: 항상 켜짐", "Keep Awake: Always On")
        case .auto:   return store.t("잠자기 방지: 세션 실행 중에만 켜짐", "Keep Awake: During Sessions Only")
        }
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
        // 그룹 내 active 세션 우선, 그 다음 최신 lastActivity 기준으로 프로젝트 정렬
        let sortedKeys = grouped.keys.sorted { a, b in
            let aActive = grouped[a]?.contains(where: { $0.status == .working || $0.status == .waitingApproval }) ?? false
            let bActive = grouped[b]?.contains(where: { $0.status == .working || $0.status == .waitingApproval }) ?? false
            if aActive != bActive { return aActive }
            let aDate = grouped[a]?.map(\.lastActivity).max() ?? .distantPast
            let bDate = grouped[b]?.map(\.lastActivity).max() ?? .distantPast
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
            Text(store.t("CLI + Xcode + Desktop 세션 감지 중", "Monitoring CLI + Xcode + Desktop sessions"))
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
    @State private var subagentsExpanded = false
    @State private var showCharacterPicker = false

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
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
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
                        if let badge = agent.sourceBadgeName {
                            let badgeColor = sourceBadgeColor(agent.source)
                            Text(badge)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(badgeColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(badgeColor.opacity(0.12))
                                .cornerRadius(3)
                        }
                        if agent.subagentCount > 0 {
                            Button(action: { subagentsExpanded.toggle() }) {
                                HStack(spacing: 2) {
                                    Image(systemName: subagentsExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 8, weight: .bold))
                                    Text("🤖×\(agent.subagentCount)")
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .foregroundColor(.purple)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.12))
                                .cornerRadius(3)
                            }
                            .buttonStyle(.plain)
                            .help(store.t("서브에이전트 펼치기/접기", "Expand/collapse subagents"))
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
                    HStack(spacing: 6) {
                        Button(action: { showCharacterPicker.toggle() }) {
                            Image(systemName: "person.crop.square")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(store.t("픽셀 캐릭터 선택", "Choose pixel character"))
                        .popover(isPresented: $showCharacterPicker, arrowEdge: .trailing) {
                            CharacterPickerView(agentID: agent.id, store: store)
                        }

                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else if let costStr = CostCalculator.formatCost(agent.estimatedCost) {
                    Text(costStr)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.quaternaryLabelColor))
                        .cornerRadius(4)
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
        .onHover { hovering in isHovering = hovering || showCharacterPicker }
        .onChange(of: showCharacterPicker) { open in if !open { isHovering = false } }
        .onTapGesture { store.openProject(agent.workingPath, source: agent.source) }

        // 서브에이전트 펼치기 영역
        if subagentsExpanded, !agent.subagents.isEmpty {
            VStack(spacing: 0) {
                ForEach(agent.subagents) { sub in
                    SubagentRowView(agent: sub, store: store)
                }
            }
            .padding(.leading, 46)
            .padding(.bottom, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
    }

    private func formatTokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }

    private func sourceBadgeColor(_ source: SessionSource) -> Color {
        switch source {
        case .cli:           return .secondary
        case .xcode:         return .blue
        case .desktopCode:   return .purple
        case .desktopCowork: return .orange
        }
    }
}

// MARK: - 서브에이전트 행 (펼치기 영역에서 사용)

struct SubagentRowView: View {
    let agent: Agent
    @ObservedObject var store: AgentStore
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                StatusDot(status: agent.status)
                Text(agent.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !agent.modelDisplayName.isEmpty {
                    Text(agent.modelDisplayName)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color(NSColor.quaternaryLabelColor))
                        .cornerRadius(2)
                }
                Spacer(minLength: 4)
                Text(agent.currentTask)
                    .font(.system(size: 10))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if agent.status == .working || agent.status == .waitingApproval {
                    Text(agent.elapsedDisplay)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(agent.status == .waitingApproval ? .orange : .secondary)
                }
            }

            // 호버 시 마지막 응답 미리보기
            if isHovering, !agent.lastResponse.isEmpty {
                Text(agent.lastResponse)
                    .font(.system(size: 10))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .padding(.leading, 14) // StatusDot + spacing 정렬
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(
            isHovering
                ? Color(NSColor.selectedContentBackgroundColor).opacity(0.08)
                : Color.clear
        )
        .onHover { isHovering = $0 }
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

    /// 그룹 내 고유 source 목록 (순서 고정)
    private var uniqueSources: [SessionSource] {
        let order: [SessionSource] = [.cli, .xcode, .desktopCode, .desktopCowork]
        let present = Set(sessions.map(\.source))
        return order.filter { present.contains($0) }
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
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text("(\(sessions.count))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    // source 아이콘 배지
                    ForEach(uniqueSources, id: \.self) { source in
                        sourceIcon(source)
                    }

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

    @ViewBuilder
    private func sourceIcon(_ source: SessionSource) -> some View {
        switch source {
        case .cli:
            Image(systemName: "terminal")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .help("Claude Code (CLI)")
        case .xcode:
            Image(systemName: "hammer")
                .font(.system(size: 9))
                .foregroundColor(.blue)
                .help("Xcode")
        case .desktopCode:
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 9))
                .foregroundColor(.purple)
                .help("Claude Desktop Code")
        case .desktopCowork:
            Image(systemName: "cloud")
                .font(.system(size: 9))
                .foregroundColor(.orange)
                .help("Claude Cowork")
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
