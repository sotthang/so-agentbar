import SwiftUI
import AppKit

struct QuickNoteView: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var noteStore: QuickNoteStore
    @State private var showCopiedToast = false

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $noteStore.content)
                .font(.system(size: 13))
                .padding(8)
                .frame(maxHeight: 340)
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack {
            Text(store.t("\(noteStore.content.count)자", "\(noteStore.content.count) chars"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            if showCopiedToast {
                Text(store.t("복사됨", "Copied!"))
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
            }
            Button(action: copyAll) {
                Text(store.t("전체 복사", "Copy All"))
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string], owner: nil)
        pb.setString(noteStore.content, forType: .string)
        showCopiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedToast = false
        }
    }
}
