import Foundation

public enum FieldSource: String, Codable, Sendable { case explicit = "EXPLICIT", inferred = "INFERRED" }
public enum Deadline: Equatable, Sendable, Codable {
    case none(originalExpression: String?)
    case date(LocalDate, zone: ZoneID, source: FieldSource, originalExpression: String?)
    case instant(Instant, zone: ZoneID, source: FieldSource, originalExpression: String?)

    enum Keys: String, CodingKey { case kind, source, originalExpression, localDate, zoneId, instant }
    struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let rawKeys = Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
        let common: Set<String> = ["kind", "source", "originalExpression"]
        let expression = try c.decodeIfPresent(String.self, forKey: .originalExpression)
        switch kind {
        case "NONE":
            let source = try c.decode(String.self, forKey: .source)
            try require(rawKeys == common && source == "UNKNOWN", "Invalid NONE deadline")
            self = .none(originalExpression: expression)
        case "DATE":
            try require(rawKeys == common.union(["localDate", "zoneId"]), "Invalid DATE fields")
            self = try .date(c.decode(LocalDate.self, forKey: .localDate), zone: c.decode(ZoneID.self, forKey: .zoneId),
                         source: c.decode(FieldSource.self, forKey: .source), originalExpression: expression)
        case "INSTANT":
            try require(rawKeys == common.union(["instant", "zoneId"]), "Invalid INSTANT fields")
            self = try .instant(c.decode(Instant.self, forKey: .instant), zone: c.decode(ZoneID.self, forKey: .zoneId),
                            source: c.decode(FieldSource.self, forKey: .source), originalExpression: expression)
        default: throw DomainError(.invalidArgument, "Unknown deadline kind")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .none(let text):
            try c.encode("NONE", forKey: .kind); try c.encode("UNKNOWN", forKey: .source)
            try c.encode(text, forKey: .originalExpression)
        case .date(let day, let zone, let source, let text):
            try c.encode("DATE", forKey: .kind); try c.encode(day, forKey: .localDate)
            try c.encode(zone, forKey: .zoneId); try c.encode(source, forKey: .source); try c.encode(text, forKey: .originalExpression)
        case .instant(let instant, let zone, let source, let text):
            try c.encode("INSTANT", forKey: .kind); try c.encode(instant, forKey: .instant)
            try c.encode(zone, forKey: .zoneId); try c.encode(source, forKey: .source); try c.encode(text, forKey: .originalExpression)
        }
    }
}

public struct DateResolution: Equatable, Sendable {
    public let deadline: Deadline
    public let uncertainFields: [String]
    public let suggestedLocalDate: LocalDate?
}

/// Deliberately bounded parser. Unrecognized language stays uncertain; an LLM is not required.
public struct DateResolver: Sendable {
    public init() {}
    public func resolve(_ expression: String, reference: Instant, zone: ZoneID) throws -> DateResolution {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone.timeZone
        func local(_ date: Date) throws -> LocalDate {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return try LocalDate(String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!))
        }
        func add(_ days: Int) throws -> LocalDate {
            guard let date = calendar.date(byAdding: .day, value: days, to: reference.date) else {
                throw DomainError(.invalidArgument, "Calendar arithmetic failed")
            }
            return try local(date)
        }
        let relative = ["今天": 0, "明天": 1, "后天": 2]
        if let days = relative[text] {
            return DateResolution(deadline: .date(try add(days), zone: zone, source: .explicit, originalExpression: expression), uncertainFields: [], suggestedLocalDate: nil)
        }
        if text.hasPrefix("下周"), text.count == 3,
           let weekday = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1][String(text.suffix(1))] {
            let mondayOffset = (calendar.component(.weekday, from: reference.date) + 5) % 7
            let targetOffset = (weekday + 5) % 7
            return DateResolution(deadline: .date(try add(7 - mondayOffset + targetOffset), zone: zone, source: .explicit, originalExpression: expression), uncertainFields: [], suggestedLocalDate: nil)
        }
        if text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil {
            return DateResolution(deadline: .date(try LocalDate(text), zone: zone, source: .explicit, originalExpression: expression), uncertainFields: [], suggestedLocalDate: nil)
        }
        let suggested: LocalDate? = text == "明天下午" ? try add(1) : nil
        return DateResolution(deadline: .none(originalExpression: expression), uncertainFields: ["deadline"], suggestedLocalDate: suggested)
    }
}
