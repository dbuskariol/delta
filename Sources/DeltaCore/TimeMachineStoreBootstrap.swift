import CommonCrypto
import CryptoKit
import Darwin
import DeltaSecurity
import Foundation
import Security

public enum TimeMachineStoreBootstrapError: Error, Equatable, LocalizedError {
    case invalidPassword
    case invalidManifestKey
    case invalidBootstrap
    case unsupportedFormat
    case authenticationFailed
    case existingStore(UUID)
    case conflictingRecoveryRecord
    case keyDerivationFailed(Int32)
    case randomGenerationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidPassword:
            "The Time Machine recovery password is empty."
        case .invalidManifestKey:
            "Delta's Time Machine manifest key is missing or invalid."
        case .invalidBootstrap:
            "The remote Time Machine recovery record is invalid."
        case .unsupportedFormat:
            "This remote Time Machine recovery record uses an unsupported format."
        case .authenticationFailed:
            "The recovery password is incorrect, or the remote Time Machine recovery record was changed."
        case let .existingStore(storeID):
            "This location already contains Delta Time Machine disk \(storeID.uuidString). Reconnect the existing disk instead of creating a new one."
        case .conflictingRecoveryRecord:
            "The remote Time Machine recovery record does not match this destination's saved encryption material."
        case let .keyDerivationFailed(status):
            "Delta could not derive the Time Machine recovery key (status \(status))."
        case let .randomGenerationFailed(status):
            "Delta could not generate secure Time Machine recovery material (status \(status))."
        }
    }
}

public struct TimeMachineRecoveredStore: Equatable, Sendable {
    public var bootstrap: TimeMachineStoreBootstrap
    public var manifestKey: Data

    public init(bootstrap: TimeMachineStoreBootstrap, manifestKey: Data) {
        self.bootstrap = bootstrap
        self.manifestKey = manifestKey
    }
}

public struct TimeMachineStoreBootstrapStore: Sendable {
    private static let maximumBootstrapBytes = 65_536

    public var transport: AnyTimeMachineRemoteObjectTransport

    public init(transport: AnyTimeMachineRemoteObjectTransport) {
        self.transport = transport
    }

    /// Creates the immutable recovery record, or proves an existing retry is
    /// byte-for-byte compatible with the same store and manifest key.
    public func prepare(
        settings: TimeMachineRepositorySettings,
        password: String,
        manifestKey: Data
    ) throws -> TimeMachineStoreBootstrap {
        if let existing = try readIfPresent() {
            return try validatePreparedStore(
                existing,
                settings: settings,
                password: password,
                manifestKey: manifestKey
            )
        }

        let candidate = try TimeMachineStoreBootstrap.create(
            settings: settings,
            password: password,
            manifestKey: manifestKey
        )
        let candidateData = try TimeMachineStoreBootstrap.canonicalEncoder.encode(candidate)
        do {
            try transport.writeObjectIfAbsent(
                candidateData,
                at: TimeMachineStoreBootstrap.objectPath
            )
        } catch TimeMachineObjectStoreError.objectAlreadyExists {
            // A concurrent creator won. The authenticated read-back below must
            // prove it is the same store before this preparation may continue.
        }
        let persisted = try readRequired()
        return try validatePreparedStore(
            persisted,
            settings: settings,
            password: password,
            manifestKey: manifestKey
        )
    }

    public func recover(password: String) throws -> TimeMachineRecoveredStore {
        let bootstrap = try readRequired()
        return TimeMachineRecoveredStore(
            bootstrap: bootstrap,
            manifestKey: try bootstrap.unwrapManifestKey(password: password)
        )
    }

    public func discover() throws -> TimeMachineStoreBootstrap {
        let bootstrap = try readRequired()
        try bootstrap.validate()
        return bootstrap
    }

    private func validatePreparedStore(
        _ bootstrap: TimeMachineStoreBootstrap,
        settings: TimeMachineRepositorySettings,
        password: String,
        manifestKey: Data
    ) throws -> TimeMachineStoreBootstrap {
        guard bootstrap.storeID == settings.storeID else {
            throw TimeMachineStoreBootstrapError.existingStore(bootstrap.storeID)
        }
        guard
            bootstrap.remoteNamespace == settings.remoteNamespace,
            bootstrap.volumeName == settings.volumeName,
            bootstrap.imageCapacityBytes == settings.imageCapacityBytes,
            bootstrap.chunkSizeBytes == TimeMachineRepositorySettings.chunkSizeBytes,
            Self.constantTimeEqual(
                try bootstrap.unwrapManifestKey(password: password),
                manifestKey
            )
        else {
            throw TimeMachineStoreBootstrapError.conflictingRecoveryRecord
        }
        return bootstrap
    }

    private func readIfPresent() throws -> TimeMachineStoreBootstrap? {
        do {
            return try decode(
                transport.readObject(at: TimeMachineStoreBootstrap.objectPath)
            )
        } catch TimeMachineObjectStoreError.objectNotFound {
            return nil
        }
    }

    private func readRequired() throws -> TimeMachineStoreBootstrap {
        try decode(transport.readObject(at: TimeMachineStoreBootstrap.objectPath))
    }

    private func decode(_ data: Data) throws -> TimeMachineStoreBootstrap {
        guard data.count <= Self.maximumBootstrapBytes else {
            throw TimeMachineStoreBootstrapError.invalidBootstrap
        }
        do {
            return try TimeMachineStoreBootstrap.canonicalDecoder.decode(
                TimeMachineStoreBootstrap.self,
                from: data
            )
        } catch {
            throw TimeMachineStoreBootstrapError.invalidBootstrap
        }
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

/// Immutable, discoverable metadata needed to reconnect an existing remote
/// Time Machine store. The random manifest key is never stored remotely in
/// plaintext; it is wrapped by a password-derived key and authenticated with
/// every recovery-critical metadata field as AES-GCM additional data.
public struct TimeMachineStoreBootstrap: Codable, Equatable, Sendable {
    public static let objectPath = "delta-time-machine/bootstrap-v1.json"
    public static let formatIdentifier = "com.delta.backup.time-machine-store"
    public static let formatVersion = 1
    public static let keyDerivationAlgorithm = "PBKDF2-HMAC-SHA256"
    public static let keyDerivationIterations: UInt32 = 600_000
    public static let keyWrapAlgorithm = "AES-256-GCM"

    private static let maximumAcceptedIterations: UInt32 = 10_000_000
    private static let saltByteCount = 16
    private static let manifestKeyByteCount = 32
    private static let derivedKeyByteCount = 32

    public var format: String
    public var version: Int
    public var storeID: UUID
    public var remoteNamespace: String
    public var volumeName: String
    public var imageCapacityBytes: Int64
    public var chunkSizeBytes: Int
    public var createdAt: Date
    public var kdfAlgorithm: String
    public var kdfIterations: UInt32
    public var kdfSalt: Data
    public var wrapAlgorithm: String
    public var wrappedManifestKey: Data

    private struct AuthenticatedMetadata: Codable {
        var format: String
        var version: Int
        var storeID: UUID
        var remoteNamespace: String
        var volumeName: String
        var imageCapacityBytes: Int64
        var chunkSizeBytes: Int
        var createdAt: Date
        var kdfAlgorithm: String
        var kdfIterations: UInt32
        var kdfSalt: Data
        var wrapAlgorithm: String
    }

    public static func create(
        settings: TimeMachineRepositorySettings,
        password: String,
        manifestKey: Data,
        createdAt: Date = Date()
    ) throws -> TimeMachineStoreBootstrap {
        guard
            !password.isEmpty,
            password.utf8.count <= TimeMachineRepositorySettings.maximumDiskPasswordBytes
        else {
            throw TimeMachineStoreBootstrapError.invalidPassword
        }
        guard manifestKey.count == manifestKeyByteCount else {
            throw TimeMachineStoreBootstrapError.invalidManifestKey
        }
        let salt = try secureRandomData(count: saltByteCount)
        let metadata = AuthenticatedMetadata(
            format: formatIdentifier,
            version: formatVersion,
            storeID: settings.storeID,
            remoteNamespace: settings.remoteNamespace,
            volumeName: settings.volumeName,
            imageCapacityBytes: settings.imageCapacityBytes,
            chunkSizeBytes: TimeMachineRepositorySettings.chunkSizeBytes,
            createdAt: TimeMachineWireDate.canonical(createdAt),
            kdfAlgorithm: keyDerivationAlgorithm,
            kdfIterations: keyDerivationIterations,
            kdfSalt: salt,
            wrapAlgorithm: keyWrapAlgorithm
        )
        let wrappingKey = try deriveWrappingKey(
            password: password,
            salt: salt,
            iterations: keyDerivationIterations
        )
        let sealed = try AES.GCM.seal(
            manifestKey,
            using: wrappingKey,
            authenticating: try canonicalEncoder.encode(metadata)
        )
        guard let combined = sealed.combined else {
            throw TimeMachineStoreBootstrapError.invalidBootstrap
        }
        return TimeMachineStoreBootstrap(
            format: metadata.format,
            version: metadata.version,
            storeID: metadata.storeID,
            remoteNamespace: metadata.remoteNamespace,
            volumeName: metadata.volumeName,
            imageCapacityBytes: metadata.imageCapacityBytes,
            chunkSizeBytes: metadata.chunkSizeBytes,
            createdAt: metadata.createdAt,
            kdfAlgorithm: metadata.kdfAlgorithm,
            kdfIterations: metadata.kdfIterations,
            kdfSalt: metadata.kdfSalt,
            wrapAlgorithm: metadata.wrapAlgorithm,
            wrappedManifestKey: combined
        )
    }

    public func unwrapManifestKey(password: String) throws -> Data {
        guard
            !password.isEmpty,
            password.utf8.count <= TimeMachineRepositorySettings.maximumDiskPasswordBytes
        else {
            throw TimeMachineStoreBootstrapError.invalidPassword
        }
        let metadata = try validatedMetadata()
        let wrappingKey = try Self.deriveWrappingKey(
            password: password,
            salt: metadata.kdfSalt,
            iterations: metadata.kdfIterations
        )
        do {
            let sealed = try AES.GCM.SealedBox(combined: wrappedManifestKey)
            let key = try AES.GCM.open(
                sealed,
                using: wrappingKey,
                authenticating: try Self.canonicalEncoder.encode(metadata)
            )
            guard key.count == Self.manifestKeyByteCount else {
                throw TimeMachineStoreBootstrapError.invalidManifestKey
            }
            return key
        } catch let error as TimeMachineStoreBootstrapError {
            throw error
        } catch {
            throw TimeMachineStoreBootstrapError.authenticationFailed
        }
    }

    public func validate() throws {
        _ = try validatedMetadata()
    }

    public func recoveredSettings(cacheLimitBytes: Int64) throws -> TimeMachineRepositorySettings {
        _ = try validatedMetadata()
        return TimeMachineRepositorySettings(
            storeID: storeID,
            volumeName: volumeName,
            imageCapacityBytes: imageCapacityBytes,
            cacheLimitBytes: cacheLimitBytes
        )
    }

    private func validatedMetadata() throws -> AuthenticatedMetadata {
        guard
            format == Self.formatIdentifier,
            version == Self.formatVersion,
            kdfAlgorithm == Self.keyDerivationAlgorithm,
            wrapAlgorithm == Self.keyWrapAlgorithm
        else {
            throw TimeMachineStoreBootstrapError.unsupportedFormat
        }
        guard
            remoteNamespace == TimeMachineRepositorySettings(
                storeID: storeID,
                volumeName: volumeName,
                imageCapacityBytes: imageCapacityBytes
            ).remoteNamespace,
            TimeMachineRepositorySettings.normalizedVolumeName(volumeName) == volumeName,
            imageCapacityBytes >= TimeMachineRepositorySettings.minimumImageCapacityBytes,
            imageCapacityBytes <= TimeMachineRepositorySettings.maximumImageCapacityBytes,
            chunkSizeBytes == TimeMachineRepositorySettings.chunkSizeBytes,
            kdfIterations >= Self.keyDerivationIterations,
            kdfIterations <= Self.maximumAcceptedIterations,
            (16...64).contains(kdfSalt.count),
            (Self.manifestKeyByteCount + 28...Self.manifestKeyByteCount + 32)
                .contains(wrappedManifestKey.count)
        else {
            throw TimeMachineStoreBootstrapError.invalidBootstrap
        }
        return AuthenticatedMetadata(
            format: format,
            version: version,
            storeID: storeID,
            remoteNamespace: remoteNamespace,
            volumeName: volumeName,
            imageCapacityBytes: imageCapacityBytes,
            chunkSizeBytes: chunkSizeBytes,
            createdAt: TimeMachineWireDate.canonical(createdAt),
            kdfAlgorithm: kdfAlgorithm,
            kdfIterations: kdfIterations,
            kdfSalt: kdfSalt,
            wrapAlgorithm: wrapAlgorithm
        )
    }

    private static func deriveWrappingKey(
        password: String,
        salt: Data,
        iterations: UInt32
    ) throws -> SymmetricKey {
        let passwordBytes = Data(password.utf8)
        guard !passwordBytes.isEmpty else {
            throw TimeMachineStoreBootstrapError.invalidPassword
        }
        var derived = [UInt8](repeating: 0, count: derivedKeyByteCount)
        defer {
            derived.withUnsafeMutableBytes { bytes in
                if let address = bytes.baseAddress {
                    DeltaSecureZero(address, bytes.count)
                }
            }
        }
        let status: Int32 = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    UInt32(kCCPBKDF2),
                    passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                    passwordBuffer.count,
                    saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    saltBuffer.count,
                    UInt32(kCCPRFHmacAlgSHA256),
                    iterations,
                    &derived,
                    derived.count
                )
            }
        }
        guard status == kCCSuccess else {
            throw TimeMachineStoreBootstrapError.keyDerivationFailed(status)
        }
        return SymmetricKey(data: derived)
    }

    private static func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw TimeMachineStoreBootstrapError.randomGenerationFailed(status)
        }
        return data
    }

    public static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    public static let canonicalDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
