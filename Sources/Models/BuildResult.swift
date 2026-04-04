import Foundation

enum BuildResult {
    case success(appBundlePath: URL, profileExpiresAt: Date? = nil)
    case failure(phase: BuildPhase, message: String)
    case cancelled
}

enum BuildPhase: String {
    case xcodebuild = "Build"
    case deviceInstall = "Install"
    case deviceNotFound = "Device Discovery"
}
