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

    /// Inspects `project.pbxproj` for an `iphoneos` SDKROOT.
    /// Returns true if any build configuration targets iOS.
    /// Returns false for macOS-only projects (SDKROOT = macosx).
    /// Returns true as a permissive default if the pbxproj can't be read,
    /// so we don't silently drop valid projects on an unexpected format.
    static func isIOSProject(xcodeprojURL: URL) -> Bool {
        let pbxprojURL = xcodeprojURL.appendingPathComponent("project.pbxproj")
        guard let contents = try? String(contentsOf: pbxprojURL, encoding: .utf8) else {
            return true
        }
        // Look for SDKROOT assignments. Typical forms:
        //   SDKROOT = iphoneos;
        //   SDKROOT = macosx;
        if contents.contains("SDKROOT = iphoneos") { return true }
        if contents.contains("SDKROOT = macosx") { return false }
        // Fallback: check SUPPORTED_PLATFORMS if SDKROOT isn't explicit.
        if contents.contains("iphoneos") && !contents.contains("SDKROOT = macosx") {
            return true
        }
        return false
    }
}
