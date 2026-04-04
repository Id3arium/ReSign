import SwiftUI

struct StatusIconView: View {
    let store: ProjectStore

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.palette)
            .foregroundStyle(iconColor, Color.primary)
    }

    private var iconName: String {
        if store.projects.contains(where: { $0.isBuilding }) {
            return "arrow.triangle.2.circlepath"
        }
        if store.projects.contains(where: { $0.lastError != nil }) {
            return "exclamationmark.circle.fill"
        }
        if store.projects.contains(where: { $0.isDue }) {
            return "clock.badge.exclamationmark.fill"
        }
        return "checkmark.circle.fill"
    }

    private var iconColor: Color {
        if store.projects.contains(where: { $0.isBuilding }) { return .blue }
        if store.projects.contains(where: { $0.lastError != nil }) { return .red }
        if store.projects.contains(where: { $0.isDue }) { return .orange }
        return .green
    }
}
