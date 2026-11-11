import Foundation

public enum PatchField<Value: Codable & Equatable & Sendable>: Equatable, Sendable {
    case unchanged, set(Value), clear
}

public struct TaskPatch: Codable, Equatable, Sendable {
    public var title: PatchField<String>
    public var description: PatchField<String>
    public var projectId: PatchField<EntityID>
    public var deadline: PatchField<Deadline>
    public var estimatedDurationMinutes: PatchField<EstimatedMinutes>
    public var complexity: PatchField<DemandLevel>
    public var energyRequired: PatchField<DemandLevel>
    public var completionCriteria: PatchField<String>
    public var nextAction: PatchField<String>
    public init(title: PatchField<String> = .unchanged, description: PatchField<String> = .unchanged,
                projectId: PatchField<EntityID> = .unchanged, deadline: PatchField<Deadline> = .unchanged,
                estimatedDurationMinutes: PatchField<EstimatedMinutes> = .unchanged,
                complexity: PatchField<DemandLevel> = .unchanged, energyRequired: PatchField<DemandLevel> = .unchanged,
                completionCriteria: PatchField<String> = .unchanged, nextAction: PatchField<String> = .unchanged) {
        self.title = title; self.description = description; self.projectId = projectId; self.deadline = deadline
        self.estimatedDurationMinutes = estimatedDurationMinutes; self.complexity = complexity; self.energyRequired = energyRequired; self.completionCriteria = completionCriteria; self.nextAction = nextAction
    }
    enum Keys: String, CodingKey, CaseIterable { case title, description, projectId, deadline, estimatedDurationMinutes, complexity, energyRequired, completionCriteria, nextAction }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(Keys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: Keys.self)
        func field<T>(_ type: T.Type, _ key: Keys) throws -> PatchField<T> {
            if !c.contains(key) { return .unchanged }; if try c.decodeNil(forKey: key) { return .clear }
            return .set(try c.decode(type, forKey: key))
        }
        self.init(title: try field(String.self, .title), description: try field(String.self, .description),
                  projectId: try field(EntityID.self, .projectId), deadline: try field(Deadline.self, .deadline),
                  estimatedDurationMinutes: try field(EstimatedMinutes.self, .estimatedDurationMinutes),
                  complexity: try field(DemandLevel.self, .complexity), energyRequired: try field(DemandLevel.self, .energyRequired),
                  completionCriteria: try field(String.self, .completionCriteria), nextAction: try field(String.self, .nextAction))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        func put<T>(_ value: PatchField<T>, _ key: Keys) throws {
            switch value { case .unchanged: break; case .clear: try c.encodeNil(forKey: key); case .set(let v): try c.encode(v, forKey: key) }
        }
        try put(title, .title); try put(description, .description); try put(projectId, .projectId); try put(deadline, .deadline)
        try put(estimatedDurationMinutes, .estimatedDurationMinutes); try put(complexity, .complexity); try put(energyRequired, .energyRequired); try put(completionCriteria, .completionCriteria); try put(nextAction, .nextAction)
    }
    func applying(to original: TaskRecord) throws -> TaskRecord {
        var task = original
        switch title { case .set(let v): task.title = try validatedTitle(v); case .clear: throw DomainError(.invalidArgument, "Title cannot be null"); case .unchanged: break }
        switch description { case .set(let v): task.description = v; case .clear: throw DomainError(.invalidArgument, "Description cannot be null"); case .unchanged: break }
        switch projectId { case .set(let v): task.projectId = v; case .clear: task.projectId = nil; case .unchanged: break }
        switch deadline { case .set(let v): task.deadline = v; case .clear: task.deadline = .none(originalExpression: nil); case .unchanged: break }
        switch estimatedDurationMinutes { case .set(let v): task.estimatedDurationMinutes = v; case .clear: task.estimatedDurationMinutes = nil; case .unchanged: break }
        switch complexity { case .set(let v): task.complexity = v; case .clear: task.complexity = nil; case .unchanged: break }
        switch energyRequired { case .set(let v): task.energyRequired = v; case .clear: task.energyRequired = nil; case .unchanged: break }
        switch completionCriteria { case .set(let v): task.completionCriteria = v; case .clear: task.completionCriteria = nil; case .unchanged: break }
        switch nextAction { case .set(let v): task.nextAction = v; case .clear: task.nextAction = nil; case .unchanged: break }
        return task
    }
}

public enum AggregateKind: String, Codable, Sendable { case task = "TASK", project = "PROJECT" }
public struct AggregateKey: Hashable, Codable, Sendable {
    public let kind: AggregateKind
    public let id: EntityID
    public init(_ kind: AggregateKind, _ id: EntityID) { self.kind = kind; self.id = id }
}
public struct AggregateRevision: Equatable, Codable, Sendable {
    public let key: AggregateKey
    public let revision: Revision
    public init(_ key: AggregateKey, _ revision: Revision) { self.key = key; self.revision = revision }
}
public enum ChangeSource: String, Codable, Sendable { case user = "USER", ai = "AI", system = "SYSTEM" }
public enum DomainOperation: Equatable, Sendable, Codable {
    case createTask(TaskRecord)
    case updateTask(EntityID, TaskPatch)
    case setTaskStatus(EntityID, TaskStatus, blockedReason: String?, overrideReason: String?)
    case addDependency(EntityID, prerequisite: EntityID)
    case removeDependency(EntityID, prerequisite: EntityID)
    case deleteTask(EntityID)
    case restoreTask(EntityID)
    case createProject(ProjectRecord)
    case setProjectStatus(EntityID, ProjectStatus)

    enum Keys: String, CodingKey, CaseIterable { case kind, task, project, taskId, projectId, patch, status, blockedReason, overrideReason, prerequisiteId }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(Keys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "CREATE_TASK": self = try .createTask(c.decode(TaskRecord.self, forKey: .task))
        case "UPDATE_TASK": self = try .updateTask(c.decode(EntityID.self, forKey: .taskId), c.decode(TaskPatch.self, forKey: .patch))
        case "SET_TASK_STATUS": self = try .setTaskStatus(c.decode(EntityID.self, forKey: .taskId), c.decode(TaskStatus.self, forKey: .status), blockedReason: c.decodeIfPresent(String.self, forKey: .blockedReason), overrideReason: c.decodeIfPresent(String.self, forKey: .overrideReason))
        case "ADD_DEPENDENCY": self = try .addDependency(c.decode(EntityID.self, forKey: .taskId), prerequisite: c.decode(EntityID.self, forKey: .prerequisiteId))
        case "REMOVE_DEPENDENCY": self = try .removeDependency(c.decode(EntityID.self, forKey: .taskId), prerequisite: c.decode(EntityID.self, forKey: .prerequisiteId))
        case "DELETE_TASK": self = try .deleteTask(c.decode(EntityID.self, forKey: .taskId))
        case "RESTORE_TASK": self = try .restoreTask(c.decode(EntityID.self, forKey: .taskId))
        case "CREATE_PROJECT": self = try .createProject(c.decode(ProjectRecord.self, forKey: .project))
        case "SET_PROJECT_STATUS": self = try .setProjectStatus(c.decode(EntityID.self, forKey: .projectId), c.decode(ProjectStatus.self, forKey: .status))
        default: throw DomainError(.invalidArgument, "Unsupported domain operation")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .createTask(let t): try c.encode("CREATE_TASK", forKey: .kind); try c.encode(t, forKey: .task)
        case .updateTask(let id, let patch): try c.encode("UPDATE_TASK", forKey: .kind); try c.encode(id, forKey: .taskId); try c.encode(patch, forKey: .patch)
        case .setTaskStatus(let id, let status, let reason, let override):
            try c.encode("SET_TASK_STATUS", forKey: .kind); try c.encode(id, forKey: .taskId); try c.encode(status, forKey: .status)
            try c.encode(reason, forKey: .blockedReason); try c.encode(override, forKey: .overrideReason)
        case .addDependency(let id, let p): try c.encode("ADD_DEPENDENCY", forKey: .kind); try c.encode(id, forKey: .taskId); try c.encode(p, forKey: .prerequisiteId)
        case .removeDependency(let id, let p): try c.encode("REMOVE_DEPENDENCY", forKey: .kind); try c.encode(id, forKey: .taskId); try c.encode(p, forKey: .prerequisiteId)
        case .deleteTask(let id): try c.encode("DELETE_TASK", forKey: .kind); try c.encode(id, forKey: .taskId)
        case .restoreTask(let id): try c.encode("RESTORE_TASK", forKey: .kind); try c.encode(id, forKey: .taskId)
        case .createProject(let p): try c.encode("CREATE_PROJECT", forKey: .kind); try c.encode(p, forKey: .project)
        case .setProjectStatus(let id, let status): try c.encode("SET_PROJECT_STATUS", forKey: .kind); try c.encode(id, forKey: .projectId); try c.encode(status, forKey: .status)
        }
    }
}

public struct ChangeBatch: Equatable, Codable, Sendable {
    public let commandId: EntityID
    public let source: ChangeSource
    public let issuedAt: Instant
    public let expectedRevisions: [AggregateRevision]
    public let operations: [DomainOperation]
    public init(commandId: EntityID, source: ChangeSource, issuedAt: Instant, expectedRevisions: [AggregateRevision], operations: [DomainOperation]) throws {
        try require((1...50).contains(operations.count), "A batch needs 1...50 operations")
        try require(Set(expectedRevisions.map(\.key)).count == expectedRevisions.count, "Duplicate revision expectations")
        self.commandId = commandId; self.source = source; self.issuedAt = issuedAt
        self.expectedRevisions = expectedRevisions.sorted { ($0.key.kind.rawValue, $0.key.id.rawValue) < ($1.key.kind.rawValue, $1.key.id.rawValue) }
        self.operations = operations
    }
    enum Keys: String, CodingKey, CaseIterable { case commandId, source, issuedAt, expectedRevisions, operations }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(Keys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: Keys.self)
        try self.init(commandId: c.decode(EntityID.self, forKey: .commandId), source: c.decode(ChangeSource.self, forKey: .source),
                      issuedAt: c.decode(Instant.self, forKey: .issuedAt), expectedRevisions: c.decode([AggregateRevision].self, forKey: .expectedRevisions),
                      operations: c.decode([DomainOperation].self, forKey: .operations))
    }
}
