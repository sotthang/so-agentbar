import SwiftUI
import ServiceManagement
import Sparkle

struct SettingsView: View {
    @ObservedObject var store: AgentStore
    let updater: SPUUpdater
    @Binding var isPresented: Bool
    @State private var thresholdValue: Double = 80

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

                Text(store.t("설정", "Settings"))
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // 언어 섹션
                    sectionHeader(store.t("언어", "Language"))

                    settingRow {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: $store.language) {
                                ForEach(AppLanguage.allCases, id: \.self) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }

                    // 메뉴바 섹션
                    sectionHeader(store.t("메뉴바", "Menu Bar"))

                    settingRow {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.t("표시 스타일", "Display style"))
                                .font(.system(size: 13))
                            HStack(spacing: 8) {
                                ForEach([
                                    (MenubarStyle.emoji,      "🤖🤔😴"),
                                    (MenubarStyle.emojiCount, "🤖 3"),
                                ], id: \.0.rawValue) { style, label in
                                    Button(action: { store.menubarStyle = style }) {
                                        Text(label)
                                            .font(.system(size: 13))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(
                                                store.menubarStyle == style
                                                    ? Color.accentColor
                                                    : Color(NSColor.controlBackgroundColor)
                                            )
                                            .foregroundColor(
                                                store.menubarStyle == style ? .white : .primary
                                            )
                                            .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    Divider().padding(.leading, 16)

                    // 에디터 섹션
                    sectionHeader(store.t("프로젝트 열기", "Open Project"))

                    settingRow {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.t("CLI 세션 에디터", "CLI session editor"))
                                .font(.system(size: 13))
                            Text(store.t("터미널에서 실행한 세션 클릭 시 사용할 앱\nXcode 세션은 자동으로 Xcode로 열립니다",
                                         "App for sessions started from terminal\nXcode sessions automatically open in Xcode"))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Picker("", selection: $store.openWith) {
                                ForEach(OpenWith.allCases, id: \.self) { opt in
                                    Text(opt.displayName).tag(opt)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }

                    Divider().padding(.leading, 16)

                    // 알림 섹션
                    sectionHeader(store.t("알림", "Notifications"))

                    settingRow {
                        Toggle(isOn: $store.notifyOnComplete) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.t("작업 완료 알림", "Notify on task complete"))
                                    .font(.system(size: 13))
                                Text(store.t("에이전트가 응답을 멈췄을 때 알림", "When agent stops responding"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }

                    Divider().padding(.leading, 16)

                    settingRow {
                        Toggle(isOn: $store.notifyOnError) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.t("에러 알림", "Notify on error"))
                                    .font(.system(size: 13))
                                Text(store.t("에이전트 에러 발생 시 알림", "When agent encounters an error"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }

                    Divider().padding(.leading, 16)

                    // 쿼터 임계값 알림
                    settingRow {
                        Toggle(isOn: $store.notifyOnQuotaThreshold) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.t("쿼터 임계값 알림", "Quota threshold alert"))
                                    .font(.system(size: 13))
                                Text(store.t("세션 쿼터가 설정값 초과 시 1회 알림", "Notify once when session quota exceeds threshold"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }

                    if store.notifyOnQuotaThreshold {
                        Divider().padding(.leading, 16)

                        settingRow {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(store.t("임계값", "Threshold"))
                                        .font(.system(size: 13))
                                    Spacer()
                                    Text("\(Int(store.sessionAlertThreshold))%")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Slider(value: $thresholdValue, in: 50...95, step: 5)
                                    .onAppear { thresholdValue = store.sessionAlertThreshold }
                                    .onChange(of: thresholdValue) { _, v in store.sessionAlertThreshold = v }
                            }
                        }

                        Divider().padding(.leading, 16)

                        settingRow {
                            Toggle(isOn: $store.notifyOnQuotaReset) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(store.t("쿼터 충전 알림", "Quota refill alert"))
                                        .font(.system(size: 13))
                                    Text(store.t("쿼터 충전 시 알림", "Notify when quota resets"))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                        }
                    }

                    // 핫키 섹션
                    sectionHeader(store.t("글로벌 핫키", "Global Hotkey"))

                    settingRow {
                        Toggle(isOn: $store.hotkeyEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.t("핫키 활성화", "Enable hotkey"))
                                    .font(.system(size: 13))
                                Text(store.t("어디서든 팝오버를 열고 닫을 수 있습니다", "Toggle popover from anywhere"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }

                    if store.hotkeyEnabled {
                        Divider().padding(.leading, 16)

                        settingRow {
                            HStack {
                                Text(store.t("단축키", "Shortcut"))
                                    .font(.system(size: 13))
                                Spacer()
                                HotkeyRecorderButton(store: store)
                            }
                        }
                    }

                    Divider().padding(.leading, 16)

                    // 세션 섹션
                    sectionHeader(store.t("세션", "Sessions"))

                    settingRow {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.t("목록 스타일", "List style"))
                                .font(.system(size: 13))
                            Picker("", selection: $store.listStyle) {
                                Text(store.t("플랫", "Flat")).tag(ListStyle.flat)
                                Text(store.t("그룹", "Grouped")).tag(ListStyle.grouped)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }

                    Divider().padding(.leading, 16)

                    settingRow {
                        Toggle(isOn: $store.showIdleSessions) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.t("비활성 세션 표시", "Show idle sessions"))
                                    .font(.system(size: 13))
                                Text(store.t("5분 이상 응답 없는 세션도 목록에 표시", "Also show sessions with no response for 5+ minutes"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }

                    Divider().padding(.leading, 16)

                    settingRow {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.t("폴백 폴링 간격", "Fallback poll interval"))
                                .font(.system(size: 13))
                            Text(store.t("파일 변경은 실시간 감지됩니다. 이 간격은 안전장치용입니다",
                                         "File changes are detected in real-time. This interval is a safety fallback"))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Picker("", selection: $store.pollInterval) {
                                Text(store.t("10초", "10s")).tag(10.0)
                                Text(store.t("30초", "30s")).tag(30.0)
                                Text(store.t("60초", "60s")).tag(60.0)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }

                    // 앱 섹션
                    sectionHeader(store.t("앱", "App"))

                    settingRow {
                        LaunchAtLoginRow(store: store)
                    }

                    Divider().padding(.leading, 16)

                    settingRow {
                        UpdateRow(updater: updater, store: store)
                    }

                    // 정보 섹션
                    sectionHeader(store.t("정보", "About"))

                    settingRow {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("so-agentbar")
                                    .font(.system(size: 13))
                                Text(store.t("Claude Code 세션 모니터", "Claude Code session monitor"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider().padding(.leading, 16)

                    settingRow {
                        HStack(spacing: 12) {
                            Button(action: {
                                NSWorkspace.shared.open(URL(string: "https://github.com/sotthang/so-agentbar")!)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 12))
                                    Text("GitHub")
                                        .font(.system(size: 13))
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)

                            Button(action: {
                                NSWorkspace.shared.open(URL(string: "https://github.com/sotthang/so-agentbar/issues/new")!)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "ladybug")
                                        .font(.system(size: 12))
                                    Text(store.t("버그 신고", "Report Bug"))
                                        .font(.system(size: 13))
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.orange)

                            Spacer()
                        }
                    }
                }
            }

            Divider()

            // 푸터
            HStack {
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
        .frame(width: 360)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 헬퍼 뷰

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private func settingRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }
}

// MARK: - 로그인 시 자동 시작

// MARK: - 핫키 레코더

struct HotkeyRecorderButton: View {
    @ObservedObject var store: AgentStore
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: { toggleRecording() }) {
            Text(isRecording
                 ? store.t("키를 누르세요…", "Press shortcut…")
                 : store.hotkeyDisplayString)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(isRecording ? .accentColor : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isRecording
                              ? Color.accentColor.opacity(0.15)
                              : Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRecording ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Escape = 취소
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            // 최소 1개 modifier 필요 (Cmd, Opt, Ctrl 중 하나)
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
                return nil
            }

            store.hotkeyKeyCode = Int(event.keyCode)
            store.hotkeyModifiers = AgentStore.nsModifiersToCarbonModifiers(flags)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

// MARK: - 로그인 시 자동 시작

struct LaunchAtLoginRow: View {
    @ObservedObject var store: AgentStore
    @State private var isEnabled: Bool = false

    var body: some View {
        Toggle(isOn: $isEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.t("로그인 시 자동 시작", "Launch at login"))
                    .font(.system(size: 13))
                Text(store.t("Mac 시작 시 so-agentbar를 자동으로 실행", "Automatically launch so-agentbar when Mac starts"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .toggleStyle(.switch)
        .onAppear {
            if #available(macOS 13.0, *) {
                isEnabled = SMAppService.mainApp.status == .enabled
            }
        }
        .onChange(of: isEnabled) { _, newValue in
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    let prev = !newValue
                    DispatchQueue.main.async { isEnabled = prev }
                }
            }
        }
    }
}

// MARK: - 업데이트

struct UpdateRow: View {
    let updater: SPUUpdater
    @ObservedObject var store: AgentStore
    @State private var automaticallyChecks: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $automaticallyChecks) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.t("자동 업데이트 확인", "Check for updates automatically"))
                        .font(.system(size: 13))
                }
            }
            .toggleStyle(.switch)
            .onAppear { automaticallyChecks = updater.automaticallyChecksForUpdates }
            .onChange(of: automaticallyChecks) { _, v in updater.automaticallyChecksForUpdates = v }

            Button(action: { updater.checkForUpdates() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                    Text(store.t("업데이트 확인", "Check for Updates"))
                        .font(.system(size: 13))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
    }
}
