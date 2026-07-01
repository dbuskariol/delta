import DeltaCore
import Foundation

enum DeltaAgentMain {
    static func run() -> Int32 {
        do {
            let database = try DeltaDatabase.live()
            let coordinator = BackupCoordinator(
                database: database,
                commandBuilder: ResticCommandBuilder(
                    resticExecutableURL: ResticExecutableLocator().locate(),
                    secretBridgeURL: secretBridgeURL()
                )
            )

            if CommandLine.arguments.contains("--status") {
                print("DeltaAgent ready")
                return 0
            }

            let runs = try coordinator.runDueBackups()
            print("DeltaAgent completed \(runs.count) due backup run(s).")
            return runs.contains(where: { $0.status == .failed }) ? 1 : 0
        } catch {
            fputs("DeltaAgent error: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func secretBridgeURL() -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("DeltaSecretBridge")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "DeltaSecretBridge") {
            return bundled
        }
        return URL(fileURLWithPath: "/usr/bin/false")
    }
}

exit(DeltaAgentMain.run())
