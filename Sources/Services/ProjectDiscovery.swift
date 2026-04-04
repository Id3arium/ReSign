import Foundation

enum ProjectDiscovery {
    static let defaultScanPath = "/Users/alejandro/Projects/Code/iOS"
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

            return ManagedProject(id: UUID(), name: name, projectPath: xcodeprojURL)
        }
    }
}
