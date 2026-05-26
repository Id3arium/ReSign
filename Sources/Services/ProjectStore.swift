import Foundation
import Observation

@Observable
@MainActor
final class ProjectStore {
    private(set) var projects: [ManagedProject] = []

    private var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("ReSign", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("projects.json")
    }

    init() {
        load()
        try? refresh()
    }

    /// Re-scans for projects, merging new ones in and preserving existing state.
    func refresh() throws {
        guard let path = UserDefaults.standard.string(forKey: "scanPath"), !path.isEmpty else {
            projects = []
            save()
            return
        }
        let scanRoot = URL(filePath: path)
        let discovered = try ProjectDiscovery.discoverProjects(in: scanRoot)

        // Guard: if scan returned nothing, don't wipe existing projects
        guard !discovered.isEmpty else { return }

        // Keep existing state for known projects, add new ones
        var updated: [ManagedProject] = []
        for disc in discovered {
            if let existing = projects.first(where: { $0.name == disc.name }) {
                updated.append(existing)
            } else {
                updated.append(disc)
            }
        }
        projects = updated
        save()
    }

    func markBuildStarted(id: UUID) {
        update(id: id) { $0.isBuilding = true; $0.buildPhase = "Starting..." }
    }

    func markBuildSucceeded(id: UUID, profileExpiresAt: Date? = nil) {
        update(id: id) {
            // "Stuck" means: we got a fresh build, but Apple handed back the same
            // (or an older) provisioning profile, so nothing actually bought us
            // more runtime on-device. Detect by comparing against the previous
            // expiry; tolerate a ~60s clock-skew nudge so trivially-same
            // timestamps don't also count as "advanced".
            if let new = profileExpiresAt, let old = $0.profileExpiresAt {
                $0.stuckOnOldProfile = new <= old.addingTimeInterval(60)
            } else {
                $0.stuckOnOldProfile = false
            }

            $0.isBuilding = false
            $0.lastBuiltAt = .now
            $0.lastError = nil
            $0.buildPhase = nil
            $0.profileExpiresAt = profileExpiresAt
        }
        save()
    }

    func markBuildFailed(id: UUID, error: String) {
        update(id: id) { $0.isBuilding = false; $0.lastError = error; $0.buildPhase = nil }
        save()
    }

    func markBuildCancelled(id: UUID) {
        update(id: id) { $0.isBuilding = false; $0.lastError = nil; $0.buildPhase = nil }
    }

    func updateBuildPhase(id: UUID, phase: String) {
        update(id: id) { $0.buildPhase = phase }
    }

    // MARK: - Private

    private func update(id: UUID, mutation: (inout ManagedProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        mutation(&projects[index])
    }

    private func save() {
        let data = try? JSONEncoder().encode(projects)
        try? data?.write(to: storeURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([ManagedProject].self, from: data) else { return }
        projects = saved.filter { ProjectDiscovery.isIOSProject(xcodeprojURL: $0.projectPath) }
    }
}
