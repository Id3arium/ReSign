import Foundation

enum ProjectDiscovery {
    static let excludedNames: Set<String> = ["ReSign"]

    static func discoverProjects(in scanRoot: URL) throws -> [ManagedProject] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: scanRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return contents.compactMap { url -> ManagedProject? in
            let name = url.lastPathComponent
            guard !excludedNames.contains(name) else { return nil }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }

            let xcodeprojURL = url.appendingPathComponent("\(name).xcodeproj")
            guard FileManager.default.fileExists(atPath: xcodeprojURL.path) else { return nil }

            // Only include projects that target iOS. We read SDKROOT from the
            // project.pbxproj — iphoneos → iOS, macosx → macOS (skip).
            guard isIOSProject(xcodeprojURL: xcodeprojURL) else { return nil }

            return ManagedProject(id: UUID(), name: name, projectPath: xcodeprojURL)
        }
    }

    /// Inspects `project.pbxproj` to decide whether the project targets iOS.
    /// Returns true if SDKROOT (or, failing that, SUPPORTED_PLATFORMS) names
    /// `iphoneos`. Returns false for macOS-only projects (SDKROOT = macosx).
    /// Returns true as a permissive default if the pbxproj can't be read,
    /// so we don't silently drop valid projects on an unexpected format.
    static func isIOSProject(xcodeprojURL: URL) -> Bool {
        let pbxprojURL = xcodeprojURL.appendingPathComponent("project.pbxproj")
        guard let contents = try? String(contentsOf: pbxprojURL, encoding: .utf8) else {
            return true
        }
        // Match build-setting assignments as real tokens rather than bare
        // substrings, tolerating whitespace and optional quotes:
        //   SDKROOT = iphoneos;   SDKROOT = "iphoneos";   SDKROOT=iphoneos;
        if matches(#"SDKROOT\s*=\s*"?iphoneos"?"#, in: contents) { return true }
        if matches(#"SDKROOT\s*=\s*"?macosx"?"#, in: contents) { return false }
        // No explicit SDKROOT: fall back to SUPPORTED_PLATFORMS containing
        // iphoneos as a whole word (e.g. xcodegen projects like Almanac).
        if matches(#"SUPPORTED_PLATFORMS\s*=[^;]*\biphoneos\b"#, in: contents) { return true }
        return false
    }

    /// Whether `pattern` (a regex) matches anywhere in `text`.
    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
