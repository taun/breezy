import Foundation

public enum DatePrecision: String, Sendable { case day, year }

/// A node date as ISO `YYYY-MM-DD` plus how much of it to show.
public struct NodeDate: Equatable, Sendable {
    public var iso: String
    public var precision: DatePrecision

    public init(iso: String, precision: DatePrecision = .day) {
        self.iso = iso
        self.precision = precision
    }

    public var label: String { precision == .year ? String(iso.prefix(4)) : iso }

    /// Interprets decoded `date:` and `datePrecision:` values like lib/frontmatter.js: a year alone (integer 1000-9999
    /// or the string "YYYY") becomes `YYYY-01-01` with year precision (unless a precision is given).
    public static func parse(date: Any?, precision: Any?) -> NodeDate? {
        let given = (precision as? String).flatMap(DatePrecision.init(rawValue:))
        if let y = date as? Int {
            guard (1000...9999).contains(y) else { return nil }
            return NodeDate(iso: "\(y)-01-01", precision: given ?? .year)
        }
        guard let s = date as? String else { return nil }
        if s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return NodeDate(iso: s, precision: given ?? .day) }
        if s.range(of: #"^\d{4}$"#, options: .regularExpression) != nil { return NodeDate(iso: "\(s)-01-01", precision: given ?? .year) }
        return nil
    }
}
