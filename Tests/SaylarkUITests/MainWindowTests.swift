import AppKit
import Foundation
import Testing
@testable import SaylarkUI
import SaylarkCore
import SwiftUI

/// The Dictionary tab's model and the Saylark window's pieces. Dictionaries are temp files.
@MainActor @Suite struct DictionaryModelTests {
    func model(_ text: String = SampleDictionary.text) -> (DictionaryModel, URL) {
        let url = SampleDictionary.write(text)
        let m = DictionaryModel(url: url)
        m.load()
        return (m, url)
    }

    func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    @Test func loadsSearchesTermsAndHeardAsForms() {
        let (m, url) = model()
        defer { cleanup(url) }
        #expect(m.entries.count == 13 && m.aliasCount == 19)
        m.query = "tens"
        #expect(m.shown.map(\.term) == ["TensorFlow"])
        m.query = "versel"
        #expect(m.shown.map(\.term) == ["Vercel"])
        m.query = "zzz"
        #expect(m.shown.isEmpty)
    }

    @Test func addWritesTheFileAndKeepsTheUsersLines() throws {
        let (m, url) = model("# mine\nCodex: codecs\n")
        defer { cleanup(url) }
        m.query = "Kalshi"
        m.startAdding()
        #expect(m.editor?.term == "Kalshi")
        m.editor?.heardAs = "Calci, cal she"
        #expect(m.commit())
        #expect(m.editor == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# mine\nCodex: codecs\nKalshi: Calci, cal she\n")
        // Adding a term that is already there adds its new heard-as forms.
        m.editor = DictionaryModel.Editor(term: "codex", heardAs: "code ex")
        #expect(m.commit())
        #expect(m.entries.first?.aliases == ["codecs", "code ex"])
    }

    @Test func editRenamesInPlaceAndCanDropHeardAsForms() throws {
        let (m, url) = model("A\nRelbird: real bird, Realbird\nC\n")
        defer { cleanup(url) }
        m.startEditing(try #require(m.entries.first { $0.term == "Relbird" }))
        m.editor?.term = "Reelbird"
        m.editor?.heardAs = "real bird"
        #expect(m.commit())
        #expect(try String(contentsOf: url, encoding: .utf8) == "A\nReelbird: real bird\nC\n")
    }

    @Test func renamingOntoAnotherTermMergesThem() throws {
        let (m, url) = model("Reelbird: real bird\nRelbird: Realbird\n")
        defer { cleanup(url) }
        m.startEditing(try #require(m.entries.last))
        m.editor?.term = "Reelbird"
        #expect(m.commit())
        #expect(m.entries == [DictionaryEntry(term: "Reelbird", aliases: ["real bird", "Realbird"])])
    }

    @Test func aBadTermKeepsTheFormOpenWithAReason() throws {
        let (m, url) = model()
        defer { cleanup(url) }
        let before = try String(contentsOf: url, encoding: .utf8)
        m.editor = DictionaryModel.Editor(term: "Foo, Bar")
        #expect(!m.commit())
        #expect(m.editor?.problem?.contains("comma") == true)
        m.editor = DictionaryModel.Editor(term: "   ")
        #expect(!m.commit())
        #expect(m.editor?.problem == "Type the term the way it should be written.")
        #expect(try String(contentsOf: url, encoding: .utf8) == before)
    }

    @Test func removeDeletesTheLineAndClosesItsEditor() throws {
        let (m, url) = model("Codex: codecs\nKalshi\n")
        defer { cleanup(url) }
        let codex = try #require(m.entries.first)
        m.startEditing(codex)
        m.remove(codex)
        #expect(m.editor == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Kalshi\n")
    }

    @Test func skippedLinesAreReportedAndAMissingFileIsEmpty() {
        let (m, url) = model(SampleDictionary.withProblems)
        defer { cleanup(url) }
        #expect(m.problems.count == 2)
        let missing = DictionaryModel(url: url.deletingLastPathComponent().appendingPathComponent("none.txt"))
        missing.load()
        #expect(missing.loaded && missing.entries.isEmpty && missing.failure == nil)
    }

    @Test func anEditElsewhereShowsUpWhileWatching() async throws {
        let (m, url) = model("Codex\n")
        defer { cleanup(url); m.stopWatching() }
        m.watch()
        try Data("Codex\nKalshi\n".utf8).write(to: url, options: .atomic)
        let end = Date().addingTimeInterval(3)
        while m.entries.count < 2, Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        #expect(m.entries.map(\.term) == ["Codex", "Kalshi"])
    }
}

@MainActor @Suite struct MainWindowTests {
    @Test func windowHasThreeTabsAndStartsOnHome() {
        #expect(MainTab.allCases.map(\.title) == ["Home", "Dictionary", "Settings"])
        let url = SampleDictionary.write()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = MainModel(library: LibraryModel(history: FakeHistory(SampleTakes.history())), dictionary: DictionaryModel(url: url))
        #expect(model.tab == .home)
        // Built the way the app builds it, never ordered on screen.
        let window = Windows.main(MainView(model: model) { EmptyView() }, remembersFrame: false)
        // The title follows the tab (it shows in the toolbar), like System Settings.
        #expect(["Saylark", "Home"].contains(window.title) && window.styleMask.contains(.resizable))
        #expect(window.contentMinSize.width >= 720)
        window.close()
    }

    @Test func windowMenuOpensSaylark() {
        let menu = AppMenu.make(target: NSObject(), openMain: Selector(("openSaylark")), openSettings: Selector(("b")))
        let item = menu.items.first { $0.title == "Window" }?.submenu?.items.first { $0.title == "Saylark" }
        #expect(item?.keyEquivalent == "0" && item?.action == Selector(("openSaylark")))
    }
}
