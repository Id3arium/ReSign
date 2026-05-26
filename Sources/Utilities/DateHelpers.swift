import Foundation

enum DateHelpers {
    static func daysUntilExpiry(from date: Date) -> Int {
        let next = Calendar.current.date(byAdding: .day, value: 6, to: date) ?? date
        return max(0, Calendar.current.dateComponents([.day], from: .now, to: next).day ?? 0)
    }

    static func relativeLabel(for date: Date) -> String {
        let seconds = Date.now.timeIntervalSince(date)
        if abs(seconds) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    static func expiryDate(from buildDate: Date) -> String {
        let expiry = Calendar.current.date(byAdding: .day, value: 6, to: buildDate) ?? buildDate
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: expiry)
    }
}
