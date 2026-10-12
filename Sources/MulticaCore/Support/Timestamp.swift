import Foundation

/// Server timestamps travel as RFC 3339 strings. Models keep the string and
/// parse on demand: a 3000-message transcript only needs dates for the rows on
/// screen, and `ISO8601DateFormatter` is an order of magnitude slower than the
/// hand-rolled parser below.
public enum Timestamp {
    /// Parses `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`. Returns nil for
    /// anything else rather than guessing.
    public static func parse(_ s: String) -> Date? {
        var s = s
        return s.withUTF8 { parse(bytes: $0) }
    }

    private static func parse(bytes b: UnsafeBufferPointer<UInt8>) -> Date? {
        guard b.count >= 19 else { return nil }
        @inline(__always) func digit(_ i: Int) -> Int? {
            let c = b[i]
            return (c >= 48 && c <= 57) ? Int(c - 48) : nil
        }
        @inline(__always) func num(_ i: Int, _ n: Int) -> Int? {
            var v = 0
            for k in i..<(i + n) {
                guard let d = digit(k) else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard let year = num(0, 4), b[4] == 45, let month = num(5, 2), b[7] == 45,
              let day = num(8, 2), b[10] == 84 || b[10] == 116 || b[10] == 32,
              let hour = num(11, 2), b[13] == 58, let minute = num(14, 2), b[16] == 58,
              let second = num(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }

        var i = 19
        var fraction = 0.0
        if i < b.count, b[i] == 46 { // '.'
            i += 1
            var scale = 0.1
            while i < b.count, let d = digit(i) {
                fraction += Double(d) * scale
                scale /= 10
                i += 1
            }
        }
        var offset = 0
        if i < b.count {
            switch b[i] {
            case 90, 122: // Z z
                i += 1
            case 43, 45: // + -
                guard i + 6 <= b.count, let oh = num(i + 1, 2), b[i + 3] == 58, let om = num(i + 4, 2) else {
                    return nil
                }
                offset = (oh * 3600 + om * 60) * (b[i] == 45 ? -1 : 1)
                i += 6
            default:
                return nil
            }
        }
        guard i == b.count else { return nil }

        let days = daysFromCivil(year, month, day)
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// Howard Hinnant's days_from_civil: days since 1970-01-01 for a proleptic
    /// Gregorian date.
    @inline(__always)
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
