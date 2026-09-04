import Foundation

/// Privileged runner for the two exact `pmset -a disablesleep` commands.
enum PrivilegedPmsetRunner {
    enum RunnerError: LocalizedError {
        case privilegeMissing
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .privilegeMissing:
                return "Admin approval is needed to stay awake with the lid closed."
            case .commandFailed(let message):
                return message
            }
        }
    }

    static func setSleepDisabled(_ disabled: Bool) throws {
        guard PmsetPrivilegeInstaller.isInstalled else {
            throw RunnerError.privilegeMissing
        }

        let flag = disabled ? "1" : "0"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", flag]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RunnerError.commandFailed(message?.isEmpty == false ? message! : "pmset disablesleep failed")
        }
    }

    /// User-level display blank (no root). Used when lid closes under Bag Mode.
    static func sleepDisplayNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    /// Reads current SleepDisabled from `pmset -g`.
    static func isSleepDisabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SleepDisabled") {
                return trimmed.contains("1")
            }
        }
        return false
    }
}
