import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case inbox = "INBOX", todo = "TODO", inProgress = "IN_PROGRESS", blocked = "BLOCKED"
    case done = "DONE", deferred = "DEFERRED", archived = "ARCHIVED"
}
public enum ProjectStatus: String, Codable, Sendable { case active = "ACTIVE", onHold = "ON_HOLD", done = "DONE", archived = "ARCHIVED" }
public enum DemandLevel: String, Codable, Sendable { case low = "LOW", medium = "MEDIUM", high = "HIGH" }

public struct TaskRecord: Equatable, Codable, Sendable {
    public let id: EntityID
    public internal(set) var revision: Revision
    public internal(set) var title: String
    public internal(set) var description: String
    public internal(set) var projectId: EntityID?
    public internal(set) var status: TaskStatus
    public internal(set) var deadline: Deadline
    public internal(set) var estimatedDurationMinutes: EstimatedMinutes?
    public internal(set) var actualDurationMs: Int64
    public internal(set) var complexity: DemandLevel?
    public internal(set) var energyRequired: DemandLevel?
    public internal(set) var completionCriteria: String?
    public internal(set) var nextAction: String?
    public internal(set) var dependencyTaskIds: [EntityID]
    public internal(set) var blockedReason: String?
    public internal(set) var archivedFromStatus: TaskStatus?
    public let createdAt: Instant
    public internal(set) var updatedAt: Instant
    public internal(set) var completedAt: Instant?
    public internal(set) var deletedAt: Instant?

    public init(id: EntityID, title: String, description: String = "", projectId: EntityID? = nil,
                status: TaskStatus = .inbox, deadline: Deadline = .none(originalExpression: nil),
                estimatedDurationMinutes: EstimatedMinutes? = nil, actualDurationMs: Int64 = 0,
                complexity: DemandLevel? = nil, energyRequired: DemandLevel? = nil,
                completionCriteria: String? = nil, nextAction: String? = nil,
                dependencyTaskIds: [EntityID] = [], blockedReason: String? = nil,
                archivedFromStatus: TaskStatus? = nil, createdAt: Instant, updatedAt: Instant? = nil,
                completedAt: Instant? = nil, deletedAt: Instant? = nil, revision: Revision? = nil) throws {
        self.id = id; self.title = try validatedTitle(title); self.description = description
        self.projectId = projectId; self.status = status; self.deadline = deadline
        self.estimatedDurationMinutes = estimatedDurationMinutes; self.actualDurationMs = actualDurationMs
        self.complexity = complexity; self.energyRequired = energyRequired
        self.completionCriteria = completionCriteria; self.nextAction = nextAction
        self.dependencyTaskIds = dependencyTaskIds.sorted(); self.blockedReason = blockedReason
        self.archivedFromStatus = archivedFromStatus; self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt; self.completedAt = completedAt; self.deletedAt = deletedAt
        self.revision = try revision ?? Revision(1)
        try validate()
    }
    /// Archiving completed work must not make its prerequisites incomplete again.
    public var fulfillsDependency: Bool {
        deletedAt == nil && (status == .done || (status == .archived && archivedFromStatus == .done))
    }
    func validate() throws {
        try require(title == validatedTitle(title), "Title is not normalized")
        try require(description.unicodeScalars.count <= 100_000, "Description too long")
        for text in [completionCriteria, nextAction, blockedReason].compactMap({ $0 }) {
            try require(text.unicodeScalars.count <= 100_000, "Text too long")
        }
        try require(actualDurationMs >= 0, "Actual duration cannot be negative")
        try require(Set(dependencyTaskIds).count == dependencyTaskIds.count, "Duplicate dependencies")
        try require(updatedAt >= createdAt, "Update precedes creation")
        let effectiveStatus = status == .archived ? archivedFromStatus : status
        try require(status != .archived || (archivedFromStatus != nil && archivedFromStatus != .archived), "Missing archived status")
        try require(status == .archived || archivedFromStatus == nil, "Unexpected archived status")
        if effectiveStatus == .blocked {
            try require(!(blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true), "Blocked task needs a reason")
        } else { try require(blockedReason == nil, "Only blocked tasks retain a blocker") }
        if effectiveStatus == .done {
            guard let completedAt else { throw DomainError(.invalidArgument, "Done task needs completion time") }
            try require(completedAt >= createdAt && completedAt <= updatedAt, "Invalid completion time")
        } else { try require(completedAt == nil, "Non-completed task has completion time") }
        if let deletedAt { try require(deletedAt >= createdAt && deletedAt <= updatedAt, "Invalid deletion time") }
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, revision, title, description, projectId, status, deadline, estimatedDurationMinutes, actualDurationMs
        case complexity, energyRequired, completionCriteria, nextAction, dependencyTaskIds, blockedReason, archivedFromStatus
        case createdAt, updatedAt, completedAt, deletedAt
    }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(EntityID.self, forKey: .id), title: c.decode(String.self, forKey: .title),
                      description: c.decode(String.self, forKey: .description), projectId: c.decodeIfPresent(EntityID.self, forKey: .projectId),
                      status: c.decode(TaskStatus.self, forKey: .status), deadline: c.decode(Deadline.self, forKey: .deadline),
                      estimatedDurationMinutes: c.decodeIfPresent(EstimatedMinutes.self, forKey: .estimatedDurationMinutes),
                      actualDurationMs: c.decode(Int64.self, forKey: .actualDurationMs), complexity: c.decodeIfPresent(DemandLevel.self, forKey: .complexity),
                      energyRequired: c.decodeIfPresent(DemandLevel.self, forKey: .energyRequired), completionCriteria: c.decodeIfPresent(String.self, forKey: .completionCriteria),
                      nextAction: c.decodeIfPresent(String.self, forKey: .nextAction), dependencyTaskIds: c.decode([EntityID].self, forKey: .dependencyTaskIds),
                      blockedReason: c.decodeIfPresent(String.self, forKey: .blockedReason), archivedFromStatus: c.decodeIfPresent(TaskStatus.self, forKey: .archivedFromStatus),
                      createdAt: c.decode(Instant.self, forKey: .createdAt), updatedAt: c.decode(Instant.self, forKey: .updatedAt),
                      completedAt: c.decodeIfPresent(Instant.self, forKey: .completedAt), deletedAt: c.decodeIfPresent(Instant.self, forKey: .deletedAt),
                      revision: c.decode(Revision.self, forKey: .revision))
    }
}

public struct ProjectRecord: Equatable, Codable, Sendable {
    public let id: EntityID
    public internal(set) var revision: Revision
    public internal(set) var name: String
    public internal(set) var description: String
    public internal(set) var objective: String
    public internal(set) var status: ProjectStatus
    public internal(set) var archivedFromStatus: ProjectStatus?
    public internal(set) var deadline: Deadline
    public let createdAt: Instant
    public internal(set) var updatedAt: Instant
    public internal(set) var deletedAt: Instant?
    public init(id: EntityID, name: String, description: String = "", objective: String = "",
                status: ProjectStatus = .active, archivedFromStatus: ProjectStatus? = nil,
                deadline: Deadline = .none(originalExpression: nil), createdAt: Instant, updatedAt: Instant? = nil,
                deletedAt: Instant? = nil, revision: Revision? = nil) throws {
        self.id = id; self.name = try validatedTitle(name); self.description = description; self.objective = objective
        self.status = status; self.archivedFromStatus = archivedFromStatus; self.deadline = deadline
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt; self.deletedAt = deletedAt
        self.revision = try revision ?? Revision(1); try validate()
    }
    func validate() throws {
        try require(name == validatedTitle(name), "Project name is not normalized")
        try require(description.unicodeScalars.count <= 100_000 && objective.unicodeScalars.count <= 100_000, "Project text too long")
        try require(updatedAt >= createdAt, "Update precedes creation")
        try require(status != .archived || (archivedFromStatus != nil && archivedFromStatus != .archived), "Missing archived project state")
        try require(status == .archived || archivedFromStatus == nil, "Unexpected archived state")
        if let deletedAt { try require(deletedAt >= createdAt && deletedAt <= updatedAt, "Invalid deletion time") }
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case id, revision, name, description, objective, status, archivedFromStatus, deadline, createdAt, updatedAt, deletedAt }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(EntityID.self, forKey: .id), name: c.decode(String.self, forKey: .name),
                      description: c.decode(String.self, forKey: .description), objective: c.decode(String.self, forKey: .objective),
                      status: c.decode(ProjectStatus.self, forKey: .status), archivedFromStatus: c.decodeIfPresent(ProjectStatus.self, forKey: .archivedFromStatus),
                      deadline: c.decode(Deadline.self, forKey: .deadline), createdAt: c.decode(Instant.self, forKey: .createdAt),
                      updatedAt: c.decode(Instant.self, forKey: .updatedAt), deletedAt: c.decodeIfPresent(Instant.self, forKey: .deletedAt),
                      revision: c.decode(Revision.self, forKey: .revision))
    }
}
