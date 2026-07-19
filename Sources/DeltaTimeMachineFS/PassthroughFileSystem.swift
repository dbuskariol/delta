/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The custom class that implements a simplified file system.
*/

import Foundation
import DeltaTimeMachineIPC
import FSKit
import OSLog

extension Logger {
    static let passthroughfs = Logger(subsystem: "com.delta.backup.timemachine-filesystem", category: "FSKit")
}

/// Returns the current `errno` value as a `POSIXError`.
var posixErrno: POSIXError {
    POSIXError(POSIXError.Code(rawValue: errno) ?? .EINVAL)
}

/// Returns the result of the given block, or throws an error if `errno` is nonzero.
/// - Parameter block: The block to execute.
func throwErrno<T: SignedInteger>(_ block: () throws -> T) throws -> T {
    let ret = try block()
    guard ret >= 0 else {
        guard errno != 0 else {
            Logger.passthroughfs.error("Call to block failed, and errno is not set")
            return ret
        }
        throw posixErrno
    }
    return ret
}

/// Returns a volume name made from the directory name of given path with a `_passthroughfs` suffix.
/// - Parameter path: The path to use to generate a volume name.
func createVolumeNameFromPath(_ path: String) -> FSFileName {
    let dirName = (path as NSString).lastPathComponent
    return FSFileName(string: dirName + "_delta_time_machine")
}

/// Converts an FSKit name into exactly one safe POSIX path component.
/// Namespace operations use descriptor-relative syscalls, so accepting a slash,
/// dot traversal, or an embedded NUL here would escape that boundary.
func validatedFSComponent(_ name: FSFileName) throws -> String {
    guard
        let component = name.string,
        !component.isEmpty,
        component != ".",
        component != "..",
        !component.contains("/"),
        !component.utf8.contains(0)
    else {
        throw POSIXError(.EINVAL)
    }
    return component
}

func matchesPOSIXFileType(_ attributes: stat, itemType: FSItem.ItemType) -> Bool {
    fsItemType(forPOSIXMode: attributes.st_mode) == itemType
}

func fsItemType(forPOSIXMode mode: mode_t) -> FSItem.ItemType? {
    switch mode & S_IFMT {
    case S_IFDIR: .directory
    case S_IFREG: .file
    default: nil
    }
}

/// A file system that passes through all operations to the underlying file system from a given FSPathURLResource.
@objc
class PassthroughFileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {

    var resource: FSPathURLResource?

    public override init() {
        Logger.passthroughfs.debug("\(#function): init")
    }

    /// Performs an operation to load a resource.
    /// - Parameters:
    ///   - resource: The resource to load.
    ///   - options: The options to use when loading the resource.
    ///   - replyHandler: The handler to call when load operation is complete with the volume, and any error.
    public func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.passthroughfs.debug("\(#function): Invalid resource type")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        guard self.resource == nil else {
            return replyHandler(nil, POSIXError(.EBUSY))
        }

        /// Handle any options present.
        ///
        /// This Module doesn't make use of options for loading. The only option to handle
        /// is `-f`, and that is because this Module doesn't support formatting:
        ///   If the force option is present and the file system doesn't support
        ///   formatting, this method should reply with the POSIX error ENOTSUP.
        ///
        if options.taskOptions.contains("-f") {
            return replyHandler(nil, POSIXError(.ENOTSUP))
        }

        let requestedReadOnly = options.taskOptions.contains("--rdonly")
        Logger.passthroughfs.info(
            "Loading path resource: writable=\(urlResource.isWritable, privacy: .public) requestedReadOnly=\(requestedReadOnly, privacy: .public)"
        )

        guard urlResource.url.startAccessingSecurityScopedResource() else {
            Logger.passthroughfs.error("\(#function): Can't start accessing security scoped resource")
            return replyHandler(nil, POSIXError(.EACCES))
        }

        do {
            let volume = try PassthroughFSVolume(
                rootPath: urlResource.url.path,
                // Apple's supported passthrough sample treats the mount task's
                // read-only option as authoritative. On macOS 26, mount(8)
                // supplies a path resource whose isWritable value is false
                // even for an explicit read/write mount. The security-scoped
                // resource and every descriptor-relative POSIX mutation still
                // enforce actual source access fail-closed.
                isReadOnly: requestedReadOnly
            )
            self.resource = urlResource
            self.containerStatus = .ready
            return replyHandler(volume, nil)
        } catch let error {
            urlResource.url.stopAccessingSecurityScopedResource()
            self.resource = nil
            self.containerStatus = .blocked(status: error as NSError)
            return replyHandler(nil, error)
        }
    }

    ///  Performs an operation to unload a resource.
    /// - Parameters:
    ///   - resource: The resource to unload.
    ///   - options: The options to use when unloading the resource.
    ///   - replyHandler: The handler to call when unload is complete.
    public func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.passthroughfs.error("\(#function): Can't cast resource")
            return reply(POSIXError(.EINVAL))
        }
        guard let loadedResource = self.resource else {
            Logger.passthroughfs.error("\(#function): No resource was loaded")
            return reply(POSIXError(.EINVAL))
        }
        guard loadedResource.url == urlResource.url else {
            Logger.passthroughfs.error("\(#function): Invalid resource was given to unload")
            return reply(POSIXError(.EINVAL))
        }
        loadedResource.url.stopAccessingSecurityScopedResource()
        self.resource = nil
        return reply(nil)
    }

    /// Performs a probe operation on a resource.
    /// - Parameters:
    ///   - resource: The resource to probe.
    ///   - replyHandler: The handler to call when the probe operation is complete.
    public func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.passthroughfs.debug("\(#function): Can't cast resource")
            return replyHandler(nil, POSIXError(.ENODEV))
        }

        guard urlResource.url.startAccessingSecurityScopedResource() else {
            Logger.passthroughfs.error("\(#function): Can't start accessing security scoped resource")
            return replyHandler(nil, POSIXError(.EACCES))
        }
        defer { urlResource.url.stopAccessingSecurityScopedResource() }

        do {
            let identity = try PassthroughFSVolume.validatedSourceIdentity(
                rootPath: urlResource.url.path
            )
            let name = createVolumeNameFromPath(urlResource.url.path())
            let containerIdentifier = FSContainerIdentifier(
                uuid: identity.mountSessionID
            )
            return replyHandler(
                FSProbeResult.usable(
                    name: name.string ?? "",
                    containerID: containerIdentifier
                ),
                nil
            )
        } catch {
            Logger.passthroughfs.error("\(#function): Resource identity validation failed: \(error)")
            return replyHandler(nil, error)
        }
    }

}
