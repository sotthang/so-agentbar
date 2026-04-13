import SwiftUI
import SpriteKit

// MARK: - SKViewRepresentable

/// Wraps SKView as NSViewRepresentable to enable `allowsTransparency` on the underlying SKView.
struct SKViewRepresentable: NSViewRepresentable {
    let scene: PixelAgentsScene

    func makeNSView(context: Context) -> SKView {
        let view = SKView()
        view.allowsTransparency = true
        view.preferredFramesPerSecond = 30
        view.presentScene(scene)
        return view
    }

    func updateNSView(_ nsView: SKView, context: Context) {
        // Scene lifecycle is managed externally via PixelAgentsScene.
    }
}
