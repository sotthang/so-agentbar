import SwiftUI
import SpriteKit

// MARK: - CharacterPickerView

struct CharacterPickerView: View {
    let agentID: String
    @ObservedObject var store: AgentStore
    @Environment(\.dismiss) private var dismiss

    private let charCount = 6

    var selectedIndex: Int {
        store.pixelCharacterOverrides[agentID]
            ?? SpriteSheetPixelProvider.charIndex(for: agentID)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(store.t("캐릭터 선택", "Choose Character"))
                .font(.system(size: 13, weight: .medium))

            HStack(spacing: 8) {
                ForEach(0..<charCount, id: \.self) { index in
                    CharacterPreviewCell(
                        charIndex: index,
                        isSelected: selectedIndex == index
                    )
                    .onTapGesture {
                        store.pixelCharacterOverrides[agentID] = index
                        dismiss()
                    }
                }
            }

            if store.pixelCharacterOverrides[agentID] != nil {
                Button(store.t("기본값으로 초기화", "Reset to default")) {
                    store.pixelCharacterOverrides.removeValue(forKey: agentID)
                    dismiss()
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .buttonStyle(.plain)
            }
        }
        .padding(16)
    }
}

// MARK: - CharacterPreviewCell

struct CharacterPreviewCell: View {
    let charIndex: Int
    let isSelected: Bool

    var body: some View {
        SpriteKitCharacterPreview(charIndex: charIndex)
            .frame(width: 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color(NSColor.quaternaryLabelColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
    }
}

// MARK: - SpriteKitCharacterPreview

/// NSImage 기반 캐릭터 프리뷰 (스프라이트시트 첫 프레임 추출)
struct SpriteKitCharacterPreview: NSViewRepresentable {
    let charIndex: Int

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = extractCharacterImage(charIndex: charIndex)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = extractCharacterImage(charIndex: charIndex)
    }

    private func extractCharacterImage(charIndex: Int) -> NSImage? {
        guard let image = NSImage(named: "char_\(charIndex)") else { return nil }

        // 스프라이트시트에서 row=0, col=0 프레임 추출 (16×32px)
        let sheetW = image.size.width
        let sheetH = image.size.height
        let frameW: CGFloat = 16
        let frameH: CGFloat = 32

        // row=0, col=0 → top-left
        let srcRect = NSRect(x: 0, y: sheetH - frameH, width: frameW, height: frameH)
        let destSize = NSSize(width: frameW, height: frameH)

        let result = NSImage(size: destSize)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: destSize),
                   from: srcRect,
                   operation: .copy,
                   fraction: 1.0)
        result.unlockFocus()

        return result
    }
}
