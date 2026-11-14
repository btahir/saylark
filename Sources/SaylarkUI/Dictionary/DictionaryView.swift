import AppKit
import SaylarkCore
import SwiftUI

/// The Dictionary tab: the words Saylark should spell your way, with search, add, edit and remove.
/// Everything here is a line in `dictionary.txt`.
public struct DictionaryView: View {
    @Bindable var model: DictionaryModel
    /// Bumped by Edit > Find (⌘F) to put the cursor in the search field.
    let findRequest: Int
    @Environment(\.undoManager) private var undoManager
    @FocusState private var searchFocused: Bool

    public init(model: DictionaryModel, findRequest: Int = 0) {
        self.model = model
        self.findRequest = findRequest
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text("Names and words Saylark should spell your way. Add the wrong spellings the model writes, and Saylark replaces them too.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            if let editor = Binding($model.editor) {
                EntryEditor(editor: editor, onSave: { model.commit() }, onCancel: { model.cancelEditing() })
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
            Divider()
            if let failure = model.failure {
                Notice(symbol: "exclamationmark.triangle.fill", tint: .orange, text: failure)
            }
            if !model.problems.isEmpty {
                SkippedLines(problems: model.problems, open: model.openFile)
            }
            if !model.loaded {
                Spacer()
            } else if model.shown.isEmpty {
                EmptyDictionary(query: model.query, add: model.startAdding)
            } else {
                list
            }
            if let removed = model.removed {
                UndoBar(term: removed.entry.term, undo: undoRemove, dismiss: model.dismissRemoval)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Color(nsColor: .textBackgroundColor))
        .animation(.easeOut(duration: 0.15), value: model.editor)
        .animation(.easeOut(duration: 0.15), value: model.removed)
        .navigationTitle("Dictionary")
        .navigationSubtitle(subtitle)
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search dictionary")
        .searchFocused($searchFocused)
        .onChange(of: findRequest) { searchFocused = true }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.startAdding()
                } label: {
                    Label("Add Term", systemImage: "plus")
                }
                .help("Add a term (⌘N)")
                .accessibilityLabel("Add Term")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .onAppear {
            if !model.loaded { model.load() }
            model.watch()
        }
    }

    private var subtitle: String {
        let n = model.entries.count, a = model.aliasCount
        let terms = n == 1 ? "1 term" : "\(n.formatted()) terms"
        let replaced = a == 0 ? "" : a == 1 ? ", 1 replacement" : ", \(a.formatted()) replacements"
        return terms + replaced
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.shown) { entry in
                    EntryRow(entry: entry, query: model.query, preview: model.hoverPreview == entry.id,
                             editing: model.editor?.original.map(SoundKey.spelling) == entry.id,
                             edit: { model.startEditing(entry) }, remove: { remove(entry) })
                    Divider().padding(.horizontal, 24)
                }
            }
            .padding(.vertical, 4)
            .padding(.bottom, 8)
        }
        .scrollContentBackground(.hidden)
    }

    /// Removes a term and offers it back: the Undo bar, and ⌘Z through the window's undo manager.
    private func remove(_ entry: DictionaryEntry) {
        model.remove(entry)
        guard model.removed?.entry == entry else { return }
        undoManager?.registerUndo(withTarget: model) { $0.undoRemove() }
        undoManager?.setActionName("Remove “\(entry.term)”")
    }

    private func undoRemove() {
        undoManager?.removeAllActions(withTarget: model)
        model.undoRemove()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(model.url.path)
            Spacer(minLength: 8)
            Button("Show in Finder") { model.revealFile() }
                .buttonStyle(.link)
                .font(.system(size: 11))
            Button("Open in Editor") { model.openFile() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }
}

// MARK: - Rows

private struct EntryRow: View {
    let entry: DictionaryEntry
    let query: String
    let preview: Bool
    let editing: Bool
    let edit: () -> Void
    let remove: () -> Void
    @ViewState private var pointerInside = false

    private var hovering: Bool { pointerInside || preview }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.term)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 180, alignment: .leading)
                .help(entry.term)
            if !entry.aliases.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("replaces")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    FlowText(items: entry.aliases)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 2) {
                RowButton(symbol: "pencil", help: "Edit", action: edit)
                RowButton(symbol: "trash", help: "Remove", action: remove)
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .frame(minHeight: 34)
        .background {
            // The same rounded, inset highlight as a take on Home.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(editing ? Color.accentColor.opacity(0.12) : Color.primary.opacity(hovering ? 0.045 : 0))
                .padding(.horizontal, 12)
        }
        // The whole row is the target: a click anywhere on it edits the term.
        .contentShape(Rectangle())
        .onHover { pointerInside = $0 }
        .onTapGesture(perform: edit)
        .contextMenu {
            Button("Edit…", action: edit)
            Divider()
            Button("Remove", role: .destructive, action: remove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Edits the term")
        .accessibilityAction(named: "Edit", edit)
        .accessibilityAction(named: "Remove", remove)
    }
}

/// The spellings a term replaces, as quiet chips that wrap onto more lines when there are many.
private struct FlowText: View {
    let items: [String]

    var body: some View {
        WrapLayout(spacing: 4, lineSpacing: 4) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .lineLimit(1)
            }
        }
    }
}

/// Lays children out left to right, starting a new line when the next one would not fit.
struct WrapLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    /// The first line's text baseline, so the row's label lines up with the first chip.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, let first = subviews.first else { return nil }
        return bounds.minY + first.dimensions(in: .unspecified)[.firstTextBaseline]
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? min(size.width, width) : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

private struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Editor

private struct EntryEditor: View {
    @Binding var editor: DictionaryModel.Editor
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focus: Field?

    enum Field { case term, replaces }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editor.original == nil ? "New Term" : "Edit Term")
                .font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Term")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    TextField("Kubernetes", text: $editor.term)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .term)
                        .onSubmit(onSave)
                        .accessibilityLabel("Term")
                }
                GridRow {
                    Text("Replaces")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("ship tiffin, shift tiffin", text: $editor.heardAs)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .replaces)
                            .onSubmit(onSave)
                            .accessibilityLabel("Replaces")
                        Text("Optional. Wrong spellings to change to this term, separated by commas.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 12))
            HStack {
                if let problem = editor.problem {
                    Label(problem, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .labelStyle(.titleAndIcon)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(editor.original == nil ? "Add" : "Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .onAppear { focus = .term }
        // Editing another term while the form is open: the cursor goes back to the term.
        .onChange(of: editor.original) { focus = .term }
    }
}

// MARK: - Notices and empty state

/// "Removed “Kubernetes”" with Undo, under the list, for a few seconds after a remove.
private struct UndoBar: View {
    let term: String
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Removed “\(term)”")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Undo", action: undo)
                .controlSize(.small)
                .help("Put “\(term)” back (⌘Z)")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
    }
}

private struct SkippedLines: View {
    let problems: [DictionaryFile.Problem]
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(problems.count == 1 ? "1 line in the file is skipped" : "\(problems.count) lines in the file are skipped")
                    .font(.system(size: 12, weight: .semibold))
                ForEach(problems.prefix(3), id: \.line) { p in
                    Text("Line \(p.line): “\(p.text.trimmingCharacters(in: .whitespaces))”, \(p.reason)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if problems.count > 3 {
                    Text("and \(problems.count - 3) more")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Open in Editor", action: open)
                .controlSize(.small)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.07))
    }
}

private struct Notice: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12))
            .foregroundStyle(.primary, tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(tint.opacity(0.07))
    }
}

private struct EmptyDictionary: View {
    let query: String
    let add: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "character.book.closed")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(query.isEmpty ? "No terms yet" : "Nothing matches “\(query)”")
                .font(.system(size: 14, weight: .semibold))
            Text(query.isEmpty
                 ? "Add names, products and jargon the model gets wrong.\nSaylark spells them your way from the next take."
                 : "Search looks at terms and the spellings they replace.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(query.isEmpty ? "Add a Term" : "Add “\(query)”", action: add)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
