import AppKit
import SaylarkCore
import SaylarkUI

/// Starts the menu bar app. The live engine comes from `LiveEngine.make()`; `--fake-engine` swaps in
/// the fake (replayed voices, sample takes, fixed permissions) so the whole app runs with no mic,
/// no Fn hook and no permission prompts.
@MainActor enum SaylarkMain {
    private static var controller: AppController?

    static func run(fake: Bool, envelopeDir: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let settings = AppSettings()
        if fake {
            let engine = FakeEngine(envelopes: Array(EnvelopeStore.load(from: envelopeDir).values).sorted { $0.id < $1.id })
            // A sample dictionary in a temp folder: the fake app never touches the real one.
            controller = AppController(engine: engine, settings: settings, permissions: FakePermissions(), loginItem: .fake(), isFake: true,
                                       dictionaryURL: SampleDictionary.write())
        } else if let engine = LiveEngine.make() {
            controller = AppController(engine: engine, settings: settings, permissions: EnginePermissionsProvider())
        } else {
            print("The live engine isn't wired in yet. Run with --fake-engine.")
            exit(1)
        }
        controller?.launch()
        app.run()
    }
}
