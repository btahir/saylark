import AppKit
import SaylarkCore
import SwiftUI

/// One take: app icon, the first lines of text, time and duration. Hover swaps the time for Copy,
/// Paste again and Play. Clicking opens the full text and the player.
struct TakeRow: View {
    static let iconSize: CGFloat = 20
    static let textInset: CGFloat = 24 + iconSize + 12
    static let metaWidth: CGFloat = 84

    let record: DictationRecord
    let model: LibraryModel
    let accent: Color
    @ViewState private var pointerInside = false
    private var hovering: Bool { pointerInside || model.hoverPreview == record.id }

    private var expanded: Bool { model.expanded == record.id }
    private var playerOpen: Bool { expanded && model.player.record?.id == record.id }
    private var state: TakeRowState { TakeRowState.of(record) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(bundleID: record.appBundleID, appName: record.appName)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .padding(.top, 0.5)
            VStack(alignment: .leading, spacing: 6) {
                texts
                statusLine
                if playerOpen { PlayerStrip(player: model.player, accent: accent) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            meta.frame(width: Self.metaWidth, alignment: .topTrailing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering || expanded ? 0.045 : 0))
                .padding(.horizontal, 12)
        }
        .contentShape(Rectangle())
        .onHover { pointerInside = $0 }
        .onTapGesture(perform: toggle)
        .contextMenu {
            Button(expanded ? "Collapse" : "Show Full Text", action: toggle)
            Divider()
            Button("Copy") { model.copy(record) }
                .disabled(!state.hasText)
            if state.hoverActions.contains(.pasteAgain) {
                Button("Paste Again") { model.pasteAgain(record) }
            }
            if state.hasAudio {
                Button(isPlaying ? "Pause" : "Play") { model.togglePlay(record) }
            }
            Divider()
            Button("Delete…", role: .destructive) { model.requestDelete(record) }
        }
        // VoiceOver: the row reads as one take, and the hover buttons (which only appear under the
        // pointer) are offered as actions.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(expanded ? "Collapses the take" : "Shows the full text and the player")
        .accessibilityAction(.default, toggle)
        .accessibilityAction(named: "Copy") { model.copy(record) }
        .accessibilityAction(named: "Delete") { model.requestDelete(record) }
    }

    private var isPlaying: Bool { model.player.isPlaying && playerOpen }

    private func toggle() {
        model.expanded = expanded ? nil : record.id
    }

    // MARK: Text

    @ViewBuilder private var texts: some View {
        if let placeholder = state.placeholder {
            Text(placeholder)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } else {
            text(record.cleanText.split(whereSeparator: \.isWhitespace).map(String.init))
                .font(.system(size: 13))
                .lineLimit(expanded ? nil : 2)
                .lineSpacing(2)
        }
    }

    /// Joins the words into one `Text`, marking search matches and the word being played.
    private func text(_ tokens: [String]) -> Text {
        var out = AttributedString()
        let playing = playerOpen ? model.player.wordIndex(at: model.player.currentTime) : nil
        let query = model.query.trimmingCharacters(in: .whitespaces).lowercased()
        for (i, token) in tokens.enumerated() {
            var word = AttributedString(token)
            if !query.isEmpty, token.lowercased().contains(query) {
                word.backgroundColor = Color.yellow.opacity(0.45)
            }
            if i == playing {
                // The spoken word: solid accent, so it reads apart from search marks.
                word.backgroundColor = accent
                word.foregroundColor = .white
            }
            if i > 0 { out += AttributedString(" ") }
            out += word
        }
        return Text(out)
    }

    // MARK: Status

    /// Under the text: a quiet word for how the take ended, and the button that fixes a cancelled or
    /// failed one. Takes whose text simply went in have no line at all.
    @ViewBuilder private var statusLine: some View {
        let busy = model.busy.contains(record.id)
        let flash = model.flash[record.id]
        if state.label != nil || state.recovered || flash != nil || busy {
            HStack(spacing: 10) {
                if let label = state.label {
                    Label(label, systemImage: state.labelSymbol ?? "circle")
                        .labelStyle(QuietLabelStyle())
                }
                if state.recovered {
                    Label("Recovered", systemImage: "arrow.counterclockwise")
                        .labelStyle(QuietLabelStyle())
                        .help("Saylark closed during this take. It was restored when Saylark opened again.")
                }
                if state.canRecover {
                    Button("Recover") { model.recover(record) }
                        .controlSize(.small)
                        .disabled(busy)
                        .help("Paste this take at your cursor")
                }
                if state.canTranscribeAgain {
                    Button("Transcribe again") { model.transcribeAgain(record) }
                        .controlSize(.small)
                        .disabled(busy)
                }
                if busy {
                    ProgressView().controlSize(.mini)
                } else if let flash {
                    Text(flash).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Meta and actions

    private var meta: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(record.startedAt, format: .dateTime.hour().minute())
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    if record.handsFree {
                        Image(systemName: "infinity").font(.system(size: 9, weight: .semibold)).accessibilityLabel("Hands-free")
                    }
                    Text(Self.duration(record.duration))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .opacity(hovering ? 0 : 1)
            HStack(spacing: 2) {
                ForEach(state.hoverActions, id: \.self) { action in
                    switch action {
                    case .copy:
                        RowButton(symbol: "doc.on.doc", help: "Copy") { model.copy(record) }
                    case .pasteAgain:
                        RowButton(symbol: "arrow.down.to.line", help: "Paste again") { model.pasteAgain(record) }
                    case .play:
                        RowButton(symbol: isPlaying ? "pause.fill" : "play.fill", help: isPlaying ? "Pause" : "Play") {
                            model.togglePlay(record)
                        }
                    }
                }
            }
            .opacity(hovering ? 1 : 0)
        }
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t < 60 ? "\(t) s" : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// A small tertiary icon and word, for the marks under a row.
private struct QuietLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 10))
            configuration.title.font(.system(size: 11))
        }
        .foregroundStyle(.tertiary)
    }
}

private struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The app a take went to, from its bundle ID. Falls back to a plain symbol.
struct AppIconView: View {
    let bundleID: String?
    let appName: String?

    var body: some View {
        if let icon = AppIcons.icon(for: bundleID) {
            Image(nsImage: icon).resizable().interpolation(.high).accessibilityLabel(appName ?? "App")
        } else {
            // App not installed here: its initial on a quiet tile, the same size as an icon.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .padding(1.5)
                .overlay(Text(appName.flatMap(\.first).map(String.init) ?? "·")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary))
                .accessibilityLabel(appName ?? "Unknown app")
        }
    }
}

@MainActor enum AppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let hit = cache[bundleID] { return hit }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = icon
        return icon
    }
}
