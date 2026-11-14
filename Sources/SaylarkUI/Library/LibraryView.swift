import AppKit
import SaylarkCore
import SwiftUI

/// The Home tab: a title with search, quiet stats, then one list of takes grouped by day.
public struct LibraryView: View {
    @Bindable var model: LibraryModel
    let accent: Color
    /// Bumped by Edit > Find (⌘F) to put the cursor in the search field.
    let findRequest: Int
    @FocusState private var searchFocused: Bool

    public init(model: LibraryModel, accent: Color, findRequest: Int = 0) {
        self.model = model
        self.accent = accent
        self.findRequest = findRequest
    }

    public var body: some View {
        VStack(spacing: 0) {
            StatsHeader(stats: model.stats)
            Divider()
            if !model.loaded {
                Spacer()
            } else if model.shown.isEmpty {
                EmptyLibrary(query: model.query, trigger: model.triggerName)
            } else {
                list
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Home")
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search takes")
        .searchFocused($searchFocused)
        .onChange(of: findRequest) { searchFocused = true }
        .task { if !model.loaded { await model.load() } }
        .confirmationDialog("Delete this take?", isPresented: deleteAsked, titleVisibility: .visible, presenting: model.pendingDelete) { _ in
            Button("Delete", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: { record in
            Text(record.audioPath == nil ? "Its text is removed from Home. This can't be undone."
                                         : "Its text and saved audio are removed. This can't be undone.")
        }
    }

    private var deleteAsked: Binding<Bool> {
        Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(model.days) { day in
                    Section {
                        ForEach(day.records) { record in
                            TakeRow(record: record, model: model, accent: accent)
                        }
                    } header: {
                        DayHeader(title: day.title, count: day.records.count)
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Header

/// Words today and this week, takes and minutes today, and median time to text. Plain numbers, no cards.
struct StatsHeader: View {
    let stats: LibraryStats

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            Stat(value: stats.wordsToday.formatted(), label: "words today")
            Stat(value: stats.wordsThisWeek.formatted(), label: "this week")
            Stat(value: stats.takesToday.formatted(), label: stats.takesToday == 1 ? "take today" : "takes today")
            Stat(value: Self.minutes(stats.minutesToday), label: "minutes talking")
            Stat(value: stats.medianTimeToTextMs.map { "\(Int($0.rounded())) ms" } ?? "–", label: "median time to text")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }
}

extension StatsHeader {
    /// "0" for none, one decimal under ten minutes, whole minutes after.
    static func minutes(_ m: Double) -> String {
        if m <= 0 { return "0" }
        return m < 10 ? m.formatted(.number.precision(.fractionLength(1))) : Int(m.rounded()).formatted()
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DayHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(count == 1 ? "1 take" : "\(count) takes").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.97))
    }
}

private struct EmptyLibrary: View {
    let query: String
    var trigger = "Fn"
    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(query.isEmpty ? "No takes yet" : "No takes match “\(query)”")
                .font(.system(size: 14, weight: .semibold))
            Text(query.isEmpty ? "Hold \(trigger) and talk. Everything you say lands here." : "Search looks at the text of every take.")
                .multilineTextAlignment(.center)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
