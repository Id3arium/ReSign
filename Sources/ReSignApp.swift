import SwiftUI

@main
struct ReSignApp: App {
    @State private var store = ProjectStore()
    @State private var logStore = BuildLogStore()
    private let scheduler = Scheduler()
    private let notifications = NotificationManager()

    init() {
        notifications.requestPermission()
        scheduler.start(store: store, notifications: notifications, logStore: logStore)
        logStore.loadAll(projects: store.projects)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(scheduler: scheduler)
                .environment(store)
                .environment(logStore)
        } label: {
            StatusIconView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
