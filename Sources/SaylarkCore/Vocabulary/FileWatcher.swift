import Foundation

/// Calls back when a file changes: written in place, replaced by an atomic save (a new file renamed
/// over it), created, or deleted. Editors save in all of these ways, so the watcher listens to the
/// file's folder (renames and creates) and also checks the file every `interval` seconds (writes in
/// place, and anything the folder events miss). A change is the file's modification date, size or
/// inode moving; the callback runs at most once per `debounce`, on `queue`.
public final class FileWatcher: @unchecked Sendable {
    public let url: URL
    private let interval: Double
    private let debounce: Double
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void

    // Touched only on `queue`.
    private var folderSource: (any DispatchSourceFileSystemObject)?
    private var timer: (any DispatchSourceTimer)?
    private var last: Signature?
    private var pending = false
    private var running = false

    struct Signature: Equatable {
        var modified: Date?
        var size: Int?
        var inode: Int?
    }

    public init(url: URL, interval: Double = 0.5, debounce: Double = 0.15, queue: DispatchQueue = DispatchQueue(label: "saylark.filewatcher"), onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.interval = interval
        self.debounce = debounce
        self.queue = queue
        self.onChange = onChange
    }

    deinit {
        folderSource?.cancel()
        timer?.cancel()
    }

    /// Starts watching. The file as it is now is the baseline: only later changes call back.
    public func start() {
        queue.sync {
            guard !running else { return }
            running = true
            last = Self.signature(url)
            watchFolder()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.check() }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        queue.sync {
            running = false
            folderSource?.cancel()
            folderSource = nil
            timer?.cancel()
            timer = nil
        }
    }

    private func watchFolder() {
        folderSource?.cancel()
        folderSource = nil
        let folder = url.deletingLastPathComponent().path
        let fd = open(folder, O_EVTONLY)
        guard fd >= 0 else { return }  // no folder yet: the timer still notices the file appear
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.scheduleCheck() }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderSource = source
    }

    private func scheduleCheck() {
        guard running, !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self else { return }
            self.pending = false
            self.check()
        }
    }

    private func check() {
        guard running else { return }
        if folderSource == nil { watchFolder() }
        let now = Self.signature(url)
        guard now != last else { return }
        last = now
        onChange()
    }

    static func signature(_ url: URL) -> Signature? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Signature(
            modified: a[.modificationDate] as? Date, size: (a[.size] as? NSNumber)?.intValue,
            inode: (a[.systemFileNumber] as? NSNumber)?.intValue)
    }
}
