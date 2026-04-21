import SwiftUI

@main
struct ReSignApp: App {
    @State private var store = ProjectStore()
    @State private var logStore = BuildLogStore()
    @State private var scheduler = Scheduler()
    @State private var notifications = NotificationManager()
    @State private var didStart = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(scheduler: scheduler)
                .environment(store)
                .environment(logStore)
        } label: {
            StatusIconView(store: store)
                .task {
                    guard !didStart else { return }
                    didStart = true
                    notifications.requestPermission()
                    logStore.loadAll(projects: store.projects)
                    scheduler.start(store: store, notifications: notifications, logStore: logStore)
                }
        }
        .menuBarExtraStyle(.window)
    }
}
