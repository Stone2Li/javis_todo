import Foundation

public struct DomainError: Error, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case invalidArgument = "INVALID_ARGUMENT"
        case invalidTransition = "INVALID_TRANSITION"
        case dependencyCycle = "DEPENDENCY_CYCLE"
        case dependencyConflict = "DEPENDENCY_CONFLICT"
        case referenceNotFound = "REFERENCE_NOT_FOUND"
        case entityNotFound = "ENTITY_NOT_FOUND"
        case duplicateEntity = "DUPLICATE_ENTITY"
        case revisionConflict = "REVISION_CONFLICT"
        case undoConflict = "UNDO_CONFLICT"
        case confirmationRequired = "CONFIRMATION_REQUIRED"
        case previewMismatch = "PREVIEW_MISMATCH"
        case idempotencyConflict = "IDEMPOTENCY_CONFLICT"
    }
    public let code: Code
    public let message: String
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw DomainError(.invalidArgument, message) }
}

public struct EntityID: Hashable, Comparable, Codable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws {
        guard let value = UUID(uuidString: rawValue), value.uuidString.lowercased() == rawValue.lowercased() else {
            throw DomainError(.invalidArgument, "Expected a canonical UUID")
        }
        self.rawValue = value.uuidString.lowercased()
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

public struct Revision: Hashable, Codable, Sendable {
    public let value: Int
    public init(_ value: Int) throws { try require(value > 0, "Revision must be positive"); self.value = value }
    public func advanced() throws -> Self {
        let (next, overflow) = value.addingReportingOverflow(1)
        try require(!overflow, "Revision overflow"); return try Self(next)
    }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(Int.self)) }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(value)
    }
}

public struct EstimatedMinutes: Equatable, Codable, Sendable {
    public let value: Int
    public init(_ value: Int) throws { try require(value > 0, "Estimate must be a positive number of minutes"); self.value = value }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(Int.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(value) }
}

public struct ZoneID: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(_ value: String) throws {
        try require(value == "UTC" || value == "GMT" || TimeZone.knownTimeZoneIdentifiers.contains(value), "Unknown IANA time zone")
        self.rawValue = value
    }
    var timeZone: TimeZone { TimeZone(identifier: rawValue)! }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

public struct Instant: Hashable, Comparable, Codable, Sendable {
    public let epochMilliseconds: Int64
    public init(epochMilliseconds: Int64) throws {
        try require((-62_135_596_800_000...253_402_300_799_999).contains(epochMilliseconds), "Instant outside supported calendar")
        self.epochMilliseconds = epochMilliseconds
    }
    public init(_ canonical: String) throws {
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$"#
        let formatter = Self.formatter()
        guard canonical.range(of: pattern, options: .regularExpression) != nil,
              let date = formatter.date(from: canonical), formatter.string(from: date) == canonical else {
            throw DomainError(.invalidArgument, "Expected a valid UTC instant with millisecond precision")
        }
        try self.init(epochMilliseconds: Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }
    public var canonical: String { Self.formatter().string(from: date) }
    var date: Date { Date(timeIntervalSince1970: Double(epochMilliseconds) / 1000) }
    static func formatter() -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; f.isLenient = false; return f
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.epochMilliseconds < rhs.epochMilliseconds }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(canonical) }
}

public struct LocalDate: Hashable, Comparable, Codable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public init(_ text: String) throws {
        try require(text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil, "Expected YYYY-MM-DD")
        let parts = text.split(separator: "-").map { Int($0)! }
        self.year = parts[0]; self.month = parts[1]; self.day = parts[2]
        try require((1...9999).contains(year), "Unsupported year")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let requested = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: requested) else { throw DomainError(.invalidArgument, "Invalid calendar date") }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        try require(actual.year == year && actual.month == month && actual.day == day, "Invalid calendar date")
    }
    public var canonical: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.canonical < rhs.canonical }
    public func interval(in zone: ZoneID) throws -> (start: Instant, endExclusive: Instant) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone.timeZone
        guard let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              let interval = calendar.dateInterval(of: .day, for: noon) else {
            throw DomainError(.invalidArgument, "Date has no local day interval")
        }
        let actual = calendar.dateComponents([.year, .month, .day], from: noon)
        try require(actual.year == year && actual.month == month && actual.day == day, "Date does not exist in this time zone")
        return (try Instant(epochMilliseconds: Int64((interval.start.timeIntervalSince1970 * 1000).rounded())),
                try Instant(epochMilliseconds: Int64((interval.end.timeIntervalSince1970 * 1000).rounded())))
    }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(canonical) }
}

public protocol DomainClock: Sendable { func now() -> Instant }
public struct FixedClock: DomainClock {
    public let instant: Instant
    public init(_ instant: Instant) { self.instant = instant }
    public func now() -> Instant { instant }
}

func canonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

func validatedTitle(_ value: String) throws -> String {
    let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
    try require((1...200).contains(title.unicodeScalars.count), "Title must contain 1...200 Unicode scalars")
    return title
}

private struct ObjectKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
func rejectUnknownKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    let keys = Set(try decoder.container(keyedBy: ObjectKey.self).allKeys.map(\.stringValue))
    try require(keys.isSubset(of: allowed), "Unsupported object fields")
}
