import DeltaCore
import Foundation

enum DeltaAgentMain {
    static func run() -> Int32 {
        do {
            switch try DeltaAgentInvocation.command(arguments: Array(CommandLine.arguments.dropFirst())) {
            case .status:
                print("DeltaAgent ready")
                return 0
            case .dryRun:
                print("DeltaAgent ready; dry run did not start scheduled backups.")
                return 0
            case .runDueBackups:
                return execMainAppForDueBackups()
            }
        } catch let error as DeltaAgentArgumentError {
            fputs("DeltaAgent error: \(error.localizedDescription)\n", stderr)
            return 64
        } catch {
            fputs("DeltaAgent error: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func execMainAppForDueBackups() -> Int32 {
        let deltaURL = mainAppURL()
        var arguments: [UnsafeMutablePointer<CChar>?] = [
            strdup(deltaURL.path),
            strdup("--run-due-backups"),
            nil
        ]
        defer {
            for argument in arguments where argument != nil {
                free(argument)
            }
        }

        execv(deltaURL.path, &arguments)
        perror("DeltaAgent exec")
        return 1
    }

    private static func mainAppURL() -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let bundledMainApp = LaunchAgentBundleLayout.mainAppExecutableURL(forAgentExecutableURL: executable)
        if FileManager.default.isExecutableFile(atPath: bundledMainApp.path) {
            return bundledMainApp
        }
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("Delta")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "Delta") {
            return bundled
        }
        return URL(fileURLWithPath: "/usr/bin/false")
    }
}

exit(DeltaAgentMain.run())
