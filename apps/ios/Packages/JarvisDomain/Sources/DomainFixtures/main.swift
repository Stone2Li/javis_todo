import Foundation
import JarvisDomain

struct TaskSeed: Decodable {
    let id: EntityID
    let title: String
    let status: TaskStatus?
    let revision: Int?
    let dependencies: [EntityID]?
    let blockedReason: String?
    func record(at now: Instant) throws -> TaskRecord {
        let s = status ?? .todo
        return try TaskRecord(id: id, title: title, status: s, dependencyTaskIds: dependencies ?? [],
                              blockedReason: blockedReason, createdAt: now, completedAt: s == .done ? now : nil,
                              revision: Revision(revision ?? 1))
    }
}
struct Input: Decodable {
    let title: String?
    let tasks: [TaskSeed]?
    let expression: String?
    let localDate: LocalDate?
    let zoneId: ZoneID?
    let referenceInstant: Instant?
    let targetStatus: TaskStatus?
}
struct Fixture: Decodable { let id: String; let scenario: String; let input: Input; let expected: JSONValue }
struct Suite: Decodable { let contractVersion: String; let referenceInstant: Instant; let cases: [Fixture] }
indirect enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Int64), bool(Bool), null
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(Int64.self) { self = .number(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([String: JSONValue].self) { self = .object(x) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let x): try c.encode(x); case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x); case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x); case .null: try c.encodeNil()
        }
    }
}
func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
}
func run(_ fixture: Fixture, reference: Instant) throws -> Data {
    let i = fixture.input; let now = i.referenceInstant ?? reference
    let id = try EntityID("11111111-1111-4111-8111-111111111111")
    let commandId = try EntityID("33333333-3333-4333-8333-333333333333")
    let planner = ChangePlanner(clock: FixedClock(now))
    let tasks = try (i.tasks ?? []).map { try $0.record(at: now) }
    let snapshot = try DomainSnapshot(tasks: tasks)
    func output(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    func update(_ current: DomainSnapshot, _ command: EntityID, title: String) throws -> ChangePreview {
        guard let first = current.tasks.first else { throw DomainError(.invalidArgument, "Fixture needs a task") }
        let batch = try ChangeBatch(commandId: command, source: .ai, issuedAt: now, expectedRevisions: current.revisions,
                                    operations: [.updateTask(first.id, TaskPatch(title: .set(title)))])
        return try planner.preview(batch, in: current)
    }
    switch fixture.scenario {
    case "create":
        let record = try TaskRecord(id: id, title: i.title ?? "", createdAt: now)
        return try output(["title": record.title, "status": record.status.rawValue, "revision": record.revision.value])
    case "graph":
        try DependencyGraph.validate(tasks); return try output(["acyclic": true])
    case "dayInterval":
        guard let day = i.localDate, let zone = i.zoneId else { throw DomainError(.invalidArgument, "Fixture needs date and zone") }
        let interval = try day.interval(in: zone)
        return try output(["durationMs": interval.endExclusive.epochMilliseconds - interval.start.epochMilliseconds])
    case "resolve":
        guard let text = i.expression, let zone = i.zoneId else { throw DomainError(.invalidArgument, "Fixture needs expression and zone") }
        let resolved = try DateResolver().resolve(text, reference: now, zone: zone)
        switch resolved.deadline {
        case .date(let day, let zone, _, _): return try output(["kind": "DATE", "localDate": day.canonical, "zoneId": zone.rawValue])
        case .none: return try output(["kind": "NONE", "uncertainFields": resolved.uncertainFields])
        case .instant: throw DomainError(.invalidArgument, "Unexpected instant")
        }
    case "status":
        guard let task = tasks.first, let target = i.targetStatus else { throw DomainError(.invalidArgument, "Fixture needs task/status") }
        let transition = try TaskRules.transition(task, to: target, in: snapshot, at: now)
        return try output(["status": transition.task.status.rawValue, "completedAt": transition.task.completedAt?.canonical as Any? ?? NSNull()])
    case "confirmation":
        let preview = try update(snapshot, commandId, title: "Edited")
        _ = try planner.commit(preview, current: snapshot, confirmedFingerprint: nil)
        return try output(["unexpected": "committed"])
    case "stale", "undoConflict", "idempotency":
        let preview = try update(snapshot, commandId, title: "First change")
        if fixture.scenario == "stale" {
            let other = try update(snapshot, EntityID("44444444-4444-4444-8444-444444444444"), title: "Concurrent edit")
            let latest = try planner.commit(other, current: snapshot, confirmedFingerprint: other.fingerprint)
            _ = try planner.commit(preview, current: latest.snapshot, confirmedFingerprint: preview.fingerprint)
        } else {
            let committed = try planner.commit(preview, current: snapshot, confirmedFingerprint: preview.fingerprint)
            if fixture.scenario == "idempotency" {
                let replay = try planner.commit(preview, current: committed.snapshot, confirmedFingerprint: nil, prior: committed.appliedRecord)
                return try output(["replayed": replay.replayed, "revision": replay.snapshot.tasks[0].revision.value, "eventCount": replay.events.count])
            }
            let second = try update(committed.snapshot, EntityID("44444444-4444-4444-8444-444444444444"), title: "Later edit")
            let latest = try planner.commit(second, current: committed.snapshot, confirmedFingerprint: second.fingerprint)
            _ = try planner.undo(committed.undoTicket!, commandId: EntityID("55555555-5555-4555-8555-555555555555"), current: latest.snapshot, confirmed: true)
        }
        return try output(["unexpected": "committed"])
    default: throw DomainError(.invalidArgument, "Unknown fixture scenario")
    }
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw DomainError(.invalidArgument, "Usage: domain-fixtures /path/to/m01.json")
    }
    let suite = try JSONDecoder().decode(Suite.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    guard suite.contractVersion == "1.0", !suite.cases.isEmpty else { throw DomainError(.invalidArgument, "Unsupported/empty fixture suite") }
    var failed = 0; var rows: [[String: Any]] = []
    for fixture in suite.cases {
        let actual: Data
        do { actual = try run(fixture, reference: suite.referenceInstant) }
        catch let error as DomainError { actual = try JSONSerialization.data(withJSONObject: ["error": error.code.rawValue], options: .sortedKeys) }
        let expected = try canonical(fixture.expected)
        let ok = try JSONDecoder().decode(JSONValue.self, from: actual) == fixture.expected; if !ok { failed += 1 }
        rows.append(["id": fixture.id, "passed": ok,
                     "expected": try JSONSerialization.jsonObject(with: expected), "actual": try JSONSerialization.jsonObject(with: actual)])
    }
    let report: [String: Any] = ["suite": "M01", "executed": rows.count, "passed": rows.count - failed, "failed": failed, "results": rows]
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    if failed != 0 { exit(1) }
} catch {
    FileHandle.standardError.write(Data("Fixture runner failed: \(error)\n".utf8)); exit(1)
}
