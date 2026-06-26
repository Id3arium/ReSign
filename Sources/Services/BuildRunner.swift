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

        // Phase 1.5: If the project root ships a build.sh, prefer it. The script
        // owns build+sign+install (and likely knows project-specific steps like
        // xcodegen). We pass the chosen device so it installs to the right phone,
        // then verify it staged a signed .app we can read expiry from. If the
        // script doesn't produce one (e.g. an old unsigned-IPA script), we fall
        // through to ReSign's own xcodebuild path rather than mis-scheduling.
        if let buildScript = projectBuildScript(for: project) {
            do { try Task.checkCancellation() } catch { return (.cancelled, fullLog.value) }
            if let delegated = await runProjectBuildScript(
                buildScript, project: project, deviceID: device.id, append: append
            ) {
                return (delegated, fullLog.value)
            }
            append("\n(build.sh did not produce a signed .app — falling back to xcodebuild)\n\n")
        }

        // Phase 2: xcodebuild
        do {
            try Task.checkCancellation()
        } catch {
            return (.cancelled, fullLog.value)
        }

        // Use a per-project derived data dir so we know exactly where the .app lands.
        let derivedDataDir = derivedDataDirectory(for: project)
        do {
            try FileManager.default.createDirectory(at: derivedDataDir, withIntermediateDirectories: true)
        } catch {
            return (.failure(phase: .xcodebuild, message: "Could not create build output directory at \(derivedDataDir.path). Check disk permissions."), fullLog.value)
        }

        append("Builder: xcodebuild (built-in)\n")
        append("=== xcodebuild ===\n")
        let buildResult: (output: String, exitCode: Int32)
        do {
            buildResult = try await run([
                "xcodebuild",
                "-project", project.projectPath.path,
                "-scheme", project.name,
                "-configuration", "Debug",
                "-destination", "generic/platform=iOS",
                "-derivedDataPath", derivedDataDir.path,
                "-allowProvisioningUpdates",
                "clean", "build"
            ], onOutput: append)
        } catch is CancellationError {
            return (.cancelled, fullLog.value)
        } catch {
            return (.failure(phase: .xcodebuild, message: error.localizedDescription), fullLog.value)
        }

        guard buildResult.exitCode == 0 else {
            return (.failure(phase: .xcodebuild, message: classifyBuildError(buildResult.output)), fullLog.value)
        }

        let productsDir = derivedDataDir
            .appendingPathComponent("Build/Products/Debug-iphoneos", isDirectory: true)
        guard let appPath = findAppBundle(in: productsDir) else {
            return (.failure(phase: .xcodebuild, message: "Build reported success but no .app was produced at \(productsDir.path). Try building the scheme manually in Xcode to see what's happening."), fullLog.value)
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
            return (.failure(phase: .deviceInstall, message: error.localizedDescription), fullLog.value)
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

    /// An executable `build.sh` at the project repo root (the .xcodeproj's parent
    /// directory), or nil if absent / not executable.
    private static func projectBuildScript(for project: ManagedProject) -> URL? {
        let script = project.projectPath
            .deletingLastPathComponent()
            .appendingPathComponent("build.sh")
        let fm = FileManager.default
        guard fm.fileExists(atPath: script.path),
              fm.isExecutableFile(atPath: script.path) else { return nil }
        return script
    }

    /// Runs the project's build.sh with the target device, then looks for a
    /// signed `build/<Name>.app` it staged. Returns a `.success`/`.failure`
    /// BuildResult if the delegation is conclusive, or nil to signal "fall back
    /// to ReSign's own xcodebuild" (script ran but staged no signed .app).
    private static func runProjectBuildScript(
        _ script: URL,
        project: ManagedProject,
        deviceID: String,
        append: @Sendable @escaping (String) -> Void
    ) async -> BuildResult? {
        append("Builder: build.sh (\(script.path))\n")
        append("=== build.sh ===\n")
        let repoRoot = script.deletingLastPathComponent()

        let result: (output: String, exitCode: Int32)
        do {
            // Pass the chosen device so the script installs to the right phone.
            // Scripts that don't recognize --device should ignore unknown flags;
            // if one hard-fails on it, the staged-.app check below still gates us.
            result = try await run(
                ["bash", script.path, "--device", deviceID],
                cwd: repoRoot,
                onOutput: append
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            // Couldn't even launch the script — fall back to xcodebuild.
            return nil
        }

        // Verify: a build.sh-built app is staged at build/<Name>.app and carries
        // an embedded provisioning profile (i.e. it was actually signed).
        let stagedApp = repoRoot
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("\(project.name).app", isDirectory: true)
        let profile = stagedApp.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: stagedApp.path),
              FileManager.default.fileExists(atPath: profile.path) else {
            // No signed .app to read expiry from — let the caller fall back.
            return nil
        }

        guard result.exitCode == 0 else {
            return .failure(phase: .xcodebuild, message: classifyBuildError(result.output))
        }

        let expiry = readProfileExpiry(appPath: stagedApp)
        return .success(appBundlePath: stagedApp, profileExpiresAt: expiry)
    }

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

    /// Per-project derived data directory. Keyed by project UUID so rebuilds are deterministic
    /// and we don't pollute the user's ~/Library/Developer/Xcode/DerivedData.
    private static func derivedDataDirectory(for project: ManagedProject) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ReSign/DerivedData", isDirectory: true)
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
    }

    /// Finds the built .app inside our controlled products directory.
    /// Picks the most recently modified .app in case multiple targets produced one.
    private static func findAppBundle(in productsDir: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: productsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let apps = entries.filter { $0.pathExtension == "app" }
        return apps.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
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
        cwd: URL? = nil,
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Accumulate full (filtered) output for return value
        let outputAccumulator = OutputAccumulator()

        // Single shared filter instance; it's stateful across chunks (tracks
        // which step header we're inside of). Wrapped for thread-safety since
        // stdout and stderr handlers may fire on different queues.
        let filter = FilterBox()

        let emit: @Sendable (String) -> Void = { raw in
            let compact = filter.feed(raw)
            guard !compact.isEmpty else { return }
            outputAccumulator.append(compact)
            onOutput(compact)
        }

        // Stream stdout in real-time (filtered)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            emit(text)
        }

        // Stream stderr in real-time (filtered)
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            emit(text)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { p in
                    // Clean up handlers
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    // Read any remaining data (filtered)
                    if let remaining = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !remaining.isEmpty {
                        emit(remaining)
                    }
                    if let remaining = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !remaining.isEmpty {
                        emit(remaining)
                    }
                    // Flush any trailing partial line the filter was buffering.
                    let tail = filter.flush()
                    if !tail.isEmpty {
                        outputAccumulator.append(tail)
                        onOutput(tail)
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

/// Thread-safe wrapper around BuildOutputFilter. Pipe readability handlers
/// can fire on different queues (stdout vs stderr), so we serialize access.
private final class FilterBox: @unchecked Sendable {
    private let lock = NSLock()
    private let filter = BuildOutputFilter()

    func feed(_ chunk: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return filter.feed(chunk)
    }

    func flush() -> String {
        lock.lock()
        defer { lock.unlock() }
        return filter.flush()
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
