import XCTest
@testable import DeltaCore

final class ExternalBackendAcceptanceContractTests: XCTestCase {
    func testKindParsingCoversEveryConfiguredExternalBackend() throws {
        let expected: [AcceptanceExternalKind] = [
            .mounted,
            .sftp,
            .rest,
            .s3,
            .b2,
            .azure,
            .gcs,
            .swift,
            .rclone,
            .custom
        ]

        XCTAssertEqual(AcceptanceExternalKind.allCases, expected)
        for kind in expected {
            XCTAssertEqual(try AcceptanceExternalKind(environmentValue: "  \(kind.rawValue)  "), kind)
            XCTAssertFalse(kind.displayName.isEmpty)
        }

        XCTAssertThrowsError(try AcceptanceExternalKind(environmentValue: "webdav")) { error in
            XCTAssertEqual(
                error as? ExternalBackendAcceptanceError,
                .validationFailed("DELTA_EXTERNAL_ACCEPTANCE_KIND must be mounted, sftp, rest, s3, b2, azure, gcs, swift, rclone, or custom.")
            )
        }
    }

    func testBackendParsingCoversEveryExternalResticBackendFamily() throws {
        let mounted = try AcceptanceExternalKind.mounted.backend(environment: [
            "DELTA_ACCEPTANCE_MOUNTED_REPOSITORY_PATH": "/Volumes/DeltaNAS/repository"
        ])
        XCTAssertEqual(mounted, .local(path: "/Volumes/DeltaNAS/repository"))

        let sftp = try AcceptanceExternalKind.sftp.backend(environment: [
            "DELTA_ACCEPTANCE_SFTP_REPOSITORY": "sftp:backup@example.com:/srv/delta",
            "DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY": "/Users/me/.ssh/delta_ed25519"
        ])
        XCTAssertEqual(
            sftp,
            .sftp(
                host: "example.com",
                path: "/srv/delta",
                username: "backup",
                port: nil,
                identityFilePath: "/Users/me/.ssh/delta_ed25519"
            )
        )

        let sftpURL = try AcceptanceExternalKind.sftp.backend(environment: [
            "DELTA_ACCEPTANCE_SFTP_REPOSITORY": "sftp://backup@example.com:2222//srv/delta"
        ])
        XCTAssertEqual(
            sftpURL,
            .sftp(
                host: "example.com",
                path: "/srv/delta",
                username: "backup",
                port: 2222,
                identityFilePath: nil
            )
        )

        XCTAssertEqual(
            try AcceptanceExternalKind.rest.backend(environment: [
                "DELTA_ACCEPTANCE_REST_REPOSITORY": "rest:https://rest.example.com/delta"
            ]),
            .rest(url: "https://rest.example.com/delta")
        )

        XCTAssertEqual(
            try AcceptanceExternalKind.s3.backend(environment: [
                "DELTA_ACCEPTANCE_S3_REPOSITORY": "s3:https://s3.example.com:9443/delta/mac",
                "AWS_DEFAULT_REGION": "us-east-1"
            ]),
            .s3(endpoint: "https://s3.example.com:9443", bucket: "delta", path: "mac", region: "us-east-1")
        )

        XCTAssertEqual(
            try AcceptanceExternalKind.b2.backend(environment: [
                "DELTA_ACCEPTANCE_B2_REPOSITORY": "b2:delta-bucket:/mac"
            ]),
            .backblazeB2(bucket: "delta-bucket", path: "mac")
        )
        XCTAssertEqual(
            try AcceptanceExternalKind.azure.backend(environment: [
                "DELTA_ACCEPTANCE_AZURE_REPOSITORY": "azure:delta-container:/mac"
            ]),
            .azureBlob(container: "delta-container", path: "mac")
        )
        XCTAssertEqual(
            try AcceptanceExternalKind.gcs.backend(environment: [
                "DELTA_ACCEPTANCE_GCS_REPOSITORY": "gs:delta-bucket:/mac"
            ]),
            .googleCloudStorage(bucket: "delta-bucket", path: "mac")
        )
        XCTAssertEqual(
            try AcceptanceExternalKind.swift.backend(environment: [
                "DELTA_ACCEPTANCE_SWIFT_REPOSITORY": "swift:delta-container:/mac"
            ]),
            .swiftObjectStorage(container: "delta-container", path: "mac")
        )
        XCTAssertEqual(
            try AcceptanceExternalKind.rclone.backend(environment: [
                "DELTA_ACCEPTANCE_RCLONE_REPOSITORY": "rclone:deltaRemote:mac"
            ]),
            .rclone(remote: "deltaRemote", path: "mac")
        )
        XCTAssertEqual(
            try AcceptanceExternalKind.custom.backend(environment: [
                "DELTA_ACCEPTANCE_CUSTOM_REPOSITORY": "rest:https://backup.example.com/custom"
            ]),
            .custom(repository: "rest:https://backup.example.com/custom")
        )
    }

    func testBackendParsingRejectsUnsafeOrMalformedAcceptanceTargets() {
        assertAcceptanceError(
            { try AcceptanceExternalKind.mounted.backend(environment: ["DELTA_ACCEPTANCE_MOUNTED_REPOSITORY_PATH": "/tmp/delta"]) },
            "Mounted acceptance repository must live under /Volumes."
        )
        assertAcceptanceError(
            { try AcceptanceExternalKind.sftp.backend(environment: ["DELTA_ACCEPTANCE_SFTP_REPOSITORY": "sftp:example.com:relative"]) },
            "SFTP acceptance repository must include an absolute path."
        )
        assertAcceptanceError(
            { try AcceptanceExternalKind.rest.backend(environment: ["DELTA_ACCEPTANCE_REST_REPOSITORY": "file:///tmp/repo"]) },
            "REST acceptance repository must be rest:https://host/path or https://host/path."
        )
        assertAcceptanceError(
            { try AcceptanceExternalKind.s3.backend(environment: ["DELTA_ACCEPTANCE_S3_REPOSITORY": "s3:delta/mac"]) },
            "S3 acceptance repository must include an endpoint URL, bucket, and path."
        )
        assertAcceptanceError(
            { try AcceptanceExternalKind.b2.backend(environment: ["DELTA_ACCEPTANCE_B2_REPOSITORY": "b2::mac"]) },
            "Backblaze B2 acceptance repository bucket/container is empty."
        )
        assertAcceptanceError(
            { try AcceptanceExternalKind.rclone.backend(environment: ["DELTA_ACCEPTANCE_RCLONE_REPOSITORY": "rclone:remoteOnly"]) },
            "rclone acceptance repository must be rclone:remote:path."
        )
    }

    func testCredentialPolicyRequiresProviderMinimumsAndKeepsOptionalKeys() throws {
        XCTAssertEqual(
            try AcceptanceExternalKind.rest.credentials(environment: [
                "RESTIC_REST_USERNAME": "user",
                "RESTIC_REST_PASSWORD": "pass"
            ]),
            [
                "RESTIC_REST_USERNAME": "user",
                "RESTIC_REST_PASSWORD": "pass"
            ]
        )

        assertAcceptanceError(
            { try AcceptanceExternalKind.s3.credentials(environment: ["AWS_ACCESS_KEY_ID": "id"]) },
            "AWS_SECRET_ACCESS_KEY is required."
        )
        XCTAssertEqual(
            try AcceptanceExternalKind.s3.credentials(environment: [
                "AWS_ACCESS_KEY_ID": "id",
                "AWS_SECRET_ACCESS_KEY": "secret",
                "AWS_SESSION_TOKEN": "session",
                "UNRELATED": "ignored"
            ]),
            [
                "AWS_ACCESS_KEY_ID": "id",
                "AWS_SECRET_ACCESS_KEY": "secret",
                "AWS_SESSION_TOKEN": "session"
            ]
        )

        assertAcceptanceError(
            { try AcceptanceExternalKind.b2.credentials(environment: ["B2_ACCOUNT_ID": "id"]) },
            "B2_ACCOUNT_KEY is required."
        )
        XCTAssertEqual(
            try AcceptanceExternalKind.b2.credentials(environment: [
                "B2_ACCOUNT_ID": "id",
                "B2_ACCOUNT_KEY": "key"
            ]),
            [
                "B2_ACCOUNT_ID": "id",
                "B2_ACCOUNT_KEY": "key"
            ]
        )

        assertAcceptanceError(
            { try AcceptanceExternalKind.azure.credentials(environment: ["AZURE_ACCOUNT_NAME": "acct"]) },
            "One of AZURE_ACCOUNT_KEY, AZURE_ACCOUNT_SAS is required."
        )
        XCTAssertEqual(
            try AcceptanceExternalKind.azure.credentials(environment: [
                "AZURE_ACCOUNT_NAME": "acct",
                "AZURE_ACCOUNT_SAS": "sas",
                "AZURE_ENDPOINT_SUFFIX": "core.windows.net"
            ]),
            [
                "AZURE_ACCOUNT_NAME": "acct",
                "AZURE_ACCOUNT_SAS": "sas",
                "AZURE_ENDPOINT_SUFFIX": "core.windows.net"
            ]
        )
    }

    func testCredentialPolicyValidatesFileBackedAndMultiModeProviders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-external-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let gcsCredentials = root.appendingPathComponent("gcs.json")
        try "{}".write(to: gcsCredentials, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try AcceptanceExternalKind.gcs.credentials(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS": gcsCredentials.path,
                "GOOGLE_PROJECT_ID": "delta"
            ]),
            [
                "GOOGLE_APPLICATION_CREDENTIALS": gcsCredentials.path,
                "GOOGLE_PROJECT_ID": "delta"
            ]
        )
        XCTAssertEqual(
            try AcceptanceExternalKind.gcs.credentials(environment: [
                "GOOGLE_ACCESS_TOKEN": "token"
            ]),
            [
                "GOOGLE_ACCESS_TOKEN": "token"
            ]
        )
        assertAcceptanceError(
            { try AcceptanceExternalKind.gcs.credentials(environment: ["GOOGLE_APPLICATION_CREDENTIALS": root.appendingPathComponent("missing.json").path]) },
            "GOOGLE_APPLICATION_CREDENTIALS is not readable: \(root.appendingPathComponent("missing.json").path)"
        )

        XCTAssertEqual(
            try AcceptanceExternalKind.swift.credentials(environment: [
                "ST_AUTH": "https://swift.example.com/auth",
                "ST_USER": "tenant:user",
                "ST_KEY": "key"
            ]),
            [
                "ST_AUTH": "https://swift.example.com/auth",
                "ST_USER": "tenant:user",
                "ST_KEY": "key"
            ]
        )
        XCTAssertEqual(
            try AcceptanceExternalKind.swift.credentials(environment: [
                "OS_AUTH_URL": "https://identity.example.com/v3",
                "OS_USERNAME": "delta",
                "OS_PASSWORD": "password",
                "OS_PROJECT_NAME": "backups"
            ]),
            [
                "OS_AUTH_URL": "https://identity.example.com/v3",
                "OS_USERNAME": "delta",
                "OS_PASSWORD": "password",
                "OS_PROJECT_NAME": "backups"
            ]
        )
        XCTAssertEqual(
            try AcceptanceExternalKind.swift.credentials(environment: [
                "OS_AUTH_URL": "https://identity.example.com/v3",
                "OS_APPLICATION_CREDENTIAL_NAME": "delta",
                "OS_APPLICATION_CREDENTIAL_SECRET": "secret"
            ]),
            [
                "OS_AUTH_URL": "https://identity.example.com/v3",
                "OS_APPLICATION_CREDENTIAL_NAME": "delta",
                "OS_APPLICATION_CREDENTIAL_SECRET": "secret"
            ]
        )
        assertAcceptanceError(
            { try AcceptanceExternalKind.swift.credentials(environment: ["OS_AUTH_URL": "https://identity.example.com/v3"]) },
            "OpenStack Swift acceptance requires ST_AUTH/ST_USER/ST_KEY, OS_STORAGE_URL/OS_AUTH_TOKEN, Keystone password auth, or Keystone application credential auth."
        )

        let rcloneConfig = root.appendingPathComponent("rclone.conf")
        try "[delta]\ntype = local\n".write(to: rcloneConfig, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try AcceptanceExternalKind.rclone.credentials(environment: [
                "RCLONE_CONFIG": rcloneConfig.path
            ]),
            [
                "RCLONE_CONFIG": rcloneConfig.path
            ]
        )
        assertAcceptanceError(
            { try AcceptanceExternalKind.rclone.credentials(environment: ["RCLONE_CONFIG": root.appendingPathComponent("missing.conf").path]) },
            "RCLONE_CONFIG is not readable: \(root.appendingPathComponent("missing.conf").path)"
        )
    }

    func testCustomCredentialPolicyRequiresDeclaredKeysOnly() throws {
        XCTAssertEqual(
            try AcceptanceExternalKind.custom.credentials(environment: [
                "DELTA_ACCEPTANCE_CUSTOM_CREDENTIAL_KEYS": "TOKEN, USER ",
                "TOKEN": "secret-token",
                "USER": "delta",
                "PASSWORD": "ignored"
            ]),
            [
                "TOKEN": "secret-token",
                "USER": "delta"
            ]
        )

        assertAcceptanceError(
            {
                try AcceptanceExternalKind.custom.credentials(environment: [
                    "DELTA_ACCEPTANCE_CUSTOM_CREDENTIAL_KEYS": "TOKEN, USER",
                    "TOKEN": "secret-token"
                ])
            },
            "USER is required."
        )
    }

    private func assertAcceptanceError(
        _ expression: () throws -> Any,
        _ expectedMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? ExternalBackendAcceptanceError,
                .validationFailed(expectedMessage),
                file: file,
                line: line
            )
        }
    }
}
