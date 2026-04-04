import Foundation

struct DeviceInfo: Identifiable {
    let id: String      // UDID used with devicectl --device
    let name: String    // Human-readable, e.g. "Alejandro's iPhone"
}
