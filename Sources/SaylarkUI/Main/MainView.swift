import AppKit
import Observation
import SaylarkCore
import SwiftUI

/// The tabs of the Saylark window.
public enum MainTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case home, dictionary, settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: "Home"
        case .dictionary: "Dictionary"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .dictionary: "character.book.closed"
        case .settings: "gearshape"
        }
    }

    /// Home and Dictionary have a search field (Edit > Find); Settings does not.
    public var isSearchable: Bool { self != .settings }
}

/// The Saylark window's state: which tab is showing, and each tab's model.
@MainActor @Observable public final class MainModel {
    public var tab: MainTab
    public let library: LibraryModel
    public let dictionary: DictionaryModel
    /// The accent for the sidebar icons and Home's controls. Follows the Settings choice live.
    public var accent: Color
    /// Bumped by Edit > Find (⌘F): the showing tab puts the cursor in its search field.
    public private(set) var findRequest = 0

    public init(library: LibraryModel, dictionary: DictionaryModel, tab: MainTab = .home, accent: Color = .accentColor) {
        self.library = library
        self.dictionary = dictionary
        self.tab = tab
        self.accent = accent
    }

    /// Edit > Find. On Settings, which has no search, it does nothing.
    public func find() {
        guard tab.isSearchable else { return }
        findRequest += 1
    }
}

/// The Saylark window: a sidebar with Home, Dictionary and Settings.
public struct MainView<Settings: View>: View {
    @Bindable var model: MainModel
    let settings: Settings

    public init(model: MainModel, @ViewBuilder settings: () -> Settings) {
        self.model = model
        self.settings = settings()
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    /// Three rows. ⌘1, ⌘2 and ⌘3 switch tabs.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(MainTab.allCases.enumerated()), id: \.element) { i, tab in
                SidebarRow(tab: tab, shortcut: i + 1, selected: model.tab == tab, accent: model.accent) { model.tab = tab }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Spacer(minLength: 0)
            hint
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    @ViewBuilder private var detail: some View {
        switch model.tab {
        case .home:
            // Takes use the pill's accent; Dictionary and Settings keep the system accent for controls.
            LibraryView(model: model.library, accent: model.accent, findRequest: model.findRequest)
                .tint(model.accent)
        case .dictionary:
            DictionaryView(model: model.dictionary, findRequest: model.findRequest)
        case .settings:
            SettingsPage { settings }
        }
    }

    /// A quiet reminder of the one thing to know.
    private var hint: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic")
                .accessibilityHidden(true)
            Text("Hold \(model.library.triggerName) to talk")
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }
}

private struct SidebarRow: View {
    let tab: MainTab
    let shortcut: Int
    let selected: Bool
    let accent: Color
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(accent)
                    .frame(width: 18)
                Text(tab.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: .labelColor))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(selected ? 0.09 : hovering ? 0.045 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(tab.title) (⌘\(shortcut))")
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Settings as a page: the same form as before, centred and scrolling.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Settings")
    }
}
