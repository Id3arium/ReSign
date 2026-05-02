import Foundation

enum DeviceLocator {
    static func findAllDevices() async throws -> [DeviceInfo] {
        let (output, exitCode) = await run(["xcrun", "devicectl", "list", "devices", "--json-output", "-"])
        guard exitCode == 0, let data = output.data(using: .utf8) else {
            throw DeviceLocatorError.parseFailure("devicectl exited with code \(exitCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else {
            throw DeviceLocatorError.parseFailure("Unexpected devicectl output format")
        }

        var found: [DeviceInfo] = []
        for device in devices {
            guard let identifier = device["identifier"] as? String,
                  let hardwareProps = device["hardwareProperties"] as? [String: Any],
                  let platform = hardwareProps["platform"] as? String,
                  platform == "iOS",
                  let deviceProps = device["deviceProperties"] as? [String: Any],
                  let name = deviceProps["name"] as? String else { continue }

            found.append(DeviceInfo(id: identifier, name: name))
        }

        return found
    }

    static func findDevice(preferredID: String?) async throws -> DeviceInfo {
        let devices = try await findAllDevices()
        guard !devices.isEmpty else { throw DeviceLocatorError.noDeviceFound }

        if let preferredID, !preferredID.isEmpty,
           let match = devices.first(where: { $0.id == preferredID }) {
            return match
        }

        return devices[0]
    }

    private static func run(_ arguments: [String]) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = arguments
            let pipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errorPipe
            process.terminationHandler = { p in
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                // Merge stderr into output on failure so callers surface a real
                // error message (e.g. "No devices found", devicectl crashes)
                // instead of a silent empty string.
                let combined = p.terminationStatus == 0 ? out : (out + err)
                continuation.resume(returning: (output: combined, exitCode: p.terminationStatus))
            }
            try? process.run()
        }
    }
}

enum DeviceLocatorError: LocalizedError {
    case noDeviceFound
    case parseFailure(String)

    var errorDescription: String? {
        switch self {
        case .noDeviceFound:
            return "No iPhone found. Connect via USB or ensure Wi-Fi pairing is active and your phone is unlocked."
        case .parseFailure(let msg):
            return "Could not read device list: \(msg)"
        }
    }
}
