import Foundation

enum BuildRunner {
    static func build(
        project: ManagedProject,
        preferredDeviceID: String? = nil,
        onOutput: @Sendable @escaping (String) -> Void = { _ in }
    ) async -> (result: BuildResult, log: String) {
        let fullLog = OutputAccumulator()

        let append: @Sendable (String) -> Void = { text in
            fullLog.append(text)
            onOutput(text)
        }

        // Phase 1: Find device
        append("=== Device Discovery ===\n")
        let device: DeviceInfo
        do {
            try Task.checkCancellation()
            device = try await DeviceLocator.findDevice(preferredID: preferredDeviceID)
            append("Device: \(device.name) (\(device.id))\n\n")
        } catch is CancellationError {
            return (.cancelled, fullLog.value)
        } catch {
            return (.failure(phase: .deviceNotFound, message: error.localizedDescription), fullLog.value)
        }

        // Phase 2: xcodebuild
        do {
            try Task.checkCancellation()
        } catch {
            return (.cancelled, fullLog.value)
        }

        append("=== xcodebuild ===\n")
        let buildResult: (output: String, exitCode: Int32)
        do {
            buildResult = try await run([
                "xcodebuild",
                "-project", project.projectPath.path,
                "-scheme", project.name,
                "-destination", "generic/platform=iOS",
                "-allowProvisioningUpdates",
                "clean", "build"
            ], onOutput: append)
        } catch is CancellationError {
            return (.cancelled, fullLog.value)
        } catch {
            return (.cancelled, fullLog.value)
        }

        guard buildResult.exitCode == 0 else {
            return (.failure(phase: .xcodebuild, message: classifyBuildError(buildResult.output)), fullLog.value)
        }

        guard let appPath = findAppBundle(in: buildResult.output, projectName: project.name) else {
            return (.failure(phase: .xcodebuild, message: "Build succeeded but .app bundle not found. Check build log for the output path."), fullLog.value)
        }

        // Phase 3: Install
        do {
            try Task.checkCancellation()
        } catch {
            return (.cancelled, fullLog.value)
        }

        append("=== Install ===\n")
        let installResult: (output: String, exitCode: Int32)
        do {
            installResult = try await run([
                "xcrun", "devicectl", "device", "install", "app",
                "--device", device.id,
                appPath.path
            ], onOutput: append)
        } catch is CancellationError {
            return (.cancelled, fullLog.value)
        } catch {
            return (.cancelled, fullLog.value)
        }

        guard installResult.exitCode == 0 else {
            let msg = installResult.output.contains("not found")
                ? "Device lost during install. Make sure your phone stays unlocked."
                : String(installResult.output.suffix(300))
            return (.failure(phase: .deviceInstall, message: msg), fullLog.value)
        }

        // Read actual profile expiration date
        let profileExpiry = readProfileExpiry(appPath: appPath)

        return (.success(appBundlePath: appPath, profileExpiresAt: profileExpiry), fullLog.value)
    }

    // MARK: - Private

    private static func readProfileExpiry(appPath: URL) -> Date? {
        let profilePath = appPath.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: profilePath.path) else { return nil }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = ["cms", "-D", "-i", profilePath.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let expirationDate = plist["ExpirationDate"] as? Date else { return nil }
        return expirationDate
    }

    /// Extracts the .app bundle path from xcodebuild output.
    /// xcodebuild emits a line like: "CODESIGNING_FOLDER_PATH = /path/to/App.app"
    private static func findAppBundle(in output: String, projectName: String) -> URL? {
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            if line.contains("CODESIGNING_FOLDER_PATH") || line.contains("TARGET_BUILD_DIR"),
               let range = line.range(of: "/"),
               line.hasSuffix(".app") || line.contains(".app/") {
                let path = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
                let url = URL(filePath: path)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        // Fallback: search Xcode's default DerivedData for a matching .app
        let xcodeDerivedData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        if let enumerator = FileManager.default.enumerator(
            at: xcodeDerivedData,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == "\(projectName).app",
                   url.pathComponents.contains("iphoneos") {
                    return url
                }
            }
        }
        return nil
    }

    private static func classifyBuildError(_ output: String) -> String {
        if output.contains("No Accounts") {
            return "Not signed in to Xcode. Open Xcode → Settings → Accounts and sign in with your Apple ID, then try again."
        }
        if output.contains("No profiles for") || output.contains("no provisioning profiles") {
            return "No provisioning profile found. Open Xcode, sign in under Settings → Accounts, and build the project once manually to create a profile."
        }
        if output.contains("provisioning profile") && output.contains("expired") {
            return "Provisioning profile expired. Open Xcode → Settings → Accounts → Manage Certificates to renew."
        }
        if output.contains("SIGNING") || output.contains("code sign") || output.contains("CodeSign") {
            return "Code signing failed. Open Xcode, select your team under Signing & Capabilities, and verify the bundle ID matches your profile."
        }
        if output.contains("Build input file cannot be found") {
            return "Source file missing. Check the project for broken file references in Xcode."
        }
        if output.contains("could not find module") {
            return "Missing Swift module or dependency. Try cleaning derived data or resolving packages in Xcode."
        }
        // Extract last error: line
        let lines = output.components(separatedBy: "\n")
        if let errorLine = lines.last(where: { $0.contains("error:") }) {
            return String(errorLine.prefix(200))
        }
        return "Build failed. Check the build log for details."
    }

    private static func run(
        _ arguments: [String],
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Accumulate full output for return value
        let outputAccumulator = OutputAccumulator()

        // Stream stdout in real-time
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            outputAccumulator.append(text)
            onOutput(text)
        }

        // Stream stderr in real-time
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            outputAccumulator.append(text)
            onOutput(text)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { p in
                    // Clean up handlers
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    // Read any remaining data
                    if let remaining = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !remaining.isEmpty {
                        outputAccumulator.append(remaining)
                    }
                    if let remaining = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !remaining.isEmpty {
                        outputAccumulator.append(remaining)
                    }

                    let output = outputAccumulator.value
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: (output: output, exitCode: p.terminationStatus))
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}

/// Thread-safe string accumulator for gathering process output.
private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func append(_ text: String) {
        lock.lock()
        _value += text
        lock.unlock()
    }
}
