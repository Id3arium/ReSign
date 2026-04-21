import Foundation

/// Collapses xcodebuild's firehose into a readable log.
///
/// xcodebuild emits ~45KB of build-system bookkeeping per build: WriteAuxiliaryFile,
/// CreateBuildDirectory, full swiftc invocations with 400 flags, etc. Almost none of
/// it helps diagnose a build failure. This filter keeps errors, warnings, notes,
/// phase headers, status banners, signing summaries, and one-line step names — and
/// drops everything else.
///
/// Line-oriented and stateful because xcodebuild emits multi-line blocks: a step
/// header, an indented `cd`, an indented giant command, a blank line. When we
/// drop the header we also drop the trailing continuation lines.
final class BuildOutputFilter {
    private var buffer = ""
    private var droppingContinuation = false
    private var seenSigningIdentities: Set<String> = []

    /// Feeds a chunk of raw xcodebuild output. Returns the compact version,
    /// which may be empty if the chunk contained only noise.
    func feed(_ chunk: String) -> String {
        buffer += chunk
        var output = ""

        // Only process complete lines; keep the trailing partial for next feed.
        while let newlineRange = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)

            if let kept = process(line: line) {
                output += kept + "\n"
            }
        }

        return output
    }

    /// Flush any trailing partial line. Call when the process exits.
    func flush() -> String {
        guard !buffer.isEmpty else { return "" }
        let line = buffer
        buffer = ""
        if let kept = process(line: line) {
            return kept + "\n"
        }
        return ""
    }

    // MARK: - Per-line logic

    private func process(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Always keep blank separator lines between kept content, but not
        // the ones padding dropped blocks.
        if trimmed.isEmpty {
            if droppingContinuation { return nil }
            return ""
        }

        // If we just dropped a step header, its indented continuation lines
        // (starting with whitespace) belong to it — drop them too. The block
        // ends when we hit a non-indented line.
        if droppingContinuation {
            if line.first?.isWhitespace == true { return nil }
            droppingContinuation = false
            // fall through to evaluate this line fresh
        }

        // Always-keep patterns (high-signal): errors, warnings, notes, banners,
        // our own phase markers, signing metadata, install results.
        if shouldAlwaysKeep(trimmed) {
            // Dedup signing identity lines — they appear 3× per build.
            if trimmed.hasPrefix("Signing Identity:") {
                if seenSigningIdentities.contains(trimmed) { return nil }
                seenSigningIdentities.insert(trimmed)
            }
            return line
        }

        // Collapse SwiftCompile to a single-line summary (drop its command).
        if trimmed.hasPrefix("SwiftCompile normal ") {
            droppingContinuation = true
            return summarizeSwiftCompile(trimmed)
        }

        // Drop noisy step headers and their continuation blocks.
        if shouldDropAsStepHeader(trimmed) {
            droppingContinuation = true
            return nil
        }

        // Unknown content at column 0 that isn't recognized noise — keep it.
        // Better to let an occasional odd line through than swallow a real error.
        if line.first?.isWhitespace != true {
            return line
        }

        // Indented orphan — drop.
        return nil
    }

    private func shouldAlwaysKeep(_ trimmed: String) -> Bool {
        // Error / warning / note lines from the compiler and linker.
        if trimmed.contains("error:") { return true }
        if trimmed.contains("warning:") { return true }
        if trimmed.contains("note:") { return true }

        // BuildRunner's own phase markers.
        if trimmed.hasPrefix("===") { return true }

        // Build status banners.
        if trimmed.contains("** BUILD") || trimmed.contains("** CLEAN") ||
           trimmed.contains("** ARCHIVE") || trimmed.contains("** TEST") {
            return true
        }

        // Device / signing / install context.
        if trimmed.hasPrefix("Device:") { return true }
        if trimmed.hasPrefix("Signing Identity:") { return true }
        if trimmed.hasPrefix("Provisioning Profile:") { return true }
        if trimmed.hasPrefix("App installed") { return true }
        if trimmed.hasPrefix("Acquired ") { return true }
        if trimmed.hasPrefix("Enabling developer disk image") { return true }

        // The xcodebuild invocation line (once) is useful to reproduce manually.
        if trimmed.hasPrefix("Command line invocation:") { return true }

        return false
    }

    /// xcodebuild step headers we want to hide entirely (header + `cd` + command + blank).
    private func shouldDropAsStepHeader(_ trimmed: String) -> Bool {
        let droppedPrefixes = [
            "WriteAuxiliaryFile",
            "CreateBuildDirectory",
            "CreateBuildRequest",
            "CreateBuildOperation",
            "CreateBuildDescription",
            "SendProjectDescription",
            "GatherProvisioningInputs",
            "ComputeTargetDependencyGraph",
            "ComputePackagePrebuildTargetDependencyGraph",
            "Prepare packages",
            "ClangStatCache",
            "ExecuteExternalTool",
            "MkDir ",
            "Copy ",
            "CpResource ",
            "CpHeader ",
            "CodeSign ",
            "ProcessProductPackaging",
            "ProcessProductPackagingDER",
            "ProcessInfoPlistFile",
            "GenerateAssetSymbols",
            "CompileAssetCatalogVariant",
            "LinkAssetCatalog",
            "Ld ",
            "Libtool ",
            "SwiftDriver ",
            "SwiftDriverJobDiscovery",
            "SwiftDriver\\",
            "SwiftEmitModule",
            "EmitSwiftModule",
            "SwiftMergeGeneratedHeaders",
            "ConstructStubExecutorLinkFileList",
            "CopySwiftLibs",
            "ExtractAppIntentsMetadata",
            "AppIntentsSSUTraining",
            "RegisterExecutionPolicyException",
            "RegisterWithLaunchServices",
            "Validate ",
            "Touch ",
            "Build description signature:",
            "Build description path:",
        ]
        return droppedPrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// Turns a SwiftCompile header into a short "Compiling Foo.swift" line.
    /// Input looks like: `SwiftCompile normal arm64 /path/to/Foo.swift (in target ...)`
    /// Or:               `SwiftCompile normal arm64 Compiling\ A.swift,\ B.swift ...`
    private func summarizeSwiftCompile(_ trimmed: String) -> String? {
        // We only care about the batch headers (the "Compiling A.swift, B.swift" form)
        // since the per-file lines are redundant. Drop per-file, keep batch.
        if trimmed.contains("Compiling\\") || trimmed.contains("Compiling ") {
            // Extract the "A.swift, B.swift, C.swift" part.
            if let range = trimmed.range(of: "Compiling\\ ") ?? trimmed.range(of: "Compiling ") {
                let rest = String(trimmed[range.upperBound...])
                // Trim off the " (in target ...)" suffix if present.
                let files = rest.components(separatedBy: " (in target").first ?? rest
                let cleaned = files.replacingOccurrences(of: "\\", with: "")
                return "Compiling \(cleaned)"
            }
        }
        return nil
    }
}
