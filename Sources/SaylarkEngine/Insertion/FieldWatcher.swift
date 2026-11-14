import Foundation
import SaylarkCore

/// "Paste when I click a field": tells us when an editable field next gets focus.
@MainActor
public protocol FieldWatcher: AnyObject {
    /// Starts watching. `onField` runs once, on the main actor, when focus moves into an editable,
    /// non-secure field. Stops by itself after `timeout` seconds without calling `onField`.
    func watch(timeout: Double, onField: @escaping @MainActor (FocusInfo) -> Void)
    func cancel()
}

/// Polls a `FocusProbe`. Simpler and sturdier than per-app `AXObserver` focus notifications,
/// which Electron apps send unreliably and which need re-registering for every app the user
/// switches to; at 10 Hz for at most `timeout` seconds the cost is a few AX calls per tick.
///
/// Fires only for a *change* of focus into a field: if focus already sat in a field when watching
/// started (the card for an app switch), the user has to click a field (that one again counts
/// only after focus has left it).
@MainActor
public final class PollingFieldWatcher: FieldWatcher {
    public let probe: any FocusProbe
    public let interval: Double
    private var task: Task<Void, Never>?

    public init(probe: any FocusProbe, interval: Double = 0.1) {
        self.probe = probe
        self.interval = interval
    }

    public func watch(timeout: Double, onField: @escaping @MainActor (FocusInfo) -> Void) {
        cancel()
        let probe = self.probe, interval = self.interval
        task = Task { @MainActor in
            let end = Date().addingTimeInterval(timeout)
            var last = await probe.focused()
            while !Task.isCancelled, Date() < end {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                let now = await probe.focused()
                if Task.isCancelled { return }
                let moved = now.elementID != last.elementID || now.pid != last.pid || last.kind != .editableText
                if now.kind == .editableText, moved {
                    onField(now)
                    return
                }
                last = now
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}
