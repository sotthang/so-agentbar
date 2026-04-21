import Foundation
import Combine

@MainActor
final class QuickNoteStore: ObservableObject {
    @Published var content: String

    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    private enum Keys {
        static let content = "quickNoteContent"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.content = defaults.string(forKey: Keys.content) ?? ""
        bindAutosave()
    }

    /// Called on applicationWillTerminate so the final unflushed buffer is saved.
    func flush() {
        defaults.set(content, forKey: Keys.content)
    }

    private func bindAutosave() {
        $content
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                self.defaults.set(text, forKey: Keys.content)
            }
            .store(in: &cancellables)
    }
}
