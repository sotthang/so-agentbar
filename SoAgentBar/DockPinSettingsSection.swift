import SwiftUI

/// SPEC-004 R11.3/R11.4 — 설정 화면 "Dock 고정" 섹션 (디자인 계약 [A]–[D], arch §6.4).
/// 표시 값은 모두 `store.dockPinManager`의 @Published에서 읽고, 상태 문구·색·버튼은
/// `DockPinPolicy.presentation(for:usingFallbackAnchor:language:)` 결과만 그린다.
struct DockPinSettingsSection: View {
    @ObservedObject var store: AgentStore

    private var manager: DockPinManager { store.dockPinManager }
    private var language: AppLanguage { store.language }

    var body: some View {
        SettingsSectionHeader(title: DockPinText.sectionTitle(language))

        SettingsRow { enableToggle }

        if manager.isEnabled {
            Divider().padding(.leading, 16)
            SettingsRow { targetPicker }

            Divider().padding(.leading, 16)
            SettingsRow {
                DockPinStatusRow(
                    presentation: DockPinPolicy.presentation(for: manager.status,
                                                             usingFallbackAnchor: manager.usingFallbackAnchor,
                                                             language: language),
                    language: language,
                    onOpenPermissionSettings: { manager.openPermissionSettings() },
                    onMoveBackNow: { manager.moveBackNow() }
                )
            }

            Divider().padding(.leading, 16)
            SettingsRow { helpRows }
        }
    }

    // [A]
    private var enableToggle: some View {
        Toggle(isOn: Binding(get: { manager.isEnabled },
                             set: { manager.setEnabled($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DockPinText.toggleTitle(language))
                    .font(.system(size: 13))
                Text(DockPinText.toggleDescription(language))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }

    // [B]
    private var targetSelection: Binding<String> {
        Binding(
            get: { manager.targetChoices.first { $0.target == manager.target }?.id ?? DockPinTargetChoice.mainID },
            set: { id in
                guard let choice = manager.targetChoices.first(where: { $0.id == id }) else { return }
                manager.setTarget(choice.target, displayName: choice.displayNameToSave)
            }
        )
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DockPinText.pickerTitle(language))
                .font(.system(size: 13))
            Picker(DockPinText.pickerTitle(language), selection: targetSelection) {
                ForEach(manager.targetChoices) { choice in
                    Text(DockPinPolicy.choiceTitle(choice, language: language)).tag(choice.id)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .labelsHidden()
            .accessibilityLabel(DockPinText.pickerTitle(language))
        }
    }

    // [D]
    private var helpRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DockPinText.helpOption(language))
            Text(DockPinText.helpPermissionCaution(language))
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// [C]
private struct DockPinStatusRow: View {
    let presentation: DockPinPresentation
    let language: AppLanguage
    let onOpenPermissionSettings: () -> Void
    let onMoveBackNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(color(for: presentation.tone))
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.text)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = presentation.fallbackNote {
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)

            HStack(spacing: 8) {
                if presentation.showsOpenPermissionSettings {
                    Button(DockPinText.openPermissionSettings(language), action: onOpenPermissionSettings)
                }
                Spacer()
                Button(DockPinText.moveBackNow(language), action: onMoveBackNow)
                    .disabled(!presentation.moveBackEnabled)
            }
        }
    }

    private func color(for tone: DockPinTone) -> Color {
        switch tone {
        case .gray: return .secondary
        case .orange: return .orange
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        }
    }
}
