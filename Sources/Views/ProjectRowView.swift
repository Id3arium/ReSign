import SwiftUI

struct ProjectRowView: View {
    let project: ManagedProject
    let onBuildNow: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.subheadline.weight(.medium))

                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if project.isBuilding {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)

                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel build")
                }
                .frame(height: 28)
            } else {
                Button("Build Now", action: onBuildNow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        if project.isBuilding { return .blue }
        if project.lastError != nil { return .red }
        if project.isDue { return .orange }
        return .green
    }

    private var statusLabel: String {
        if project.isBuilding { return project.buildPhase ?? "Building..." }
        if let error = project.lastError { return String(error.prefix(80)) }
        guard let last = project.lastBuiltAt else { return "Never built — will build soon" }
        let lastStr = DateHelpers.relativeLabel(for: last)
        if let expiry = project.expiryLabel {
            return "Built \(lastStr) · \(expiry)"
        }
        return "Built \(lastStr)"
    }
}
