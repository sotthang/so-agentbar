import Foundation
import AppKit
import Combine

// MARK: - PasteboardProviding

protocol PasteboardProviding {
    var changeCount: Int { get }
    func string() -> String?
    func write(_ text: String)
    func isConcealedType() -> Bool
}

// MARK: - Real NSPasteboard implementation

final class NSPasteboardProvider: PasteboardProviding {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    func string() -> String? {
        pasteboard.string(forType: .string)
    }

    func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
    }

    func isConcealedType() -> Bool {
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        return pasteboard.types?.contains(concealedType) ?? false
    }
}

// MARK: - ClipboardMonitor

@MainActor
final class ClipboardMonitor: ObservableObject {
    @Published private(set) var history: [ClipboardEntry] = []

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? start() : stop()
        }
    }

    static let maxEntries = 20
    static let maxEntryLength = 100_000  // 100KB per entry
    static let pollInterval: TimeInterval = 1.0

    private let pasteboardProvider: PasteboardProviding
    private let defaults: UserDefaults

    private enum Keys {
        static let enabled = "clipboardHistoryEnabled"
        static let history = "clipboardHistory"
    }

    private var pollTimer: Timer?
    private var lastChangeCount: Int
    private var ignoreNextChangeCount: Int? = nil

    init(
        pasteboardProvider: PasteboardProviding? = nil,
        defaults: UserDefaults = .standard
    ) {
        let provider = pasteboardProvider ?? NSPasteboardProvider()
        self.pasteboardProvider = provider
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        self.lastChangeCount = provider.changeCount
        loadHistory()
        if self.isEnabled {
            start()
        }
    }

    func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func copy(_ entry: ClipboardEntry) {
        pasteboardProvider.write(entry.text)
        ignoreNextChangeCount = pasteboardProvider.changeCount
        lastChangeCount = pasteboardProvider.changeCount
        // Move entry to front without re-ingesting
        history.removeAll { $0.text == entry.text }
        history.insert(entry, at: 0)
        persist()
    }

    func clearAll() {
        history = []
        persist()
    }

    func remove(_ entry: ClipboardEntry) {
        history.removeAll { $0.id == entry.id }
        persist()
    }

    // MARK: - Internal (exposed for tests)

    func ingest(text: String) {
        guard !text.isEmpty else { return }
        let trimmed = text.count > Self.maxEntryLength ? String(text.prefix(Self.maxEntryLength)) : text
        history.removeAll { $0.text == trimmed }
        history.insert(ClipboardEntry(text: trimmed), at: 0)
        if history.count > Self.maxEntries {
            history.removeLast(history.count - Self.maxEntries)
        }
        persist()
    }

    // MARK: - Private

    private func tick() {
        let current = pasteboardProvider.changeCount
        guard current != lastChangeCount else { return }

        // Check if we should ignore this change (self-write)
        if let ignoreCount = ignoreNextChangeCount, ignoreCount == current {
            lastChangeCount = current
            ignoreNextChangeCount = nil
            return
        }

        lastChangeCount = current
        ignoreNextChangeCount = nil

        guard !pasteboardProvider.isConcealedType() else { return }

        if let text = pasteboardProvider.string(), !text.isEmpty {
            ingest(text: text)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Keys.history)
        }
    }

    private func loadHistory() {
        guard let data = defaults.data(forKey: Keys.history),
              let entries = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else {
            return
        }
        history = entries
    }
}
