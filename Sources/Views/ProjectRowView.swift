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
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)

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
                Button("Rebuild", action: onBuildNow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        if project.isBuilding { return .blue.opacity(0.9) }
        if project.lastError != nil { return .red.opacity(0.9) }
        if project.isDue { return .orange.opacity(0.9) }
        return .green.opacity(0.9)
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
