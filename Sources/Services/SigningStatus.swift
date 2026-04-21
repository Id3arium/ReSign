import Foundation

/// Checks whether Xcode / the keychain has a usable code-signing identity.
///
/// Xcode has a well-known habit of silently signing the user out (session token
/// expiry, 2FA timeout, keychain conflicts). When that happens, `xcodebuild`
/// wastes ~30s before failing with "No Accounts". This check lets us detect
/// the signed-out state in milliseconds and skip the doomed build.
enum SigningStatus {
    enum State: Equatable {
        case signedIn(identityCount: Int)
        case signedOut
        case unknown(reason: String)
    }

    /// Runs `security find-identity -v -p codesigning` and parses the count of
    /// "Apple Development" identities. Zero → signed out.
    static func current() -> State {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = ["find-identity", "-v", "-p", "codesigning"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .unknown(reason: error.localizedDescription)
        }
        process.waitUntilExit()

        guard let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return .unknown(reason: "Could not read output from `security`.")
        }

        // Count lines containing an "Apple Development" or "Apple Distribution"
        // identity. Format per line: `  1) ABC123... "Apple Development: name (TEAM)"`
        let count = output
            .components(separatedBy: "\n")
            .filter { $0.contains("Apple Development") || $0.contains("Apple Distribution") }
            .count

        return count > 0 ? .signedIn(identityCount: count) : .signedOut
    }
}
