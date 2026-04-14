import Foundation
import Observation

@Observable
@MainActor
final class BuildLogStore {
    private(set) var logs: [UUID: String] = [:]

    private var logsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("ReSign/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func save(log: String, for projectID: UUID, name: String) {
        logs[projectID] = log
        let file = logsDirectory.appendingPathComponent("\(name).log")
        try? log.write(to: file, atomically: true, encoding: .utf8)
    }

    func appendLog(_ text: String, for projectID: UUID, name: String) {
        logs[projectID, default: ""] += text
        let file = logsDirectory.appendingPathComponent("\(name).log")
        if let data = text.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            // File doesn't exist yet, create it
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    func clearLog(for projectID: UUID, name: String) {
        logs[projectID] = nil
        let file = logsDirectory.appendingPathComponent("\(name).log")
        try? FileManager.default.removeItem(at: file)
    }

    func log(for projectID: UUID) -> String? {
        logs[projectID]
    }

    func loadAll(projects: [ManagedProject]) {
        for project in projects {
            let file = logsDirectory.appendingPathComponent("\(project.name).log")
            if let content = try? String(contentsOf: file, encoding: .utf8) {
                logs[project.id] = content
            }
        }
    }
}
