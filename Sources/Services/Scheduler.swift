import Foundation
import AppKit

@MainActor
final class Scheduler {
    private var timer: Timer?
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private weak var store: ProjectStore?
    private weak var notifications: NotificationManager?
    private weak var logStore: BuildLogStore?

    func start(store: ProjectStore, notifications: NotificationManager, logStore: BuildLogStore) {
        self.store = store
        self.notifications = notifications
        self.logStore = logStore

        // Check once at launch
        Task { await checkDueProjects() }

        // Hourly checks
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.checkDueProjects() }
        }

        // Check after Mac wakes from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.checkDueProjects() }
        }

        // Wire up notification retry
        notifications.onRetry = { [weak self] id in
            guard let self else { return }
            Task { await self.buildProject(id: id) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func checkNow(for id: UUID? = nil) {
        Task {
            if let id {
                await buildProject(id: id)
            } else {
                await checkDueProjects()
            }
        }
    }

    func cancelBuild(for id: UUID) {
        guard let task = inFlight.removeValue(forKey: id) else { return }
        task.cancel()
        store?.markBuildCancelled(id: id)
    }

    // MARK: - Private

    private func checkDueProjects() async {
        guard let store else { return }
        let due = store.projects.filter { $0.isDue && !$0.isBuilding }
        for project in due {
            await buildProject(id: project.id)
        }
    }

    private func buildProject(id: UUID) async {
        guard let store, let notifications else { return }
        guard inFlight[id] == nil else { return }
        guard let project = store.projects.first(where: { $0.id == id }) else { return }

        store.markBuildStarted(id: id)
        logStore?.clearLog(for: id, name: project.name)

        let task = Task { [weak self] in
            let preferredDeviceID = UserDefaults.standard.string(forKey: "selectedDeviceID")
            let projectName = project.name
            let projectID = project.id

            let (result, log) = await BuildRunner.build(
                project: project,
                preferredDeviceID: preferredDeviceID,
                onOutput: { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.logStore?.appendLog(text, for: projectID, name: projectName)
                        // Parse phase from output
                        if let phase = Self.parsePhase(from: text) {
                            self.store?.updateBuildPhase(id: projectID, phase: phase)
                        }
                    }
                }
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight.removeValue(forKey: projectID)

                // Always save the log, even on cancel
                self.logStore?.save(log: log, for: projectID, name: projectName)

                switch result {
                case .success(_, let profileExpiresAt):
                    store.markBuildSucceeded(id: projectID, profileExpiresAt: profileExpiresAt)
                    notifications.sendSuccessNotification(project: project)
                case .failure(let phase, let message):
                    store.markBuildFailed(id: projectID, error: "\(phase.rawValue): \(message)")
                    notifications.sendFailureNotification(project: project, message: message)
                case .cancelled:
                    store.markBuildCancelled(id: projectID)
                }
            }
        }

        inFlight[id] = task
    }

    private static func parsePhase(from text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.contains("=== Device Discovery ===") { return "Finding device..." }
        if line.contains("=== xcodebuild ===") { return "Building..." }
        if line.contains("=== Install ===") { return "Installing..." }
        if line.contains("Compiling") { return "Compiling..." }
        if line.contains("Linking") { return "Linking..." }
        if line.contains("Signing") || line.contains("CodeSign") { return "Signing..." }
        return nil
    }
}
