import SpriteKit
import AppKit

// MARK: - PixelCharacterProvider Protocol

/// Abstracts character texture generation.
protocol PixelCharacterProvider {
    /// Returns animation frame textures for the given status.
    func textures(for status: AgentStatus, agentID: String, size: Int) -> [SKTexture]

    /// Returns walking animation textures for a given sprite row.
    /// row 0 = front (down), row 1 = side (left/right), row 2 = back (up)
    func walkTextures(row: Int, agentID: String, size: Int) -> [SKTexture]

    /// Returns speech bubble texture for waitingApproval.
    func bubbleTexture(size: Int) -> SKTexture

    /// Clears all texture caches so the next call regenerates textures.
    /// Call after characterOverrides changes to avoid stale textures.
    func invalidateCache()

    /// Number of entries currently held in the texture cache (for testing).
    var cacheSize: Int { get }
}

// MARK: - SpriteSheetPixelProvider

/// Uses pixel-agents PNG sprite sheets for character rendering.
final class SpriteSheetPixelProvider: PixelCharacterProvider {

    var characterOverrides: [String: Int] = [:]

    // Sprite sheet constants — PIPOYA RPG Maker MV format
    // 3 cols × 4 rows, frames 32x32, rows = down/left/right/up
    private static let sheetWidth: CGFloat = 96
    private static let sheetHeight: CGFloat = 128
    private static let frameWidth: CGFloat = 32
    private static let frameHeight: CGFloat = 32
    private static let framesPerRow: Int = 3

    // Row indices for walk directions (RPG Maker MV convention)
    static let rowDown: Int = 0
    static let rowLeft: Int = 1
    static let rowRight: Int = 2
    static let rowUp: Int = 3

    // Number of character variants (internal so AgentStore can reference it)
    internal static let charCount: Int = 40

    // MARK: - Caches

    /// Key: "\(status)-\(agentID)-\(size)"
    private var cache: [String: [SKTexture]] = [:]

    /// Key: "\(charIndex)-\(row)"  (walk textures, size-independent)
    private var walkCache: [String: [SKTexture]] = [:]

    /// Key: charName — reuse the sheet SKTexture object
    private static var sheetCache: [String: SKTexture] = [:]

    /// Cached tint results: key is the base texture's description + color hex
    private var tintCache: [String: SKTexture] = [:]

    // MARK: - PixelCharacterProvider

    func invalidateCache() {
        cache = [:]
        walkCache = [:]
        tintCache = [:]
    }

    var cacheSize: Int { cache.count }

    func textures(for status: AgentStatus, agentID: String, size: Int) -> [SKTexture] {
        let key = "\(status)-\(agentID)-\(size)"
        if let cached = cache[key] { return cached }

        let charIndex = characterOverrides[agentID] ?? Self.charIndex(for: agentID)
        let charName = "char_\(charIndex)"
        let sheet = Self.cachedSheet(named: charName)

        let result: [SKTexture]
        switch status {
        case .idle, .thinking:
            // row 0 (down), middle frame — static idle pose
            result = [Self.frameTexture(sheet: sheet, row: 0, col: 1)]

        case .working:
            // row 0 (down), all 3 frames — stepping animation
            result = (0..<3).map { col in
                Self.frameTexture(sheet: sheet, row: 0, col: col)
            }

        case .waitingApproval:
            // row 0 (down), all 3 frames — subtle bob
            result = (0..<3).map { col in
                Self.frameTexture(sheet: sheet, row: 0, col: col)
            }

        case .error:
            // row 0 (down), middle frame with red tint
            let base = Self.frameTexture(sheet: sheet, row: 0, col: 1)
            let tintKey = "\(charIndex)-error"
            let tinted: SKTexture
            if let t = tintCache[tintKey] {
                tinted = t
            } else {
                tinted = Self.tintTexture(base, color: NSColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.5))
                tintCache[tintKey] = tinted
            }
            result = [base, tinted]
        }

        cache[key] = result
        return result
    }

    func walkTextures(row: Int, agentID: String, size: Int) -> [SKTexture] {
        let charIndex = characterOverrides[agentID] ?? Self.charIndex(for: agentID)
        let key = "\(charIndex)-\(row)"
        if let cached = walkCache[key] { return cached }

        let sheet = Self.cachedSheet(named: "char_\(charIndex)")
        let result = (0..<Self.framesPerRow).map { col in
            Self.frameTexture(sheet: sheet, row: row, col: col)
        }
        walkCache[key] = result
        return result
    }

    func bubbleTexture(size: Int) -> SKTexture {
        // Reuse programmatic bubble (simple "!" circle)
        return ProgrammaticPixelProvider().bubbleTexture(size: size)
    }

    // MARK: - Private helpers

    private static func cachedSheet(named name: String) -> SKTexture {
        if let t = sheetCache[name] { return t }
        let t = SKTexture(imageNamed: name)
        t.filteringMode = .nearest
        sheetCache[name] = t
        return t
    }

    /// Deterministic character index [0, 6) from agent ID string.
    /// Uses a different hash multiplier than hue() to avoid clustering.
    static func charIndex(for agentID: String) -> Int {
        var hash: UInt32 = 2166136261
        for byte in agentID.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        // XOR fold upper/lower 16 bits for better spread
        let folded = (hash ^ (hash >> 16)) & 0xFFFF
        return Int(folded) % charCount
    }

    /// Deterministic character index [0, charCount) from hue (legacy).
    private static func charIndex(for hue: CGFloat) -> Int {
        Int(hue * 997) % charCount
    }

    /// Extracts a single frame from the sprite sheet.
    /// SpriteKit texture rects use bottom-left origin, so we flip the row.
    private static func frameTexture(sheet: SKTexture, row: Int, col: Int) -> SKTexture {
        let u = CGFloat(col) * frameWidth / sheetWidth
        // Row 0 = top of image → in bottom-up coords: y = (sheetHeight - frameHeight) / sheetHeight
        let v = (sheetHeight - CGFloat(row + 1) * frameHeight) / sheetHeight
        let w = frameWidth / sheetWidth
        let h = frameHeight / sheetHeight
        let rect = CGRect(x: u, y: v, width: w, height: h)
        let t = SKTexture(rect: rect, in: sheet)
        t.filteringMode = .nearest
        return t
    }

    /// Returns a red-tinted copy of the texture.
    private static func tintTexture(_ texture: SKTexture, color: NSColor) -> SKTexture {
        let size = texture.size()
        let w = Int(size.width > 0 ? size.width : 16)
        let h = Int(size.height > 0 ? size.height : 32)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return texture }

        // Draw original
        ctx.draw(texture.cgImage(), in: CGRect(x: 0, y: 0, width: w, height: h))
        // Overlay tint
        ctx.setFillColor(color.cgColor)
        ctx.setBlendMode(.sourceAtop)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        guard let result = ctx.makeImage() else { return texture }
        let t = SKTexture(cgImage: result)
        t.filteringMode = .nearest
        return t
    }
}

// MARK: - ProgrammaticPixelProvider

/// Generates pixel art via CGContext — no PNG assets required.
final class ProgrammaticPixelProvider: PixelCharacterProvider {

    private var cache: [String: [SKTexture]] = [:]

    // MARK: - PixelCharacterProvider

    func invalidateCache() {
        cache = [:]
    }

    var cacheSize: Int { cache.count }

    /// Convenience overload for tests that supply a hue directly.
    func textures(for status: AgentStatus, hue: CGFloat, size: Int) -> [SKTexture] {
        let key = "\(status)-\(hue)-\(size)"
        if let cached = cache[key] { return cached }

        let color = NSColor(hue: hue, saturation: 0.7, brightness: 0.85, alpha: 1.0)
        let darkColor = NSColor(hue: hue, saturation: 0.8, brightness: 0.5, alpha: 1.0)

        let frames: [SKTexture]
        switch status {
        case .idle, .thinking:
            frames = [
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 0),
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: -1)
            ]
        case .working:
            frames = [
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 0, armsUp: false),
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 0, armsUp: true)
            ]
        case .waitingApproval:
            frames = [
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 0),
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 2),
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 4),
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 2)
            ]
        case .error:
            let errorColor = NSColor(hue: 0.0, saturation: 0.9, brightness: 0.8, alpha: 1.0)
            let errorDark = NSColor(hue: 0.0, saturation: 1.0, brightness: 0.5, alpha: 1.0)
            frames = [
                renderCharacter(color: errorColor, darkColor: errorDark, size: size, offsetY: 0),
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 0)
            ]
        }

        cache[key] = frames
        return frames
    }

    func textures(for status: AgentStatus, agentID: String, size: Int) -> [SKTexture] {
        let hue = ProgrammaticPixelProvider.hue(for: agentID)
        let key = "\(status)-\(hue)-\(size)"
        if let cached = cache[key] { return cached }

        let color = NSColor(hue: hue, saturation: 0.7, brightness: 0.85, alpha: 1.0)
        let darkColor = NSColor(hue: hue, saturation: 0.8, brightness: 0.5, alpha: 1.0)

        let frames: [SKTexture]
        switch status {
        case .idle, .thinking:
            // Two-frame gentle bob
            frames = [
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 0),
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: -1)
            ]
        case .working:
            // Typing animation: arms move
            frames = [
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 0, armsUp: false),
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 0, armsUp: true)
            ]
        case .waitingApproval:
            // Jump animation
            frames = [
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 0),
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 2),
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 4),
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 2)
            ]
        case .error:
            // Red blink
            let errorColor = NSColor(hue: 0.0, saturation: 0.9, brightness: 0.8, alpha: 1.0)
            let errorDark = NSColor(hue: 0.0, saturation: 1.0, brightness: 0.5, alpha: 1.0)
            frames = [
                renderCharacter(color: errorColor, darkColor: errorDark, size: size, offsetY: 0),
                renderCharacter(color: color, darkColor: darkColor, size: size, offsetY: 0)
            ]
        }

        cache[key] = frames
        return frames
    }

    func walkTextures(row: Int, agentID: String, size: Int) -> [SKTexture] {
        return textures(for: .working, agentID: agentID, size: size)
    }

    func bubbleTexture(size: Int) -> SKTexture {
        let bubbleSize = max(size / 2, 12)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: bubbleSize,
            height: bubbleSize,
            bitsPerComponent: 8,
            bytesPerRow: bubbleSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return SKTexture()
        }

        // White circle bubble
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: 1, y: 1, width: bubbleSize - 2, height: bubbleSize - 2))

        // "!" text
        ctx.setFillColor(NSColor.red.cgColor)
        let barW = max(bubbleSize / 6, 2)
        let barH = max(bubbleSize / 3, 4)
        let dotSize = max(bubbleSize / 8, 2)
        let cx = bubbleSize / 2 - barW / 2
        ctx.fill(CGRect(x: cx, y: bubbleSize / 2 + 1, width: barW, height: barH))
        ctx.fill(CGRect(x: cx, y: bubbleSize / 2 - dotSize - 1, width: dotSize, height: dotSize))

        guard let img = ctx.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: img)
    }

    // MARK: - Static helpers

    /// Deterministic hue in [0, 1] based on agent ID hash.
    static func hue(for agentID: String) -> CGFloat {
        var hash: UInt32 = 2166136261
        for byte in agentID.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        return CGFloat(hash % 1000) / 1000.0
    }

    // MARK: - Private rendering

    private func renderCharacter(
        color: NSColor,
        darkColor: NSColor,
        size: Int,
        offsetY: Int,
        armsUp: Bool = false
    ) -> SKTexture {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return SKTexture()
        }

        let s = CGFloat(size)
        let oy = CGFloat(offsetY)

        // Body (torso)
        ctx.setFillColor(color.cgColor)
        let bodyX = s * 0.25
        let bodyY = s * 0.25 + oy
        let bodyW = s * 0.5
        let bodyH = s * 0.35
        ctx.fill(CGRect(x: bodyX, y: bodyY, width: bodyW, height: bodyH))

        // Head
        let headX = s * 0.3
        let headY = bodyY + bodyH
        let headW = s * 0.4
        let headH = s * 0.28
        ctx.fill(CGRect(x: headX, y: headY, width: headW, height: headH))

        // Eyes
        ctx.setFillColor(darkColor.cgColor)
        let eyeY = headY + headH * 0.55
        ctx.fill(CGRect(x: headX + headW * 0.2, y: eyeY, width: s * 0.07, height: s * 0.07))
        ctx.fill(CGRect(x: headX + headW * 0.65, y: eyeY, width: s * 0.07, height: s * 0.07))

        // Arms
        ctx.setFillColor(color.cgColor)
        let armW = s * 0.12
        let armH = s * 0.25
        let armY = armsUp
            ? bodyY + bodyH * 0.5
            : bodyY + bodyH * 0.1
        // Left arm
        ctx.fill(CGRect(x: bodyX - armW, y: armY, width: armW, height: armH))
        // Right arm
        ctx.fill(CGRect(x: bodyX + bodyW, y: armY, width: armW, height: armH))

        // Legs
        let legW = s * 0.15
        let legH = s * 0.2
        let legY = bodyY - legH
        ctx.fill(CGRect(x: bodyX + bodyW * 0.1, y: legY, width: legW, height: legH))
        ctx.fill(CGRect(x: bodyX + bodyW * 0.6, y: legY, width: legW, height: legH))

        guard let img = ctx.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: img)
    }
}
