import SwiftUI
import AppKit

struct ClipboardHistoryView: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var monitor: ClipboardMonitor
    var onOpenSettings: () -> Void = {}
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            historyHeader
            Divider()
            if !monitor.isEnabled {
                disabledState
            } else if monitor.history.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
    }

    private var historyHeader: some View {
        HStack {
            Text(store.t("클립보드 히스토리", "Clipboard History"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            if !monitor.history.isEmpty {
                Button(action: { showClearConfirmation = true }) {
                    Text(store.t("전체 삭제", "Clear All"))
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .alert(store.t("전체 삭제", "Clear All"), isPresented: $showClearConfirmation) {
                    Button(store.t("삭제", "Delete"), role: .destructive) {
                        monitor.clearAll()
                    }
                    Button(store.t("취소", "Cancel"), role: .cancel) {}
                } message: {
                    Text(store.t("모든 클립보드 히스토리를 삭제할까요?", "Delete all clipboard history?"))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(store.t("복사한 텍스트가 여기에 표시됩니다", "Copied text will appear here"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 32)
    }

    private var disabledState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            VStack(spacing: 4) {
                Text(store.t("클립보드 히스토리가 꺼져 있습니다", "Clipboard history is off"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Text(store.t("기능을 켜야 복사한 텍스트가 여기에 저장됩니다", "Turn it on to save copied text here"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                Button(action: { monitor.isEnabled = true }) {
                    Text(store.t("켜기", "Enable"))
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(action: onOpenSettings) {
                    Text(store.t("설정 열기", "Open Settings"))
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(monitor.history) { entry in
                    ClipboardRowView(
                        entry: entry,
                        store: store,
                        onTap: { monitor.copy(entry) },
                        onDelete: { monitor.remove(entry) }
                    )
                    Divider().padding(.leading, 16)
                }
            }
        }
        .frame(maxHeight: 350)
    }
}

private struct ClipboardRowView: View {
    let entry: ClipboardEntry
    @ObservedObject var store: AgentStore
    var onTap: () -> Void
    var onDelete: () -> Void
    @State private var isHovering = false
    @State private var copiedFlash = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundColor(.primary)
                Text(store.relativeTime(entry.copiedAt))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if copiedFlash {
                Text(store.t("복사됨", "Copied"))
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)
            } else if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            isHovering
                ? Color(NSColor.selectedContentBackgroundColor).opacity(0.1)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            onTap()
            copiedFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copiedFlash = false
            }
        }
    }
}
