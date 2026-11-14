import Foundation

/// A value behind a lock, for state that holds non-Sendable system objects (Core Foundation ports,
/// run loops, observers). The owner promises those objects are only used under the lock or on
/// their own thread.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    @discardableResult
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
