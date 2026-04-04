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

        let derivedDataPath = derivedDataURL(for: project)
        try? FileManager.default.createDirectory(at: derivedDataPath, withIntermediateDirectories: true)

        append("=== xcodebuild ===\n")
        let buildResult: (output: String, exitCode: Int32)
        do {
            buildResult = try await run([
                "xcodebuild",
                "-project", project.projectPath.path,
                "-scheme", project.name,
                "-destination", "generic/platform=iOS",
                "-derivedDataPath", derivedDataPath.path,
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

        let appPath = derivedDataPath
            .appendingPathComponent("Build/Products/Debug-iphoneos/\(project.name).app")

        guard FileManager.default.fileExists(atPath: appPath.path) else {
            return (.failure(phase: .xcodebuild, message: "Build succeeded but .app bundle not found at expected path."), fullLog.value)
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

    private static func derivedDataURL(for project: ManagedProject) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("ReSign/DerivedData/\(project.name)", isDirectory: true)
    }

    private static func classifyBuildError(_ output: String) -> String {
        if output.contains("SIGNING") || output.contains("provisioning") {
            return "Signing error. Open Xcode and verify your team is selected."
        }
        if output.contains("Build input file cannot be found") {
            return "Source file missing. Check the project in Xcode."
        }
        // Extract last error: line
        let lines = output.components(separatedBy: "\n")
        if let errorLine = lines.last(where: { $0.contains("error:") }) {
            return String(errorLine.prefix(200))
        }
        return "Build failed. Check logs for details."
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
