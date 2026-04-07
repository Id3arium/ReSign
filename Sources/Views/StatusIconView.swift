import SwiftUI
import AppKit

struct StatusIconView: View {
    let store: ProjectStore

    var body: some View {
        if let nsImage = NSImage(named: "MenuBarIcon") {
            let tinted = nsImage.tinted(with: NSColor(iconColor))
            Image(nsImage: tinted)
                .resizable()
                .frame(width: 18, height: 18)
        }
    }

    private var iconColor: Color {
        if store.projects.contains(where: { $0.isBuilding }) { return .yellow }
        if store.projects.contains(where: { $0.lastError != nil }) { return .red }
        if store.projects.contains(where: { $0.isDue }) { return .orange }
        return .green
    }
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
