import XCTest
import Foundation
@testable import JarvisDomain

final class DomainTests: XCTestCase {
    let a = try! EntityID("11111111-1111-4111-8111-111111111111")
    let b = try! EntityID("22222222-2222-4222-8222-222222222222")
    let p = try! EntityID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    let c1 = try! EntityID("33333333-3333-4333-8333-333333333333")
    let c2 = try! EntityID("44444444-4444-4444-8444-444444444444")
    let c3 = try! EntityID("55555555-5555-4555-8555-555555555555")
    let now = try! Instant("2026-11-11T10:00:00.000Z")
    func task(_ id: EntityID? = nil, title: String = "Original", status: TaskStatus = .todo,
              deps: [EntityID] = [], project: EntityID? = nil, revision: Int = 1) throws -> TaskRecord {
        try TaskRecord(id: id ?? a, title: title, projectId: project, status: status, dependencyTaskIds: deps,
                       blockedReason: status == .blocked ? "Waiting" : nil, archivedFromStatus: status == .archived ? .todo : nil,
                       createdAt: now, completedAt: status == .done ? now : nil, revision: Revision(revision))
    }
    var planner: ChangePlanner { ChangePlanner(clock: FixedClock(now)) }
    func batch(_ state: DomainSnapshot, _ operations: [DomainOperation], id: EntityID? = nil, source: ChangeSource = .user) throws -> ChangeBatch {
        try ChangeBatch(commandId: id ?? c1, source: source, issuedAt: now, expectedRevisions: state.revisions, operations: operations)
    }
    func apply(_ state: DomainSnapshot, _ operations: [DomainOperation], id: EntityID? = nil) throws -> PlannedCommit {
        let preview = try planner.preview(batch(state, operations, id: id), in: state)
        return try planner.commit(preview, current: state, confirmedFingerprint: preview.fingerprint)
    }
    func assertCode(_ expected: DomainError.Code, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do { try body(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as DomainError { XCTAssertEqual(error.code, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error \(error)", file: file, line: line) }
    }
    func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)), value)
    }

    func testUUIDAndPositiveValues() throws {
        XCTAssertEqual(try EntityID("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA").rawValue, p.rawValue)
        assertCode(.invalidArgument) { _ = try EntityID("bad") }
        assertCode(.invalidArgument) { _ = try Revision(0) }
        assertCode(.invalidArgument) { _ = try Revision(Int.max).advanced() }
        assertCode(.invalidArgument) { _ = try EstimatedMinutes(0) }
        try roundTrip(EstimatedMinutes(35)); try roundTrip(Revision(4)); try roundTrip(a)
    }
    func testTitleUsesScalarsAndTrimsWhitespace() throws {
        XCTAssertEqual(try task(title: " \n 中文 \t").title, "中文")
        XCTAssertEqual(try task(title: String(repeating: "😀", count: 200)).title.unicodeScalars.count, 200)
        assertCode(.invalidArgument) { _ = try task(title: " \n ") }
        assertCode(.invalidArgument) { _ = try task(title: String(repeating: "e\u{301}", count: 101)) }
    }
    func testInvalidDatesAndZonesFailWithoutNormalization() throws {
        for value in ["2026-02-30", "2026-13-01", "0000-01-01", "２０２６-０１-０１"] {
            assertCode(.invalidArgument) { _ = try LocalDate(value) }
        }
        assertCode(.invalidArgument) { _ = try Instant("2026-02-30T10:00:00.000Z") }
        assertCode(.invalidArgument) { _ = try Instant("2026-11-11T18:00:00.000+08:00") }
        assertCode(.invalidArgument) { _ = try ZoneID("invented/zone") }
        try roundTrip(LocalDate("2028-02-29")); try roundTrip(now)
    }
    func testDSTDayLengthsAndSkippedCivilDay() throws {
        let zone = try ZoneID("America/New_York")
        for (day, hours) in [("2026-03-08", 23), ("2026-11-01", 25)] {
            let bounds = try LocalDate(day).interval(in: zone)
            XCTAssertEqual(bounds.endExclusive.epochMilliseconds - bounds.start.epochMilliseconds, Int64(hours) * 3_600_000)
        }
        assertCode(.invalidArgument) { _ = try LocalDate("2011-12-30").interval(in: ZoneID("Pacific/Apia")) }
    }
    func testRelativeDateUsesCapturedZoneAndTime() throws {
        let result = try DateResolver().resolve("明天", reference: Instant("2026-11-11T16:30:00.000Z"), zone: ZoneID("Asia/Shanghai"))
        guard case .date(let date, _, let source, _) = result.deadline else { return XCTFail("Missing local date") }
        XCTAssertEqual(date.canonical, "2026-11-13"); XCTAssertEqual(source, .explicit)
    }
    func testVagueOrPeriodExpressionDoesNotInventAnInstant() throws {
        let zone = try ZoneID("Asia/Shanghai")
        for text in ["尽快", "有空时", "明天下午", "一些未知日期"] {
            let value = try DateResolver().resolve(text, reference: now, zone: zone)
            XCTAssertEqual(value.deadline, .none(originalExpression: text)); XCTAssertEqual(value.uncertainFields, ["deadline"])
            if text == "明天下午" { XCTAssertEqual(value.suggestedLocalDate?.canonical, "2026-11-12") }
        }
    }
    func testDeadlineAndEntityRoundTrips() throws {
        let zone = try ZoneID("Asia/Shanghai")
        for value: Deadline in [.none(originalExpression: "尽快"), .date(try LocalDate("2026-11-12"), zone: zone, source: .explicit, originalExpression: "明天"), .instant(now, zone: zone, source: .inferred, originalExpression: nil)] {
            try roundTrip(value)
        }
        try roundTrip(task()); try roundTrip(ProjectRecord(id: p, name: "  Project  ", createdAt: now))
        XCTAssertThrowsError(try JSONDecoder().decode(Deadline.self, from: Data(#"{"kind":"NONE","source":"UNKNOWN","originalExpression":null,"instant":"2026-11-11T10:00:00.000Z"}"#.utf8)))
    }
    func testDecodedEntitiesCannotBypassValidation() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task())) as! [String: Any]
        object["actualDurationMs"] = -1
        XCTAssertThrowsError(try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: object)))
        object["actualDurationMs"] = 0; object["status"] = "MAGIC"
        XCTAssertThrowsError(try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    func testAbsentPatchDiffersFromExplicitNull() throws {
        let project = try ProjectRecord(id: p, name: "P", createdAt: now)
        let initial = try DomainSnapshot(tasks: [task(project: p)], projects: [project])
        let unchanged = try JSONDecoder().decode(TaskPatch.self, from: Data(#"{"title":"Changed"}"#.utf8))
        let clear = try JSONDecoder().decode(TaskPatch.self, from: Data(#"{"projectId":null}"#.utf8))
        XCTAssertEqual(unchanged.projectId, .unchanged); XCTAssertEqual(clear.projectId, .clear)
        XCTAssertEqual(try apply(initial, [.updateTask(a, unchanged)]).snapshot.tasks[0].projectId, p)
        XCTAssertNil(try apply(initial, [.updateTask(a, clear)]).snapshot.tasks[0].projectId)
        try roundTrip(clear)
    }
    func testStateTransitionMatrix() throws {
        let allowed: [TaskStatus: Set<TaskStatus>] = [
            .inbox: [.todo, .deferred, .done, .archived], .todo: [.inProgress, .blocked, .deferred, .done, .archived],
            .inProgress: [.todo, .blocked, .deferred, .done, .archived], .blocked: [.todo, .inProgress, .deferred, .done, .archived],
            .deferred: [.todo, .inProgress, .blocked, .done, .archived], .done: [.todo, .archived], .archived: [.todo]
        ]
        for from in TaskStatus.allCases {
            let original = try task(status: from); let snapshot = try DomainSnapshot(tasks: [original])
            for to in TaskStatus.allCases {
                if from == to || allowed[from, default: []].contains(to) {
                    _ = try TaskRules.transition(original, to: to, in: snapshot, at: now, blockedReason: "Waiting")
                } else {
                    assertCode(.invalidTransition) { _ = try TaskRules.transition(original, to: to, in: snapshot, at: now, blockedReason: "Waiting") }
                }
            }
        }
    }
    func testCompletionReopenAndArchiveKeepHistorySemantics() throws {
        let original = try task(); let state = try DomainSnapshot(tasks: [original])
        let done = try TaskRules.transition(original, to: .done, in: state, at: now).task
        XCTAssertEqual(done.completedAt, now)
        let archived = try TaskRules.transition(done, to: .archived, in: DomainSnapshot(tasks: [done]), at: now).task
        XCTAssertEqual(archived.archivedFromStatus, .done); XCTAssertEqual(archived.completedAt, now)
        let restored = try TaskRules.transition(archived, to: .done, in: DomainSnapshot(tasks: [archived]), at: now).task
        let reopened = try TaskRules.transition(restored, to: .todo, in: DomainSnapshot(tasks: [restored]), at: now).task
        XCTAssertNil(reopened.completedAt); XCTAssertNil(reopened.archivedFromStatus)
    }
    func testBlockedReasonAndUnmetDependencies() throws {
        let first = try task(deps: [b]); let prerequisite = try task(b)
        let state = try DomainSnapshot(tasks: [first, prerequisite])
        assertCode(.invalidArgument) { _ = try TaskRules.transition(first, to: .blocked, in: state, at: now) }
        assertCode(.dependencyConflict) { _ = try TaskRules.transition(first, to: .inProgress, in: state, at: now, overrideReason: "not allowed") }
        assertCode(.dependencyConflict) { _ = try TaskRules.transition(first, to: .done, in: state, at: now) }
        XCTAssertEqual(try TaskRules.transition(first, to: .done, in: state, at: now, overrideReason: "Already finished offline").task.status, .done)
    }
    func testSelfCycleIndirectCycleAndMissingDependency() throws {
        assertCode(.dependencyCycle) { try DependencyGraph.validate([task(deps: [a])]) }
        assertCode(.dependencyCycle) { try DependencyGraph.validate([task(deps: [b]), task(b, deps: [a])]) }
        assertCode(.referenceNotFound) { try DependencyGraph.validate([task(deps: [b])]) }
    }
    func testLongDependencyChainDoesNotUseRecursiveDFS() throws {
        let ids = try (1...2_000).map { try EntityID(String(format: "%08x-0000-4000-8000-%012x", $0, $0)) }
        let records = try ids.enumerated().map { index, id in try task(id, deps: index == 0 ? [] : [ids[index - 1]]) }
        try DependencyGraph.validate(records)
    }
    func testPreviewHasNoSideEffectsAndConfirmationIsRequired() throws {
        let state = try DomainSnapshot(tasks: [task()]); let before = state
        let preview = try planner.preview(batch(state, [.updateTask(a, TaskPatch(title: .set("Edited")))], source: .ai), in: state)
        XCTAssertEqual(state, before); XCTAssertEqual(preview.candidate.tasks[0].title, "Edited")
        assertCode(.confirmationRequired) { _ = try planner.commit(preview, current: state, confirmedFingerprint: nil) }
        assertCode(.previewMismatch) { _ = try planner.commit(preview, current: state, confirmedFingerprint: "wrong") }
        XCTAssertEqual(state, before)
    }
    func testMultipleOperationsIncrementAggregateOnce() throws {
        let state = try DomainSnapshot(tasks: [task()])
        let result = try apply(state, [.updateTask(a, TaskPatch(title: .set("Edited"))), .setTaskStatus(a, .done, blockedReason: nil, overrideReason: nil)])
        XCTAssertEqual(result.snapshot.tasks[0].revision.value, 2); XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.snapshot.tasks[0].status, .done); XCTAssertNotNil(result.snapshot.tasks[0].completedAt)
    }
    func testFailedBatchDoesNotPartiallyApply() throws {
        let state = try DomainSnapshot(tasks: [task()]); let before = state
        assertCode(.invalidTransition) {
            _ = try apply(state, [.updateTask(a, TaskPatch(title: .set("Would change"))), .setTaskStatus(a, .inbox, blockedReason: nil, overrideReason: nil)])
        }
        XCTAssertEqual(state, before)
    }
    func testBatchSupportsForwardReferencesAndRejectsCycle() throws {
        let empty = try DomainSnapshot()
        let result = try apply(empty, [.createTask(task(deps: [b])), .createTask(task(b))])
        XCTAssertEqual(result.snapshot.tasks.count, 2)
        assertCode(.dependencyCycle) { _ = try apply(empty, [.createTask(task(deps: [b])), .createTask(task(b, deps: [a]))]) }
        XCTAssertTrue(empty.tasks.isEmpty)
    }
    func testMissingExpectedRevisionIsRejected() throws {
        let state = try DomainSnapshot(tasks: [task()])
        let request = try ChangeBatch(commandId: c1, source: .user, issuedAt: now, expectedRevisions: [], operations: [.updateTask(a, TaskPatch(title: .set("Edited")))])
        assertCode(.revisionConflict) { _ = try planner.preview(request, in: state) }
    }
    func testReferencedAggregateRequiresItsOwnRevision() throws {
        let state = try DomainSnapshot(tasks: [task(deps: [b]), task(b, status: .done)])
        let request = try ChangeBatch(commandId: c1, source: .user, issuedAt: now, expectedRevisions: [AggregateRevision(AggregateKey(.task, a), Revision(1))], operations: [.setTaskStatus(a, .inProgress, blockedReason: nil, overrideReason: nil)])
        assertCode(.revisionConflict) { _ = try planner.preview(request, in: state) }
    }
    func testStalePreviewCannotOverwriteConcurrentEdit() throws {
        let state = try DomainSnapshot(tasks: [task()])
        let old = try planner.preview(batch(state, [.updateTask(a, TaskPatch(title: .set("Old suggestion")))]), in: state)
        let latest = try apply(state, [.updateTask(a, TaskPatch(title: .set("New edit")))], id: c2)
        assertCode(.revisionConflict) { _ = try planner.commit(old, current: latest.snapshot, confirmedFingerprint: old.fingerprint) }
        XCTAssertEqual(latest.snapshot.tasks[0].title, "New edit")
    }
    func testUndoRestoresContentAndAdvancesRevision() throws {
        let state = try DomainSnapshot(tasks: [task()])
        let commit = try apply(state, [.updateTask(a, TaskPatch(title: .set("Edited")))])
        let undo = try planner.undo(commit.undoTicket!, commandId: c2, current: commit.snapshot, confirmed: true)
        XCTAssertEqual(undo.snapshot.tasks[0].title, "Original"); XCTAssertEqual(undo.snapshot.tasks[0].revision.value, 3)
        XCTAssertTrue(undo.events.allSatisfy(\.isUndo))
    }
    func testUndoCreationProducesATombstoneInsteadOfRollingBackRevision() throws {
        let empty = try DomainSnapshot(); let commit = try apply(empty, [.createTask(task())])
        let undone = try planner.undo(commit.undoTicket!, commandId: c2, current: commit.snapshot, confirmed: true)
        XCTAssertEqual(undone.snapshot.tasks[0].revision.value, 2); XCTAssertNotNil(undone.snapshot.tasks[0].deletedAt)
    }
    func testUndoConflictDoesNotOverwriteLaterEdit() throws {
        let state = try DomainSnapshot(tasks: [task()])
        let first = try apply(state, [.updateTask(a, TaskPatch(title: .set("First")))])
        let second = try apply(first.snapshot, [.updateTask(a, TaskPatch(title: .set("Second")))], id: c2)
        assertCode(.undoConflict) { _ = try planner.undo(first.undoTicket!, commandId: c3, current: second.snapshot, confirmed: true) }
        XCTAssertEqual(second.snapshot.tasks[0].title, "Second")
    }
    func testIdempotentReplayPreservesLaterStateAndEmitsNoEvents() throws {
        let state = try DomainSnapshot(tasks: [task()]); let request = try batch(state, [.updateTask(a, TaskPatch(title: .set("First")))])
        let preview = try planner.preview(request, in: state)
        let first = try planner.commit(preview, current: state, confirmedFingerprint: preview.fingerprint)
        let second = try apply(first.snapshot, [.updateTask(a, TaskPatch(title: .set("Later")))], id: c2)
        let replay = try planner.commit(preview, current: second.snapshot, confirmedFingerprint: nil, prior: first.appliedRecord)
        XCTAssertTrue(replay.replayed); XCTAssertTrue(replay.events.isEmpty); XCTAssertEqual(replay.receipt, first.receipt)
        XCTAssertEqual(replay.snapshot, second.snapshot)
    }
    func testReusingCommandIdWithDifferentContentIsRejected() throws {
        let state = try DomainSnapshot(tasks: [task()]); let first = try apply(state, [.updateTask(a, TaskPatch(title: .set("First")))])
        let other = try planner.preview(batch(first.snapshot, [.updateTask(a, TaskPatch(title: .set("Other")))]), in: first.snapshot)
        assertCode(.idempotencyConflict) { _ = try planner.commit(other, current: first.snapshot, confirmedFingerprint: other.fingerprint, prior: first.appliedRecord) }
    }
    func testDeleteCleansIncomingDependenciesAndUndoRestoresThem() throws {
        let state = try DomainSnapshot(tasks: [task(), task(b, deps: [a])])
        let commit = try apply(state, [.deleteTask(a)])
        XCTAssertTrue(try commit.snapshot.task(b).dependencyTaskIds.isEmpty); XCTAssertNotNil(try commit.snapshot.task(a).deletedAt)
        let undo = try planner.undo(commit.undoTicket!, commandId: c2, current: commit.snapshot, confirmed: true)
        XCTAssertEqual(try undo.snapshot.task(b).dependencyTaskIds, [a]); XCTAssertNil(try undo.snapshot.task(a).deletedAt)
        XCTAssertEqual(undo.events.count, 2)
    }
    func testLaterGraphChangeCannotBypassCompletionCheck() throws {
        let state = try DomainSnapshot(tasks: [task(), task(b)])
        assertCode(.dependencyConflict) { _ = try apply(state, [.setTaskStatus(a, .done, blockedReason: nil, overrideReason: nil), .addDependency(a, prerequisite: b)]) }
    }
    func testProjectDoneDoesNotCompleteChildren() throws {
        let project = try ProjectRecord(id: p, name: "P", createdAt: now)
        let state = try DomainSnapshot(tasks: [task(project: p)], projects: [project])
        let commit = try apply(state, [.setProjectStatus(p, .done)])
        XCTAssertEqual(commit.snapshot.projects[0].status, .done); XCTAssertEqual(commit.snapshot.tasks[0].status, .todo)
    }
    func testBatchCodingIsStableAndRejectsDuplicateExpectations() throws {
        let state = try DomainSnapshot(tasks: [task()]); let request = try batch(state, [.updateTask(a, TaskPatch(title: .set("Edited")))])
        try roundTrip(request)
        assertCode(.invalidArgument) { _ = try ChangeBatch(commandId: c1, source: .user, issuedAt: now, expectedRevisions: state.revisions + state.revisions, operations: request.operations) }
    }

    func testUnknownWireFieldsAreNotSilentlyIgnored() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(TaskPatch.self, from: Data(#"{"title":"Edited","sql":"not permitted"}"#.utf8)))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task())) as! [String: Any]
        object["unknownField"] = "unexpected"
        XCTAssertThrowsError(try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    func testBlockedReasonCanBeUpdatedWithoutChangingStatus() throws {
        let original = try task(status: .blocked); let state = try DomainSnapshot(tasks: [original])
        let updated = try TaskRules.transition(original, to: .blocked, in: state, at: now, blockedReason: " Updated reason ").task
        XCTAssertEqual(updated.blockedReason, "Updated reason")
        assertCode(.invalidArgument) { _ = try TaskRules.transition(original, to: .blocked, in: state, at: now, blockedReason: " ") }
    }
    func testStatusTransitionRejectsAMismatchedSnapshot() throws {
        let original = try task(); let other = try task(title: "Other", revision: 2)
        let state = try DomainSnapshot(tasks: [other])
        assertCode(.revisionConflict) { _ = try TaskRules.transition(original, to: .done, in: state, at: now) }
    }
    func testNewTasksCannotInjectActualWorkTime() throws {
        let empty = try DomainSnapshot()
        let forged = try TaskRecord(id: a, title: "New task", actualDurationMs: 999, createdAt: now)
        assertCode(.invalidArgument) { _ = try apply(empty, [.createTask(forged)]) }
        XCTAssertEqual(try EstimatedMinutes(2880).value, 2880)
    }
    func testUndoRetryIsIdempotentAndPreservesRevision() throws {
        let state = try DomainSnapshot(tasks: [task()])
        let first = try apply(state, [.updateTask(a, TaskPatch(title: .set("Edited")))])
        let undo = try planner.undo(first.undoTicket!, commandId: c2, current: first.snapshot, confirmed: true)
        let replay = try planner.undo(first.undoTicket!, commandId: c2, current: undo.snapshot, confirmed: false, prior: undo.appliedRecord)
        XCTAssertTrue(replay.replayed); XCTAssertEqual(replay.snapshot, undo.snapshot); XCTAssertTrue(replay.events.isEmpty)
    }

    func testCommitUsesOneClockSampleForDataAndReceipt() throws {
        let later = try Instant(epochMilliseconds: now.epochMilliseconds + 1000)
        let earlier = try Instant(epochMilliseconds: now.epochMilliseconds - 1000)
        let clock = SequenceClock([now, later, earlier])
        let engine = ChangePlanner(clock: clock)
        let state = try DomainSnapshot(tasks: [task()])
        let preview = try engine.preview(batch(state, [.setTaskStatus(a, .done, blockedReason: nil, overrideReason: nil)]), in: state)
        let result = try engine.commit(preview, current: state, confirmedFingerprint: preview.fingerprint)
        XCTAssertEqual(result.receipt.committedAt, later)
        XCTAssertEqual(result.snapshot.tasks[0].updatedAt, later)
        XCTAssertEqual(result.snapshot.tasks[0].completedAt, later)
    }
    func testCompletionOverrideReasonSurvivesInAuditDraft() throws {
        let state = try DomainSnapshot(tasks: [task(deps: [b]), task(b)])
        let result = try apply(state, [.setTaskStatus(a, .done, blockedReason: nil, overrideReason: "Already completed offline")])
        XCTAssertEqual(result.events.first?.dependencyOverrideReasons, ["Already completed offline"])
    }
    func testOptionalDemandPatchRoundTripAndClear() throws {
        let patch = TaskPatch(complexity: .set(.high), energyRequired: .set(.low))
        try roundTrip(patch)
        let state = try DomainSnapshot(tasks: [task()])
        let first = try apply(state, [.updateTask(a, patch)])
        XCTAssertEqual(first.snapshot.tasks[0].complexity, .high)
        let cleared = try apply(first.snapshot, [.updateTask(a, TaskPatch(complexity: .clear, energyRequired: .clear))], id: c2)
        XCTAssertNil(cleared.snapshot.tasks[0].complexity); XCTAssertNil(cleared.snapshot.tasks[0].energyRequired)
    }

    func testArchivingCompletedPrerequisiteDoesNotBlockDependent() throws {
        let done = try task(status: .done)
        let archived = try TaskRules.transition(done, to: .archived, in: DomainSnapshot(tasks: [done]), at: now).task
        let dependent = try task(b, deps: [a])
        let state = try DomainSnapshot(tasks: [archived, dependent])
        XCTAssertTrue(archived.fulfillsDependency)
        let result = try apply(state, [.setTaskStatus(b, .inProgress, blockedReason: nil, overrideReason: nil)])
        XCTAssertEqual(try result.snapshot.task(b).status, .inProgress)
        let notDone = try task(status: .archived)
        XCTAssertFalse(notDone.fulfillsDependency)
        let incompleteState = try DomainSnapshot(tasks: [notDone, dependent])
        assertCode(.dependencyConflict) { _ = try apply(incompleteState, [.setTaskStatus(b, .inProgress, blockedReason: nil, overrideReason: nil)]) }
    }

}

private final class SequenceClock: DomainClock, @unchecked Sendable {
    private let lock = NSLock()
    private let values: [Instant]
    private var index = 0
    init(_ values: [Instant]) { self.values = values }
    func now() -> Instant {
        lock.lock(); defer { lock.unlock() }
        let value = values[min(index, values.count - 1)]; index += 1; return value
    }
}
