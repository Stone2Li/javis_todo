import Foundation

public struct ChangePreview: Sendable {
    public let batch: ChangeBatch
    public let candidate: DomainSnapshot
    public let fingerprint: String
    public let affectedAggregates: [AggregateKey]
    public let warnings: [String]
    let base: DomainSnapshot
    let requestFingerprint: String
}
public struct CommitReceipt: Equatable, Codable, Sendable {
    public let commandId: EntityID
    public let revisions: [AggregateRevision]
    public let committedAt: Instant
}
public struct AppliedCommandRecord: Equatable, Codable, Sendable {
    public let commandId: EntityID
    public let requestFingerprint: String
    public let receipt: CommitReceipt
}
public struct EventDraft: Equatable, Sendable {
    public let commandId: EntityID
    public let aggregate: AggregateKey
    public let beforeRevision: Revision?
    public let afterRevision: Revision
    public let source: ChangeSource
    public let isUndo: Bool
    public let dependencyOverrideReasons: [String]
}
public struct UndoTicket: Encodable, Sendable {
    public let originalCommandId: EntityID
    let before: DomainSnapshot
    let after: DomainSnapshot
    let affected: [AggregateKey]
}
public struct PlannedCommit: Sendable {
    public let snapshot: DomainSnapshot
    public let receipt: CommitReceipt
    public let events: [EventDraft]
    public let appliedRecord: AppliedCommandRecord
    public let undoTicket: UndoTicket?
    public let replayed: Bool
}

extension DomainSnapshot {
    public var revisions: [AggregateRevision] {
        projects.map { AggregateRevision(AggregateKey(.project, $0.id), $0.revision) }
        + tasks.map { AggregateRevision(AggregateKey(.task, $0.id), $0.revision) }
    }
    // Only the planner uses transient snapshots; the final public initializer always validates.
    init(transientTasks: [TaskRecord], projects: [ProjectRecord]) {
        self.tasks = transientTasks.sorted { $0.id < $1.id }; self.projects = projects.sorted { $0.id < $1.id }
    }
}

/// Pure planning/validation. M02 must persist snapshot deltas, event IDs and appliedRecord atomically.
/// Fingerprints compare canonical bytes locally. They are neither authentication nor cryptographic tokens.
public struct ChangePlanner: Sendable {
    private let clock: any DomainClock
    public init(clock: any DomainClock) { self.clock = clock }

    public func preview(_ batch: ChangeBatch, in snapshot: DomainSnapshot) throws -> ChangePreview {
        let now = clock.now(); try require(now >= batch.issuedAt, "Command is issued in the future")
        let originalTasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        let originalProjects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
        var tasks = originalTasks; var projects = originalProjects
        let expected = Dictionary(uniqueKeysWithValues: batch.expectedRevisions.map { ($0.key, $0.revision) })
        let initial = Dictionary(uniqueKeysWithValues: snapshot.revisions.map { ($0.key, $0.revision) })
        for item in batch.expectedRevisions {
            guard initial[item.key] == item.revision else { throw DomainError(.revisionConflict, "A supplied revision is stale or missing") }
        }
        var affected: Set<AggregateKey> = []; var warnings: [String] = []
        var statusChecks: [(EntityID, TaskStatus, String?, Bool)] = []
        func existing(_ id: EntityID, allowDeleted: Bool = false) throws -> TaskRecord {
            guard let task = tasks[id] else { throw DomainError(.entityNotFound, "Task not found") }
            try require(allowDeleted || task.deletedAt == nil, "Task is deleted")
            try require(now >= task.updatedAt, "Clock moved backwards"); return task
        }
        for operation in batch.operations {
            switch operation {
            case .createTask(let task):
                guard tasks[task.id] == nil else { throw DomainError(.duplicateEntity, "Task ID already exists") }
                try require(task.revision.value == 1 && task.deletedAt == nil && [.inbox, .todo].contains(task.status), "New task must be an initial inbox/todo record")
                try require(task.createdAt == batch.issuedAt && task.createdAt == task.updatedAt && task.createdAt <= now && task.actualDurationMs == 0, "Invalid initial timestamps")
                tasks[task.id] = task; affected.insert(AggregateKey(.task, task.id))
            case .updateTask(let id, let patch):
                try require(try canonicalData(patch) != Data("{}".utf8), "Empty patch")
                var task = try patch.applying(to: existing(id)); task.updatedAt = now
                tasks[id] = task; affected.insert(AggregateKey(.task, id))
            case .setTaskStatus(let id, let status, let reason, let override):
                let task = try existing(id)
                let transient = DomainSnapshot(transientTasks: Array(tasks.values), projects: Array(projects.values))
                let result = try TaskRules.transition(task, to: status, in: transient, at: now, blockedReason: reason, overrideReason: override)
                tasks[id] = result.task; warnings += result.warnings; affected.insert(AggregateKey(.task, id))
                statusChecks.append((id, result.task.status, override, task.status == .archived))
            case .addDependency(let id, let prerequisite):
                var task = try existing(id)
                try require(!task.dependencyTaskIds.contains(prerequisite), "Dependency already exists")
                task.dependencyTaskIds.append(prerequisite); task.dependencyTaskIds.sort(); task.updatedAt = now
                tasks[id] = task; affected.insert(AggregateKey(.task, id))
            case .removeDependency(let id, let prerequisite):
                var task = try existing(id)
                try require(task.dependencyTaskIds.contains(prerequisite), "Dependency does not exist")
                task.dependencyTaskIds.removeAll { $0 == prerequisite }; task.updatedAt = now
                tasks[id] = task; affected.insert(AggregateKey(.task, id))
            case .deleteTask(let id):
                var task = try existing(id); task.deletedAt = now; task.updatedAt = now; tasks[id] = task
                affected.insert(AggregateKey(.task, id))
                for key in tasks.keys.sorted() where key != id {
                    if var incoming = tasks[key], incoming.deletedAt == nil, incoming.dependencyTaskIds.contains(id) {
                        try require(now >= incoming.updatedAt, "Clock moved backwards")
                        incoming.dependencyTaskIds.removeAll { $0 == id }; incoming.updatedAt = now
                        tasks[key] = incoming; affected.insert(AggregateKey(.task, key))
                    }
                }
            case .restoreTask(let id):
                var task = try existing(id, allowDeleted: true); try require(task.deletedAt != nil, "Task is not deleted")
                task.deletedAt = nil; task.updatedAt = now; tasks[id] = task; affected.insert(AggregateKey(.task, id))
            case .createProject(let project):
                guard projects[project.id] == nil else { throw DomainError(.duplicateEntity, "Project already exists") }
                try require(project.revision.value == 1 && project.deletedAt == nil && project.status == .active, "New project must be active and initial")
                try require(project.createdAt == batch.issuedAt && project.createdAt == project.updatedAt && project.createdAt <= now, "Invalid initial project timestamps")
                projects[project.id] = project; affected.insert(AggregateKey(.project, project.id))
            case .setProjectStatus(let id, let status):
                guard let project = projects[id] else { throw DomainError(.entityNotFound, "Project not found") }
                projects[id] = try ProjectRules.transition(project, to: status, at: now); affected.insert(AggregateKey(.project, id))
            }
        }
        var required = affected
        for key in affected where key.kind == .task {
            for task in [originalTasks[key.id], tasks[key.id]].compactMap({ $0 }) {
                for id in task.dependencyTaskIds { required.insert(AggregateKey(.task, id)) }
                if let owner = task.projectId { required.insert(AggregateKey(.project, owner)) }
            }
        }
        for key in required where initial[key] != nil {
            guard expected[key] == initial[key] else { throw DomainError(.revisionConflict, "Missing revision for a changed or referenced aggregate") }
        }
        // Recheck final prerequisites: a later graph change must not bypass status validation.
        for (id, status, override, restoring) in statusChecks {
            guard let task = tasks[id], task.deletedAt == nil, task.status == status, [.done, .inProgress].contains(status) else { continue }
            let ready = task.dependencyTaskIds.allSatisfy { tasks[$0]?.fulfillsDependency == true }
            if !ready && (status == .inProgress || (!restoring && (override?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))) {
                throw DomainError(.dependencyConflict, "Final graph violates transition prerequisites")
            }
        }
        let keys = affected.sorted { ($0.kind.rawValue, $0.id.rawValue) < ($1.kind.rawValue, $1.id.rawValue) }
        for key in keys {
            switch key.kind {
            case .task:
                var task = tasks[key.id]!
                if let original = originalTasks[key.id] { task.revision = try original.revision.advanced() }
                tasks[key.id] = task
            case .project:
                var project = projects[key.id]!
                if let original = originalProjects[key.id] { project.revision = try original.revision.advanced() }
                projects[key.id] = project
            }
        }
        let candidate = try DomainSnapshot(tasks: Array(tasks.values), projects: Array(projects.values))
        let request = try canonicalData(batch).base64EncodedString()
        let base = try canonicalData(snapshot).base64EncodedString()
        let fingerprint = try canonicalData([request, base]).base64EncodedString()
        return ChangePreview(batch: batch, candidate: candidate, fingerprint: fingerprint, affectedAggregates: keys,
                             warnings: warnings, base: snapshot, requestFingerprint: request)
    }

    public func commit(_ preview: ChangePreview, current: DomainSnapshot, confirmedFingerprint: String?,
                       prior: AppliedCommandRecord? = nil) throws -> PlannedCommit {
        if let replay = try replay(prior, commandId: preview.batch.commandId, request: preview.requestFingerprint, current: current) { return replay }
        guard let confirmedFingerprint else { throw DomainError(.confirmationRequired, "An explicit save/confirmation action is required") }
        guard confirmedFingerprint == preview.fingerprint else { throw DomainError(.previewMismatch, "Confirmation belongs to another preview") }
        guard current == preview.base else { throw DomainError(.revisionConflict, "Snapshot changed after preview; refresh and confirm again") }
        let committedAt = clock.now()
        let refreshed = try ChangePlanner(clock: FixedClock(committedAt)).preview(preview.batch, in: current)
        return makeCommit(before: current, after: refreshed.candidate, affected: refreshed.affectedAggregates,
                          commandId: preview.batch.commandId, source: preview.batch.source,
                          fingerprint: preview.requestFingerprint, isUndo: false, committedAt: committedAt, operations: preview.batch.operations)
    }

    public func undo(_ ticket: UndoTicket, commandId: EntityID, current: DomainSnapshot, confirmed: Bool,
                     prior: AppliedCommandRecord? = nil) throws -> PlannedCommit {
        struct UndoRequest: Encodable { let commandId: EntityID; let ticket: UndoTicket }
        let request = try canonicalData(UndoRequest(commandId: commandId, ticket: ticket)).base64EncodedString()
        if let replay = try replay(prior, commandId: commandId, request: request, current: current) { return replay }
        guard confirmed else { throw DomainError(.confirmationRequired, "Undo requires an explicit user action") }
        guard current == ticket.after else { throw DomainError(.undoConflict, "Later changes prevent a safe undo") }
        let now = clock.now()
        var tasks = Dictionary(uniqueKeysWithValues: current.tasks.map { ($0.id, $0) })
        var projects = Dictionary(uniqueKeysWithValues: current.projects.map { ($0.id, $0) })
        for key in ticket.affected {
            switch key.kind {
            case .task:
                let present = tasks[key.id]!
                try require(now >= present.updatedAt, "Clock moved backwards")
                var restored = ticket.before.tasks.first { $0.id == key.id } ?? present
                if !ticket.before.tasks.contains(where: { $0.id == key.id }) { restored.deletedAt = now; restored.dependencyTaskIds = [] }
                restored.revision = try present.revision.advanced(); restored.updatedAt = now; tasks[key.id] = restored
            case .project:
                let present = projects[key.id]!
                try require(now >= present.updatedAt, "Clock moved backwards")
                var restored = ticket.before.projects.first { $0.id == key.id } ?? present
                if !ticket.before.projects.contains(where: { $0.id == key.id }) { restored.deletedAt = now }
                restored.revision = try present.revision.advanced(); restored.updatedAt = now; projects[key.id] = restored
            }
        }
        return makeCommit(before: current, after: try DomainSnapshot(tasks: Array(tasks.values), projects: Array(projects.values)),
                          affected: ticket.affected, commandId: commandId, source: .user, fingerprint: request, isUndo: true, committedAt: now, operations: [])
    }

    private func replay(_ prior: AppliedCommandRecord?, commandId: EntityID, request: String, current: DomainSnapshot) throws -> PlannedCommit? {
        guard let prior else { return nil }
        guard prior.commandId == commandId && prior.receipt.commandId == commandId && prior.requestFingerprint == request else {
            throw DomainError(.idempotencyConflict, "Command ID already has different content")
        }
        return PlannedCommit(snapshot: current, receipt: prior.receipt, events: [], appliedRecord: prior, undoTicket: nil, replayed: true)
    }
    private func makeCommit(before: DomainSnapshot, after: DomainSnapshot, affected: [AggregateKey], commandId: EntityID,
                            source: ChangeSource, fingerprint: String, isUndo: Bool, committedAt: Instant, operations: [DomainOperation]) -> PlannedCommit {
        let old = Dictionary(uniqueKeysWithValues: before.revisions.map { ($0.key, $0.revision) })
        let new = Dictionary(uniqueKeysWithValues: after.revisions.map { ($0.key, $0.revision) })
        let revisions = affected.map { AggregateRevision($0, new[$0]!) }
        let receipt = CommitReceipt(commandId: commandId, revisions: revisions, committedAt: committedAt)
        let events = affected.map { key in
            let reasons = operations.compactMap { operation -> String? in
                if case .setTaskStatus(let id, .done, _, let reason) = operation,
                   key.kind == .task, id == key.id, let reason,
                   !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return reason }
                return nil
            }
            return EventDraft(commandId: commandId, aggregate: key, beforeRevision: old[key],
                              afterRevision: new[key]!, source: source, isUndo: isUndo,
                              dependencyOverrideReasons: reasons)
        }
        return PlannedCommit(snapshot: after, receipt: receipt, events: events,
                             appliedRecord: AppliedCommandRecord(commandId: commandId, requestFingerprint: fingerprint, receipt: receipt),
                             undoTicket: UndoTicket(originalCommandId: commandId, before: before, after: after, affected: affected), replayed: false)
    }
}
