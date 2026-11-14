import AppKit
import Foundation
import Testing
@testable import SaylarkUI
import SaylarkCore
import SwiftUI

/// The small interaction rules from the UI audit: removing is undoable, deleting asks first, Back
/// stays where it was taken, defaults are listed first, ⌘F finds, and the accent reads on a window.
@MainActor @Suite struct InteractionPolishTests {
    private func dictionary(_ text: String) -> (DictionaryModel, URL) {
        let url = SampleDictionary.write(text)
        let m = DictionaryModel(url: url)
        m.load()
        return (m, url)
    }

    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    // MARK: Dictionary: remove is undoable

    @Test func undoPutsARemovedTermBackWhereItWas() throws {
        let text = "# mine\nCodex: codecs\n\n# people\nKalshi: Calci\nVercel\n"
        let (m, url) = dictionary(text)
        defer { cleanup(url) }
        let kalshi = try #require(m.entries.first { $0.term == "Kalshi" })
        m.remove(kalshi)
        #expect(m.removed?.entry == kalshi)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# mine\nCodex: codecs\n\n# people\nVercel\n")
        m.undoRemove()
        #expect(m.removed == nil)
        // Comments, blank lines and order all come back exactly.
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
        #expect(m.entries.map(\.term) == ["Codex", "Kalshi", "Vercel"])
    }

    @Test func undoAfterAnEditElsewhereAddsTheTermAgain() throws {
        let (m, url) = dictionary("Codex\nKalshi: Calci\n")
        defer { cleanup(url) }
        m.remove(try #require(m.entries.last))
        // Another editor changed the file meanwhile: its edit must survive the undo.
        try Data("Codex\nVercel\n".utf8).write(to: url, options: .atomic)
        m.undoRemove()
        #expect(m.entries.map(\.term) == ["Codex", "Vercel", "Kalshi"])
        #expect(m.entries.last?.aliases == ["Calci"])
    }

    @Test func theUndoOfferGoesAwayOnItsOwn() async throws {
        let (m, url) = dictionary("Codex\nKalshi\n")
        defer { cleanup(url) }
        m.undoWindow = .milliseconds(50)
        m.remove(try #require(m.entries.first))
        #expect(m.removed != nil)
        await until { m.removed == nil }
        #expect(m.removed == nil)
        // Nothing to undo any more: undo does nothing.
        m.undoRemove()
        #expect(m.entries.map(\.term) == ["Kalshi"])
    }

    // MARK: Home: delete asks first

    @Test func deletingATakeWaitsForConfirmation() async throws {
        let model = LibraryModel(history: FakeHistory(SampleTakes.history()))
        await model.load()
        let take = try #require(model.all.first)
        let count = model.all.count
        model.expanded = take.id
        model.requestDelete(take)
        #expect(model.pendingDelete?.id == take.id)
        #expect(model.all.count == count, "asking does not delete")
        model.pendingDelete = nil   // Cancel
        #expect(model.all.count == count)
        model.requestDelete(take)
        model.confirmDelete()
        #expect(model.pendingDelete == nil)
        #expect(model.all.count == count - 1 && !model.all.contains { $0.id == take.id })
        #expect(model.expanded == nil, "a deleted take's row is not left open")
    }

    // MARK: Onboarding: Back stays put

    @Test func backToAGrantedStepDoesNotBounceForward() async throws {
        let perms = FakePermissions([.microphone: .granted, .inputMonitoring: .notDetermined])
        let m = OnboardingModel(permissions: perms, step: .keyboard)
        m.back()
        #expect(m.step == .microphone && m.stepIsDone)
        // The view polls twice a second; the old model moved on 0.7 s after Back.
        for _ in 0..<3 {
            m.refresh()
            try await Task.sleep(for: .milliseconds(400))
        }
        #expect(m.step == .microphone)
        // Its Continue button moves on, and the next step is back to normal.
        m.next()
        #expect(m.step == .keyboard)
        perms.states[.inputMonitoring] = .granted
        m.refresh()
        await until { m.step == .accessibility }
        #expect(m.step == .accessibility, "a permission granted on the step still moves on by itself")
    }

    // MARK: Defaults first

    @Test func theDefaultChoiceIsListedFirst() {
        let fresh = AppSettings(defaults: UserDefaults(suiteName: "saylark.test.\(UUID().uuidString)")!)
        #expect(VoiceVisualKind.allCases.first == fresh.voiceVisual)
        #expect(PillAccent.userChoices.first == fresh.accent)
        #expect(TriggerKey.userChoices.first == fresh.triggerKey)
    }

    // MARK: Find

    @Test func findGoesToTheSearchOfHomeAndDictionaryOnly() {
        let url = SampleDictionary.write()
        defer { cleanup(url) }
        let model = MainModel(library: LibraryModel(history: FakeHistory([])), dictionary: DictionaryModel(url: url))
        model.find()
        #expect(model.findRequest == 1)
        model.tab = .dictionary
        model.find()
        #expect(model.findRequest == 2)
        model.tab = .settings
        model.find()
        #expect(model.findRequest == 2, "Settings has no search field")
    }

    @Test func mainMenuHasAboutHideOthersAndFind() {
        let menu = AppMenu.make(target: NSObject(), openMain: Selector(("a")), openSettings: Selector(("b")), find: Selector(("find")))
        let app = menu.items.first?.submenu?.items.map(\.title) ?? []
        #expect(app.first == "About Saylark" && app.contains("Hide Others") && app.contains("Show All"))
        let find = menu.items.first { $0.title == "Edit" }?.submenu?.items.first { $0.title == "Find…" }
        #expect(find?.keyEquivalent == "f" && find?.action == Selector(("find")))
    }

    // MARK: Menu bar wording

    @Test func menuItemsSayWhatTheyDoAndShowTheText() {
        let now = Date()
        let take = DictationRecord(startedAt: now.addingTimeInterval(-60), duration: 3, mode: .active, handsFree: false,
                                   rawText: "hello there", cleanText: "hello there", outcome: .inserted, audioPath: nil)
        let items = MenuModel(recent: [take], now: now).entries.compactMap { if case .item(let i) = $0 { i } else { nil } }
        let copy = items.first { $0.action == .copyLast }
        #expect(copy?.title == "Copy Last Take" && copy?.subtitle == "hello there")
        #expect(items.contains { $0.title == "Paste Last Take" && $0.action == .pasteLast })
    }

    // MARK: Accent contrast

    /// WCAG relative luminance of an sRGB colour.
    private func luminance(_ c: CGColor) -> Double {
        let comps = (c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0])
        func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(comps[0]) + 0.7152 * lin(comps[1]) + 0.0722 * lin(comps[2])
    }

    private func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    @Test func windowAccentsReadAgainstWhiteTextAndBothBackgrounds() {
        let white = 1.0, darkWindow = luminance(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        for accent in PillAccent.userChoices {
            let l = luminance(accent.controlColor)
            // White text on a prominent button, and accent text on a white or dark window: at least
            // 3:1 (the bar for large and bold text and for controls).
            #expect(contrast(l, white) >= 3.4, "\(accent) under white text")
            #expect(contrast(l, darkWindow) >= 3.0, "\(accent) on a dark window")
        }
        // The pill colour itself was too light for a window (why controlColor exists).
        #expect(contrast(luminance(PillAccent.amber.color), white) < 2)
    }
}
