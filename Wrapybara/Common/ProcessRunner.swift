import Foundation

/// Runs a command-line tool and collects its output.
///
/// Wrapybara shells out for exactly one thing — `codesign` — because macOS has no
/// public API for creating a code signature. Everything else it does itself.
enum ProcessRunner {

    struct Result {
        var exitCode: Int32
        var standardOutput: String
        var standardError: String

        var succeeded: Bool { exitCode == 0 }

        /// The most useful message the tool produced, for an error dialog.
        var message: String {
            let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if !error.isEmpty { return error }
            let output = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? "exited with code \(exitCode)" : output
        }
    }

    enum RunError: LocalizedError {
        case notExecutable(String)
        case launchFailed(String, underlying: String)
        case timedOut(String, seconds: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .notExecutable(let path):
                return "\(path) isn't available on this Mac."
            case .launchFailed(let path, let underlying):
                return "Couldn't run \(path): \(underlying)"
            case .timedOut(let path, let seconds):
                return "\(path) didn't finish within \(Int(seconds)) seconds."
            }
        }
    }

    /// Runs `executable` with `arguments` and waits for it.
    ///
    /// Reads both pipes concurrently on background queues. Draining them after
    /// `waitUntilExit` instead would deadlock the moment a tool writes more than a
    /// pipe buffer (64 KB) — `codesign --verbose` on a large bundle does.
    static func run(_ executable: String,
                    arguments: [String],
                    timeout: TimeInterval = 120) throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw RunError.notExecutable(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Never let a tool block on stdin waiting for input nobody will type.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(executable, underlying: error.localizedDescription)
        }

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.wrapybara.ProcessRunner", attributes: .concurrent)
        let lock = NSLock()

        for (handle, isStandardOutput) in [(outPipe.fileHandleForReading, true),
                                           (errPipe.fileHandleForReading, false)] {
            group.enter()
            queue.async {
                let data = handle.readDataToEndOfFile()
                lock.lock()
                if isStandardOutput { outData = data } else { errData = data }
                lock.unlock()
                group.leave()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            // Poll rather than `waitUntilExit`, so a wedged tool can be killed
            // instead of hanging the caller forever.
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            throw RunError.timedOut(executable, seconds: timeout)
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 5)

        lock.lock()
        let out = text(from: outData)
        let err = text(from: errData)
        lock.unlock()
        return Result(exitCode: process.terminationStatus, standardOutput: out, standardError: err)
    }

    /// UTF-8 where possible, otherwise a latin-1 read — a tool's diagnostics are
    /// worth showing even when they aren't valid UTF-8, and latin-1 can't fail.
    static func text(from data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }
}
