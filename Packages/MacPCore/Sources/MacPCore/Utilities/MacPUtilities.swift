import Foundation

/// Single source of truth for MacP application and server versioning.
public enum MacPVersion {
    public static let current = "2.1.0"
    public static let short = "v2.1"
}

/// Fast, thread-safe, allocation-free ISO-8601 date formatting and parsing helpers.
public enum ISO8601Codec {
    private static let internetDateTimeStyle = Date.ISO8601FormatStyle()
    private static let fractionalSecondsStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public static func format(_ date: Date) -> String {
        date.formatted(internetDateTimeStyle)
    }

    public static func parse(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let date = try? fractionalSecondsStyle.parse(value) {
            return date
        }
        if let date = try? internetDateTimeStyle.parse(value) {
            return date
        }
        return parseLocalDateTime(value)
    }

    /// Parses local ISO-like date-times without timezone suffix:
    /// `YYYY-MM-DDTHH:MM:SS` or `YYYY-MM-DDTHH:MM` (or space separator).
    private static func parseLocalDateTime(_ value: String, calendar: Calendar = .current) -> Date? {
        let separator: Character = value.contains("T") ? "T" : (value.contains(" ") ? " " : "T")
        let parts = value.split(separator: separator, maxSplits: 1)
        guard parts.count == 2 else { return nil }

        let dateParts = parts[0].split(separator: "-")
        let timeParts = parts[1].split(separator: ":")
        guard dateParts.count == 3,
              (2...3).contains(timeParts.count),
              let year = Int(dateParts[0]),
              let month = Int(dateParts[1]),
              let day = Int(dateParts[2]),
              let hour = Int(timeParts[0]),
              let minute = Int(timeParts[1]),
              (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }

        let second: Int
        if timeParts.count == 3 {
            let secText = timeParts[2].split(separator: ".").first ?? timeParts[2]
            guard let parsedSec = Int(secText), (0...59).contains(parsedSec) else { return nil }
            second = parsedSec
        } else {
            second = 0
        }

        var comps = DateComponents()
        comps.calendar = calendar
        comps.timeZone = calendar.timeZone
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second

        guard let date = calendar.date(from: comps) else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard verified.year == year,
              verified.month == month,
              verified.day == day,
              verified.hour == hour,
              verified.minute == minute,
              verified.second == second else {
            return nil
        }
        return date
    }
}

/// Fast heuristic LLM token counter (~3.8 UTF-8 bytes per token for JSON/English/French payloads).
public enum TokenEstimator {
    public static func estimate(utf8Bytes: Int) -> Int {
        guard utf8Bytes > 0 else { return 0 }
        return max(1, Int((Double(utf8Bytes) / 3.8).rounded()))
    }

    public static func estimate(text: String) -> Int {
        estimate(utf8Bytes: text.utf8.count)
    }

    /// Formats a compact JSON string into pretty-printed JSON for human inspection in the UI.
    public static func prettyPrintJSONIfValid(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              JSONSerialization.isValidJSONObject(obj),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            return raw
        }
        return String(decoding: pretty, as: UTF8.self)
    }
}
