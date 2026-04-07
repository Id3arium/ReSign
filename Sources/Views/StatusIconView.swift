import SwiftUI
import AppKit

struct StatusIconView: View {
    let store: ProjectStore

    var body: some View {
        if let nsImage = NSImage(named: "MenuBarIcon") {
            let tinted = nsImage.tinted(with: NSColor(iconColor))
            Image(nsImage: tinted)
        }
    }

    private var iconColor: Color {
        if store.projects.contains(where: { $0.isBuilding }) { return .blue.opacity(0.8) }
        if store.projects.contains(where: { $0.lastError != nil }) { return .red.opacity(0.8) }
        if store.projects.contains(where: { $0.isDue }) { return .orange.opacity(0.8) }
        return .green.opacity(0.8)
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
