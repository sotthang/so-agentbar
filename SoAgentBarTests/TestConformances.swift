@testable import SoAgentBar

// Bridge test-local fake types to the main-module protocols.
// The Fake types already implement all required methods; these extensions
// add explicit conformance to SoAgentBar's protocol types so they can be
// passed to KeepAwakeManager.init and ClipboardMonitor.init.

extension FakePowerAssertionProvider: SoAgentBar.PowerAssertionProvider {}

extension FakePasteboardProvider: SoAgentBar.PasteboardProviding {}
