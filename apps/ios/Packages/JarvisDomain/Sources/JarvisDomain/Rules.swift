import Foundation

public enum DependencyGraph {
    /// Kahn's algorithm avoids recursion limits for long dependency chains.
    public static func validate(_ tasks: [TaskRecord]) throws {
        var active: [EntityID: TaskRecord] = [:]
        var allIDs: Set<EntityID> = []
        for task in tasks {
            guard allIDs.insert(task.id).inserted else { throw DomainError(.duplicateEntity, "Duplicate task ID") }
            if task.deletedAt == nil { active[task.id] = task }
        }
        var degree: [EntityID: Int] = [:]; var followers: [EntityID: [EntityID]] = [:]
        for task in active.values {
            degree[task.id] = task.dependencyTaskIds.count
            for dependency in task.dependencyTaskIds {
                guard active[dependency] != nil else { throw DomainError(.referenceNotFound, "Dependency does not exist or is deleted") }
                followers[dependency, default: []].append(task.id)
            }
        }
        var ready = degree.filter { $0.value == 0 }.map(\.key).sorted(); var index = 0
        while index < ready.count {
            let id = ready[index]; index += 1
            for next in followers[id, default: []] {
                degree[next]! -= 1
                if degree[next] == 0 { ready.append(next) }
            }
        }
        guard index == active.count else { throw DomainError(.dependencyCycle, "Task dependencies contain a cycle") }
    }
}

public struct DomainSnapshot: Equatable, Codable, Sendable {
    public let tasks: [TaskRecord]
    public let projects: [ProjectRecord]
    public init(tasks: [TaskRecord] = [], projects: [ProjectRecord] = []) throws {
        try require(Set(projects.map(\.id)).count == projects.count, "Duplicate project IDs")
        for project in projects { try project.validate() }
        let projectMap = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        for task in tasks {
            try task.validate()
            if task.deletedAt == nil, let projectId = task.projectId {
                guard let owner = projectMap[projectId], owner.deletedAt == nil else { throw DomainError(.referenceNotFound, "Task project missing") }
            }
        }
        try DependencyGraph.validate(tasks)
        self.tasks = tasks.sorted { $0.id < $1.id }; self.projects = projects.sorted { $0.id < $1.id }
    }
    public func task(_ id: EntityID) throws -> TaskRecord {
        guard let task = tasks.first(where: { $0.id == id }) else { throw DomainError(.entityNotFound, "Task not found") }
        return task
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case tasks, projects }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(tasks: c.decode([TaskRecord].self, forKey: .tasks), projects: c.decode([ProjectRecord].self, forKey: .projects))
    }
}

public struct TaskTransition: Equatable, Sendable {
    public let task: TaskRecord
    public let warnings: [String]
}
public enum TaskRules {
    public static func transition(_ task: TaskRecord, to requested: TaskStatus, in snapshot: DomainSnapshot,
                                  at now: Instant, blockedReason: String? = nil, overrideReason: String? = nil) throws -> TaskTransition {
        try require(task.deletedAt == nil, "Deleted task must be restored first")
        try require(now >= task.updatedAt, "Clock precedes latest update")
        guard try snapshot.task(task.id) == task else { throw DomainError(.revisionConflict, "Transition task does not match snapshot") }
        if task.status == requested {
            if requested == .blocked, let blockedReason {
                var revised = task; revised.blockedReason = blockedReason.trimmingCharacters(in: .whitespacesAndNewlines)
                revised.updatedAt = now; try revised.validate(); return TaskTransition(task: revised, warnings: [])
            }
            return TaskTransition(task: task, warnings: [])
        }
        let table: [TaskStatus: Set<TaskStatus>] = [
            .inbox: [.todo, .deferred, .done, .archived],
            .todo: [.inProgress, .blocked, .deferred, .done, .archived],
            .inProgress: [.todo, .blocked, .deferred, .done, .archived],
            .blocked: [.todo, .inProgress, .deferred, .done, .archived],
            .deferred: [.todo, .inProgress, .blocked, .done, .archived],
            .done: [.todo, .archived]
        ]
        var next = requested; var warnings: [String] = []
        let dependenciesDone = try task.dependencyTaskIds.allSatisfy { try snapshot.task($0).fulfillsDependency }
        if task.status == .archived {
            guard requested == task.archivedFromStatus else { throw DomainError(.invalidTransition, "Restore the pre-archive status") }
            if requested == .inProgress && !dependenciesDone { next = .todo; warnings.append("RESTORED_AS_TODO") }
        } else if table[task.status]?.contains(requested) != true {
            throw DomainError(.invalidTransition, "Task status transition is not allowed")
        }
        if next == .inProgress && !dependenciesDone { throw DomainError(.dependencyConflict, "Prerequisites are not complete") }
        if next == .done && task.status != .archived && !dependenciesDone {
            guard !(overrideReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
                throw DomainError(.dependencyConflict, "Completion needs an explicit dependency override reason")
            }
        }
        var result = task; result.status = next; result.updatedAt = now
        if next == .archived { result.archivedFromStatus = task.status }
        else {
            result.archivedFromStatus = nil
            result.blockedReason = next == .blocked ? (task.status == .archived ? task.blockedReason : blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
            result.completedAt = next == .done ? (task.completedAt ?? now) : nil
        }
        try result.validate(); return TaskTransition(task: result, warnings: warnings)
    }
}

public enum ProjectRules {
    public static func transition(_ project: ProjectRecord, to status: ProjectStatus, at now: Instant) throws -> ProjectRecord {
        try require(project.deletedAt == nil && now >= project.updatedAt, "Project is deleted or clock invalid")
        if status == project.status { return project }
        if project.status == .archived {
            guard status == project.archivedFromStatus else { throw DomainError(.invalidTransition, "Restore original project state") }
        } else {
            let allowed: [ProjectStatus: Set<ProjectStatus>] = [
                .active: [.onHold, .done, .archived], .onHold: [.active, .done, .archived], .done: [.active, .archived]
            ]
            guard allowed[project.status]?.contains(status) == true else { throw DomainError(.invalidTransition, "Invalid project transition") }
        }
        var result = project; result.status = status; result.updatedAt = now
        result.archivedFromStatus = status == .archived ? project.status : nil
        try result.validate(); return result
    }
}
