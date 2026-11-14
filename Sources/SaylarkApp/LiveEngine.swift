import Foundation
import SaylarkCore
import SaylarkEngine

/// The one place the app picks up the engine track's `DictationEngine`.
@MainActor enum LiveEngine {
    static func make() -> (any DictationEngine)? {
        // Listen-only Fn hook, real mic at Fn-down, history in Application Support, the real
        // clipboard and keys. Settings come from the standard UserDefaults.
        do {
            return try ShadowEngine(parts: .app(defaults: .standard))
        } catch {
            print("Saylark engine failed to open history: \(error)")
            return nil
        }
    }
}
