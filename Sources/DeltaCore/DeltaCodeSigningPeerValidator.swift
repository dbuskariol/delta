import Darwin
import Foundation
import Security

public enum DeltaCodeSigningIdentityError: Error, LocalizedError {
    case unavailable(OSStatus)
    case missingCodeHash
    case missingExecutableURL

    public var errorDescription: String? {
        switch self {
        case let .unavailable(status):
            "Delta could not inspect a required code signature (Security status \(status))."
        case .missingCodeHash:
            "Delta could not identify a required signed executable."
        case .missingExecutableURL:
            "Delta could not locate a required signed executable."
        }
    }
}

public enum DeltaCodeSigningIdentity {
    public static func currentProcessExecutableURL() throws -> URL {
        var dynamicCode: SecCode?
        let selfStatus = SecCodeCopySelf([], &dynamicCode)
        guard selfStatus == errSecSuccess, let dynamicCode else {
            throw DeltaCodeSigningIdentityError.unavailable(selfStatus)
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(dynamicCode, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw DeltaCodeSigningIdentityError.unavailable(staticStatus)
        }
        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            [],
            &information
        )
        guard informationStatus == errSecSuccess else {
            throw DeltaCodeSigningIdentityError.unavailable(informationStatus)
        }
        guard
            let values = information as? [String: Any],
            let executableURL = values[kSecCodeInfoMainExecutable as String] as? URL
        else {
            throw DeltaCodeSigningIdentityError.missingExecutableURL
        }
        return executableURL.standardizedFileURL
    }

    public static func currentProcessCodeHash() throws -> Data {
        var dynamicCode: SecCode?
        let selfStatus = SecCodeCopySelf([], &dynamicCode)
        guard selfStatus == errSecSuccess, let dynamicCode else {
            throw DeltaCodeSigningIdentityError.unavailable(selfStatus)
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(dynamicCode, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw DeltaCodeSigningIdentityError.unavailable(staticStatus)
        }
        return try codeHash(of: staticCode)
    }

    public static func staticCodeHash(at executableURL: URL) throws -> Data {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            [],
            &staticCode
        )
        guard status == errSecSuccess, let staticCode else {
            throw DeltaCodeSigningIdentityError.unavailable(status)
        }
        return try codeHash(of: staticCode)
    }

    private static func codeHash(of code: SecStaticCode) throws -> Data {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(code, [], &information)
        guard status == errSecSuccess else {
            throw DeltaCodeSigningIdentityError.unavailable(status)
        }
        guard
            let values = information as? [String: Any],
            let codeHash = values[kSecCodeInfoUnique as String] as? Data,
            !codeHash.isEmpty,
            codeHash.count <= 64
        else {
            throw DeltaCodeSigningIdentityError.missingCodeHash
        }
        return codeHash
    }
}

public struct DeltaCodeSigningPeerValidator: Sendable {
    private struct IdentityRequirement: Sendable {
        var identifier: String
        var text: String
    }

    private let requirements: [IdentityRequirement]
    private let expectedCodeHashesByIdentifier: [String: Data]

    public init(
        allowedIdentifiers: [String],
        expectedCodeHashesByIdentifier: [String: Data] = [:]
    ) {
        requirements = allowedIdentifiers.map {
            IdentityRequirement(
                identifier: $0,
                text: DeltaCodeSigningRequirement.designated(identifier: $0)
            )
        }
        self.expectedCodeHashesByIdentifier = expectedCodeHashesByIdentifier
    }

    public func validate(auditToken: Data) -> Bool {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else { return false }
        let attributes = [
            kSecGuestAttributeAudit as String: auditToken
        ] as CFDictionary
        var code: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
            let code
        else {
            return false
        }
        for identityRequirement in requirements {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(
                identityRequirement.text as CFString,
                [],
                &requirement
            ) == errSecSuccess, let requirement else {
                continue
            }
            if SecCodeCheckValidity(code, [], requirement) == errSecSuccess {
                guard let expectedCodeHash = expectedCodeHashesByIdentifier[
                    identityRequirement.identifier
                ]
                else {
                    return true
                }
                var staticCode: SecStaticCode?
                guard
                    SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
                    let staticCode
                else {
                    return false
                }
                var information: CFDictionary?
                guard
                    SecCodeCopySigningInformation(staticCode, [], &information)
                        == errSecSuccess,
                    let values = information as? [String: Any],
                    let observedCodeHash = values[kSecCodeInfoUnique as String] as? Data,
                    Self.matches(
                        expectedCodeHash: expectedCodeHash,
                        observedCodeHash: observedCodeHash
                    )
                else {
                    return false
                }
                return true
            }
        }
        return false
    }

    static func matches(
        expectedCodeHash: Data,
        observedCodeHash: Data
    ) -> Bool {
        !expectedCodeHash.isEmpty
            && expectedCodeHash.count <= 64
            && observedCodeHash == expectedCodeHash
    }
}
