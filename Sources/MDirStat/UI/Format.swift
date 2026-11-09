import Foundation

/// Formatage fait a la main pour rester en anglais sur un Mac en francais.
enum Format {
    private static let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]

    /// Comme le Finder : puissances de 1000, « 812 KB », « 13.1 MB », « 2.94 GB ».
    static func bytes(_ value: Int64) -> String {
        var amount = Double(value)
        var unit = 0
        while abs(amount) >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        switch unit {
        case 0: return "\(Int(amount)) bytes"
        case 1: return String(format: "%.0f %@", amount, units[unit])
        case 2: return String(format: "%.1f %@", amount, units[unit])
        default: return String(format: "%.2f %@", amount, units[unit])
        }
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func count(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func date(_ time: Int) -> String {
        time > 0 ? dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(time))) : ""
    }

    /// « 0:07 », « 12:34 », « 1:02:03 ».
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }
}
