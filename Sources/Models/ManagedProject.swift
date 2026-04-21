import Foundation

struct ManagedProject: Identifiable, Codable {
    let id: UUID
    let name: String
    let projectPath: URL
    var lastBuiltAt: Date?
    var lastError: String?
    var profileExpiresAt: Date?
    var isBuilding: Bool = false
    var buildPhase: String?
    /// Set when the most recent rebuild succeeded but Apple returned the same
    /// provisioning profile (expiry didn't advance). The build itself is fine;
    /// this surfaces "Apple said meh, rerun in Xcode or try again later."
    var stuckOnOldProfile: Bool = false

    var nextDueAt: Date? {
        if let profileExpiresAt {
            // Rebuild 2 hours before the profile actually expires. We used to
            // use 1 day, but free-tier profiles are only valid for 7 days and
            // Apple often won't issue a fresh one until the old one is nearly
            // gone — so a wider threshold just keeps the UI yellow all day
            // for nothing. 2h is "practically expired, do it now".
            return Calendar.current.date(byAdding: .hour, value: -2, to: profileExpiresAt)
        }
        guard let last = lastBuiltAt else { return .now }
        return Calendar.current.date(byAdding: .day, value: 6, to: last)
    }

    var isDue: Bool {
        guard let next = nextDueAt else { return true }
        return next <= .now
    }

    var daysUntilExpiry: Int {
        guard let profileExpiresAt else {
            guard let last = lastBuiltAt else { return 0 }
            return DateHelpers.daysUntilExpiry(from: last)
        }
        return max(0, Calendar.current.dateComponents([.day], from: .now, to: profileExpiresAt).day ?? 0)
    }

    var expiryLabel: String? {
        guard let profileExpiresAt else {
            guard let last = lastBuiltAt else { return nil }
            let days = DateHelpers.daysUntilExpiry(from: last)
            return "exp ~\(DateHelpers.expiryDate(from: last)) (~\(days)d left)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let dateStr = formatter.string(from: profileExpiresAt)
        return "exp \(dateStr) (\(daysUntilExpiry)d left)"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, projectPath, lastBuiltAt, lastError, profileExpiresAt, stuckOnOldProfile
    }
}
