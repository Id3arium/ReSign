import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(BuildLogStore.self) private var logStore
    let scheduler: Scheduler

    @State private var showSettings = false
    @State private var expandedLogID: UUID?
    @State private var projectListContentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text("ReSign")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()

                if !showSettings {
                    HeaderButton(icon: "arrow.clockwise", help: "Refresh projects") {
                        try? store.refresh()
                    }
                }

                HeaderButton(
                    icon: showSettings ? "arrow.left" : "gear",
                    help: showSettings ? "Back to projects" : "Settings"
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showSettings.toggle()
                        expandedLogID = nil
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            if showSettings {
                SettingsPanel()
            } else {
                projectList
            }

            Divider()

            HoverButton("Quit ReSign") {
                NSApplication.shared.terminate(nil)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .onHover { inside in
            // macOS sometimes shows a resize cursor over dividers / scroll
            // edges in a MenuBarExtra window. Force the arrow cursor while
            // hovering anywhere in the popup.
            if inside {
                NSCursor.arrow.set()
            }
        }
    }

    // MARK: - Projects

    @ViewBuilder
    private var projectList: some View {
        if store.projects.isEmpty {
            Text(UserDefaults.standard.string(forKey: "scanPath")?.isEmpty == false
                 ? "No iOS projects found in\n\(UserDefaults.standard.string(forKey: "scanPath")!)"
                 : "No scan path set.\nOpen Settings and choose a folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let allLogs = logStore.logs
            // Measure the content's natural height so the ScrollView can size
            // to fit (showing all cards without scrolling) up to a 320pt cap.
            // macOS 26 collapses a ScrollView that has only a maxHeight to zero
            // height inside MenuBarExtra(.window), so we drive the height from
            // the measured content instead of relying on maxHeight alone.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.projects) { project in
                        ProjectCardRow(
                            project: project,
                            log: allLogs[project.id],
                            isExpanded: expandedLogID == project.id,
                            onRebuild: { scheduler.checkNow(for: project.id) },
                            onCancel: { scheduler.cancelBuild(for: project.id) },
                            onTap: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedLogID = expandedLogID == project.id ? nil : project.id
                                }
                            }
                        )
                        Divider()
                    }
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            // Clamp into [44, 320]: never collapse to zero before the first
            // measurement arrives, never grow past the cap (scroll past that).
            .frame(height: min(max(projectListContentHeight, 44), 320))
            .onPreferenceChange(ContentHeightKey.self) { projectListContentHeight = $0 }
        }
    }
}

// Measures the natural height of the project list content so the ScrollView
// can size to fit (up to a cap) instead of collapsing to zero on macOS 26.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Project Card Row

private struct ProjectCardRow: View {
    let project: ManagedProject
    let log: String?
    let isExpanded: Bool
    let onRebuild: () -> Void
    let onCancel: () -> Void
    let onTap: () -> Void

    @State private var isHovered = false

    private var expandedLogText: String {
        var parts: [String] = []
        parts.append(statusSummary)
        if let log, !log.isEmpty {
            parts.append(log)
        }
        return parts.joined(separator: "\n\n")
    }

    private var statusSummary: String {
        if project.isBuilding { return project.buildPhase ?? "Building..." }
        if let error = project.lastError { return error }
        guard let last = project.lastBuiltAt else { return "Never built" }
        let lastStr = DateHelpers.relativeLabel(for: last)
        if let expiry = project.expiryLabel {
            if project.stuckOnOldProfile {
                return "Profile still valid · built \(lastStr) · \(expiry)"
            }
            return "Built \(lastStr) · \(expiry)"
        }
        return "Built \(lastStr)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ProjectRowView(project: project, onBuildNow: onRebuild, onCancel: onCancel)

            if isExpanded {
                let displayText = expandedLogText
                if !displayText.isEmpty {
                    ScrollView {
                        Text(displayText)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 140)
                    .background(.black.opacity(0.05))
                    .overlay(alignment: .topTrailing) {
                        CopyLogButton(log: displayText)
                            .padding(.top, 6)
                            .padding(.trailing, 18)
                    }
                }
            }
        }
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onTap() }
    }
}

// MARK: - Copy Log Button

private struct CopyLogButton: View {
    let log: String
    @State private var justCopied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(log, forType: .string)
            justCopied = true
            Task {
                try? await Task.sleep(for: .milliseconds(1200))
                justCopied = false
            }
        } label: {
            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(justCopied ? Color.green : Color.primary.opacity(0.7))
                .padding(5)
                .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(justCopied ? "Copied" : "Copy log")
    }
}

// MARK: - Header Button

private struct HeaderButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    init(icon: String, help: String, action: @escaping () -> Void) {
        self.icon = icon
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovered ? .primary : .secondary)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

// MARK: - Hover Button

private struct HoverButton: View {
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovered ? .primary : .secondary)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Settings Panel

private struct SettingsPanel: View {
    @Environment(ProjectStore.self) private var store
    @AppStorage("scanPath") private var scanPath = ""
    @AppStorage("selectedDeviceID") private var selectedDeviceID = ""
    @State private var devices: [DeviceInfo] = []
    @State private var isLoadingDevices = false
    // Reflect the saved intent (persists across reinstalls), falling back to
    // live OS status so a freshly-registered item still reads as on.
    @State private var launchAtLogin = LoginItemManager.wantsLaunchAtLogin || LoginItemManager.isEnabled
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // Launch at login
                HStack {
                    Text("Launch ReSign at login")
                        .controlSize(.small)
                    Spacer()
                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, newValue in
                            try? LoginItemManager.setEnabled(newValue)
                            // Reflect saved intent: setEnabled persisted it even
                            // if the OS registration call is briefly out of sync.
                            launchAtLogin = LoginItemManager.wantsLaunchAtLogin
                        }
                }

                Divider()

                // Scan path
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan Path")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Text(scanPath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Change") { pickFolder() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5)
                            )
                    }
                }

                Divider()

                // Device picker
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Install Device")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isLoadingDevices {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        } else {
                            HeaderButton(icon: "arrow.clockwise", help: "Refresh devices") {
                                Task { await refreshDevices() }
                            }
                        }
                    }

                    Picker("", selection: $selectedDeviceID) {
                        Text("Automatic")
                            .tag("")

                        ForEach(devices) { device in
                            Text("\(device.name)")
                                .tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: ContentHeightKey.self, value: proxy.size.height)
                }
            )
        }
        // Same macOS 26 collapse fix as the project list: size to content,
        // clamped into [44, 260], rather than relying on maxHeight alone.
        .frame(height: min(max(contentHeight, 44), 260))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .task { await refreshDevices() }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: scanPath)
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            scanPath = url.path
            try? store.refresh()
        }
    }

    private func refreshDevices() async {
        isLoadingDevices = true
        defer { isLoadingDevices = false }
        devices = (try? await DeviceLocator.findAllDevices()) ?? []
    }
}
