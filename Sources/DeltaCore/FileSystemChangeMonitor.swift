import CoreServices
import Foundation

public struct FileSystemChange: Equatable, Sendable {
    public var path: String
    public var eventID: UInt64
    public var flags: FSEventStreamEventFlags

    public init(path: String, eventID: UInt64, flags: FSEventStreamEventFlags) {
        self.path = path
        self.eventID = eventID
        self.flags = flags
    }
}

public final class FileSystemChangeMonitor: @unchecked Sendable {
    private final class CallbackBox {
        let handler: @Sendable ([FileSystemChange]) -> Void

        init(handler: @escaping @Sendable ([FileSystemChange]) -> Void) {
            self.handler = handler
        }
    }

    private var stream: FSEventStreamRef?
    private var callbackBox: CallbackBox?
    private let queue = DispatchQueue(label: "com.delta.backup.fsevents")

    public init() {}

    deinit {
        stop()
    }

    public func start(
        paths: [String],
        latency: TimeInterval = 5,
        handler: @escaping @Sendable ([FileSystemChange]) -> Void
    ) throws {
        stop()
        guard !paths.isEmpty else { return }

        let box = CallbackBox(handler: handler)
        callbackBox = box
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(box).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, eventIDs in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self) as NSArray
            var changes: [FileSystemChange] = []
            changes.reserveCapacity(eventCount)

            for index in 0..<eventCount {
                guard let path = cfPaths[index] as? String else { continue }
                changes.append(
                    FileSystemChange(
                        path: path,
                        eventID: eventIDs[index],
                        flags: eventFlags[index]
                    )
                )
            }

            if !changes.isEmpty {
                box.handler(changes)
            }
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else {
            throw FileSystemChangeMonitorError.couldNotCreateStream
        }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            stop()
            throw FileSystemChangeMonitorError.couldNotStartStream
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        callbackBox = nil
    }
}

public enum FileSystemChangeMonitorError: Error, LocalizedError {
    case couldNotCreateStream
    case couldNotStartStream

    public var errorDescription: String? {
        switch self {
        case .couldNotCreateStream: "Could not create an FSEvents stream."
        case .couldNotStartStream: "Could not start the FSEvents stream."
        }
    }
}
