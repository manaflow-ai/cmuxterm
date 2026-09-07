import Foundation
import Testing
@testable import CMUXAgentLaunch

@MainActor
@Suite("WorkstreamStore")
struct WorkstreamStoreTests {
    @Test("ingest creates a pending item for permission requests")
    func ingestPending() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(.permission("s1", requestId: "r1"))
        #expect(store.items.count == 1)
        #expect(store.pending.count == 1)
        #expect(store.items[0].kind == .permissionRequest)
    }

    @Test("send(.approvePermission) marks the item resolved")
    func resolvePermission() async throws {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(.permission("s1", requestId: "r1"))
        let itemId = store.items[0].id
        try await store.send(.approvePermission(itemId: itemId, mode: .once))
        #expect(store.pending.isEmpty)
        if case .resolved(let decision, _) = store.items[0].status {
            #expect(decision == .permission(.once))
        } else {
            Issue.record("expected .resolved status")
        }
    }

    @Test("Ring buffer evicts oldest items past capacity")
    func ringEviction() {
        let store = WorkstreamStore(ringCapacity: 3)
        for i in 0..<5 {
            store.ingest(.permission("s\(i)", requestId: "r\(i)"))
        }
        #expect(store.items.count == 3)
        #expect(store.items.first?.workstreamId == "s2")
        #expect(store.items.last?.workstreamId == "s4")
    }

    @Test("Exact source event replay updates one item without reopening a resolved decision")
    func exactSourceEventReplayDeduplicates() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "copilot-session",
            hookEventName: .permissionRequest,
            source: "copilot",
            toolName: "shell",
            requestId: "request-1",
            sourceEventId: "native-event-1",
            sourceRevision: "1"
        ))
        let itemId = store.items[0].id
        store.markResolved(itemId, decision: .permission(.once))

        store.ingest(WorkstreamEvent(
            sessionId: "copilot-session",
            hookEventName: .permissionRequest,
            source: "copilot",
            toolName: "shell",
            requestId: "request-2",
            sourceEventId: "native-event-1",
            sourceRevision: "2"
        ))

        #expect(store.items.count == 1)
        #expect(store.items[0].id == itemId)
        #expect(store.items[0].sourceRevision == "2")
        if case .permissionRequest(let requestId, _, _, _) = store.items[0].payload {
            #expect(requestId == "request-1")
        } else {
            Issue.record("expected permission payload")
        }
        if case .resolved = store.items[0].status {} else {
            Issue.record("exact replay must not reopen a resolved item")
        }
    }

    @Test("Source-event replay survives in-process ring eviction")
    func sourceEventReplaySurvivesRingEviction() {
        let store = WorkstreamStore(ringCapacity: 2)
        let first = store.ingest(WorkstreamEvent(
            sessionId: "copilot-session",
            hookEventName: .permissionRequest,
            source: "copilot",
            toolName: "shell",
            requestId: "request-1",
            sourceEventId: "native-event-1"
        ))
        store.markResolved(first.item.id, decision: .permission(.once))
        store.ingest(WorkstreamEvent(
            sessionId: "other-1",
            hookEventName: .stop,
            source: "copilot"
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "other-2",
            hookEventName: .stop,
            source: "copilot"
        ))
        #expect(!store.items.contains { $0.id == first.item.id })

        let replay = store.ingest(WorkstreamEvent(
            sessionId: "copilot-session",
            hookEventName: .permissionRequest,
            source: "copilot",
            toolName: "shell",
            requestId: "request-replay",
            sourceEventId: "native-event-1"
        ))

        #expect(!replay.inserted)
        #expect(replay.item.id == first.item.id)
        if case .resolved(let decision, _) = replay.item.status {
            #expect(decision == .permission(.once))
        } else {
            Issue.record("ring-evicted replay must retain its resolved decision")
        }
        if case .permissionRequest(let requestId, _, _, _) = replay.item.payload {
            #expect(requestId == "request-1")
        } else {
            Issue.record("ring-evicted replay must retain its original request id")
        }
    }

    @Test("Replay state remains bounded during a long process lifetime")
    func replayStateIsBoundedInMemory() {
        let store = WorkstreamStore(ringCapacity: 1)
        for index in 0...WorkstreamDefaultReplayCapacity {
            store.ingest(WorkstreamEvent(
                sessionId: "session-\(index)",
                hookEventName: .stop,
                source: "copilot",
                sourceEventId: "event-\(index)"
            ))
        }

        let oldest = store.ingest(WorkstreamEvent(
            sessionId: "session-0",
            hookEventName: .stop,
            source: "copilot",
            sourceEventId: "event-0"
        ))
        let newest = store.ingest(WorkstreamEvent(
            sessionId: "session-\(WorkstreamDefaultReplayCapacity)",
            hookEventName: .stop,
            source: "copilot",
            sourceEventId: "event-\(WorkstreamDefaultReplayCapacity)"
        ))

        #expect(oldest.inserted)
        #expect(!newest.inserted)
    }

    @Test("Restart replay reconstruction reads only the bounded recent horizon")
    func replayStateIsBoundedAcrossRestart() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-replay-bounded-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        let source = WorkstreamStore(persistence: persistence, ringCapacity: 1)
        for index in 0...WorkstreamDefaultReplayCapacity {
            source.ingest(WorkstreamEvent(
                sessionId: "session-\(index)",
                hookEventName: .stop,
                source: "copilot",
                sourceEventId: "event-\(index)"
            ))
        }
        await source.flushPersistence()

        let restored = WorkstreamStore(persistence: persistence, ringCapacity: 1)
        await restored.start()
        let oldest = restored.ingest(WorkstreamEvent(
            sessionId: "session-0",
            hookEventName: .stop,
            source: "copilot",
            sourceEventId: "event-0"
        ))
        let newest = restored.ingest(WorkstreamEvent(
            sessionId: "session-\(WorkstreamDefaultReplayCapacity)",
            hookEventName: .stop,
            source: "copilot",
            sourceEventId: "event-\(WorkstreamDefaultReplayCapacity)"
        ))

        #expect(oldest.inserted)
        #expect(!newest.inserted)
    }

    @Test("Resolved source-event replay survives restart outside the initial page")
    func resolvedSourceEventReplaySurvivesRestart() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-replay-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        let firstStore = WorkstreamStore(persistence: persistence, ringCapacity: 3)
        let first = firstStore.ingest(WorkstreamEvent(
            sessionId: "copilot-session",
            hookEventName: .permissionRequest,
            source: "copilot",
            toolName: "shell",
            requestId: "request-1",
            sourceEventId: "native-event-1"
        ))
        firstStore.markResolved(first.item.id, decision: .permission(.once))
        for index in 0..<5 {
            firstStore.ingest(WorkstreamEvent(
                sessionId: "other-\(index)",
                hookEventName: .stop,
                source: "copilot"
            ))
        }
        await firstStore.flushPersistence()

        let restoredStore = WorkstreamStore(
            persistence: persistence,
            ringCapacity: 10,
            initialLoadLimit: 2
        )
        await restoredStore.start()
        #expect(!restoredStore.items.contains { $0.id == first.item.id })

        let replay = restoredStore.ingest(WorkstreamEvent(
            sessionId: "copilot-session",
            hookEventName: .permissionRequest,
            source: "copilot",
            toolName: "shell",
            requestId: "request-replay",
            sourceEventId: "native-event-1"
        ))

        #expect(!replay.inserted)
        #expect(replay.item.id == first.item.id)
        if case .resolved(let decision, _) = replay.item.status {
            #expect(decision == .permission(.once))
        } else {
            Issue.record("restored replay must retain its resolved decision")
        }
        if case .permissionRequest(let requestId, _, _, _) = replay.item.payload {
            #expect(requestId == "request-1")
        } else {
            Issue.record("restored replay must retain its original request id")
        }
    }

    @Test("Source event identity remains scoped to producer and workstream")
    func sourceEventIdentityIncludesProducerAndWorkstream() {
        let store = WorkstreamStore(ringCapacity: 10)
        for sessionId in ["one", "two"] {
            store.ingest(WorkstreamEvent(
                sessionId: sessionId,
                hookEventName: .stop,
                source: "copilot",
                sourceEventId: "native-event-1"
            ))
        }
        store.ingest(WorkstreamEvent(
            sessionId: "one",
            hookEventName: .stop,
            source: "codex",
            sourceEventId: "native-event-1"
        ))

        #expect(store.items.count == 3)
    }

    @Test("Events without source identity are never heuristically merged")
    func missingSourceIdentityDoesNotDeduplicate() {
        let store = WorkstreamStore(ringCapacity: 10)
        for sourceEventId in [nil, nil, " ", " "] as [String?] {
            store.ingest(WorkstreamEvent(
                sessionId: "same-session",
                hookEventName: .stop,
                source: "copilot",
                sourceEventId: sourceEventId
            ))
        }

        #expect(store.items.count == 4)
    }

    @Test("Error notifications preserve failure semantics")
    func errorNotificationPreservesFailure() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "copilot-session",
            hookEventName: .notification,
            source: "copilot",
            toolInputJSON: #"{"error":"provider unavailable","errorContext":"model_call"}"#,
            isError: true
        ))

        guard case .toolResult(let toolName, let resultJSON, let isError) = store.items[0].payload else {
            Issue.record("expected tool-result payload")
            return
        }
        #expect(toolName == "notification")
        #expect(resultJSON.contains("provider unavailable"))
        #expect(isError)
    }

    @Test("Persisted source-event updates collapse to the latest row")
    func persistedSourceEventUpdatesCollapse() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-dedupe-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        let latestItemId = UUID()
        let middleItemId = UUID()
        let createdAt = Date(timeIntervalSince1970: 1)
        try await persistence.append(WorkstreamItem(
            id: UUID(),
            workstreamId: "copilot-session",
            source: .copilot,
            kind: .stop,
            createdAt: createdAt,
            updatedAt: Date(timeIntervalSince1970: 2),
            payload: .stop(reason: "first"),
            sourceEventId: "native-event-1",
            sourceRevision: "1"
        ))
        try await persistence.append(WorkstreamItem(
            id: middleItemId,
            workstreamId: "other-session",
            source: .copilot,
            kind: .stop,
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 2),
            payload: .stop(reason: "middle"),
            sourceEventId: "native-event-2",
            sourceRevision: "1"
        ))
        try await persistence.append(WorkstreamItem(
            id: latestItemId,
            workstreamId: "copilot-session",
            source: .copilot,
            kind: .stop,
            createdAt: createdAt,
            updatedAt: Date(timeIntervalSince1970: 3),
            payload: .stop(reason: "second"),
            sourceEventId: "native-event-1",
            sourceRevision: "2"
        ))

        let store = WorkstreamStore(persistence: persistence, ringCapacity: 10)
        await store.start()

        #expect(store.items.count == 2)
        #expect(store.items.map(\.id) == [latestItemId, middleItemId])
        #expect(store.items[0].sourceRevision == "2")
        if case .stop(let reason) = store.items[0].payload {
            #expect(reason == "second")
        } else {
            Issue.record("expected latest persisted stop payload")
        }
    }

    @Test("start loads a small recent slice and pages older persisted rows on demand")
    func lazyLoadPersistedHistory() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-store-page-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        for i in 0..<5 {
            try await persistence.append(WorkstreamItem(
                workstreamId: "s\(i)",
                source: .claude,
                kind: .permissionRequest,
                payload: .permissionRequest(requestId: "r\(i)", toolName: "t", toolInputJSON: "{}", pattern: nil)
            ))
        }

        let store = WorkstreamStore(
            persistence: persistence,
            ringCapacity: 10,
            initialLoadLimit: 2,
            historyPageSize: 2
        )
        await store.start()
        #expect(store.items.map(\.workstreamId) == ["s3", "s4"])
        #expect(store.hasMorePersistedItems)

        await store.loadOlderItems()
        #expect(store.items.map(\.workstreamId) == ["s1", "s2", "s3", "s4"])
        #expect(store.hasMorePersistedItems)

        await store.loadOlderItems()
        #expect(store.items.map(\.workstreamId) == ["s0", "s1", "s2", "s3", "s4"])
        #expect(!store.hasMorePersistedItems)
    }

    @Test("expireAbandonedItems expires items whose agent PID is dead")
    func expireAbandoned() {
        let clock = TestClock(initial: Date(timeIntervalSince1970: 0))
        let store = WorkstreamStore(ringCapacity: 10, clock: { clock.now })
        // Alive agent (pid=1000), dead agent (pid=2000).
        store.ingest(.permission("alive", requestId: "r1", at: clock.now, ppid: 1000))
        store.ingest(.permission("dead", requestId: "r2", at: clock.now, ppid: 2000))
        store.ingest(.permission("untracked", requestId: "r3", at: clock.now))
        // Injected liveness: only 1000 is alive.
        store.expireAbandonedItems { pid in pid == 1000 }
        #expect(store.items.count == 3)
        #expect(store.items[0].status.isPending)
        if case .expired = store.items[1].status {} else {
            Issue.record("dead-pid item should be expired")
        }
        // Item with no ppid: no change (we don't know liveness).
        #expect(store.items[2].status.isPending)
    }

    @Test("expirePending moves stale pending items to expired")
    func expirePending() {
        let clock = TestClock(initial: Date(timeIntervalSince1970: 0))
        let store = WorkstreamStore(ringCapacity: 10, clock: { clock.now })
        store.ingest(.permission("s1", requestId: "r1", at: clock.now))
        clock.advance(200)
        store.expirePending(olderThan: 60)
        if case .expired = store.items[0].status {
            // ok
        } else {
            Issue.record("expected .expired status after timeout")
        }
    }

    @Test("Telemetry items (toolUse) never enter pending")
    func telemetryNeverPending() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .preToolUse,
            source: "claude",
            toolName: "Read"
        ))
        #expect(store.items.count == 1)
        #expect(store.pending.isEmpty)
        #expect(store.items[0].kind == .toolUse)
    }

    @Test("PostToolUse preserves failure status from the wire event")
    func postToolUsePreservesFailureStatus() throws {
        let data = try #require(
            """
            {
              "session_id": "pi-session",
              "hook_event_name": "PostToolUse",
              "_source": "pi",
              "tool_name": "bash",
              "tool_input": {"kind": "object", "key_count": 2},
              "is_error": true
            }
            """.data(using: .utf8)
        )
        let event = try JSONDecoder().decode(WorkstreamEvent.self, from: data)
        let encoded = try JSONEncoder().encode(event)
        let encodedObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(encodedObject["is_error"] as? Bool == true)
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(event)

        let item = try #require(store.items.first)
        if case .toolResult(let toolName, _, let isError) = item.payload {
            #expect(toolName == "bash")
            #expect(isError)
        } else {
            Issue.record("expected PostToolUse to decode as toolResult telemetry")
        }
    }

    @Test("Codex CLI lifecycle feed events stay telemetry")
    func codexLifecycleFeedEventsStayTelemetry() {
        let store = WorkstreamStore(
            ringCapacity: 10,
            titleProvider: { event in
                switch event.hookEventName {
                case .preCompact, .postCompact:
                    return "Compaction"
                case .subagentStart, .subagentStop:
                    return "Subagent"
                default:
                    return nil
                }
            }
        )
        let events: [WorkstreamEvent.HookEventName] = [
            .postToolUse,
            .postToolUseFailure,
            .preCompact,
            .postCompact,
            .subagentStart,
            .subagentStop,
        ]

        for event in events {
            store.ingest(WorkstreamEvent(
                sessionId: "codex-session",
                hookEventName: event,
                source: "codex"
            ))
        }

        #expect(store.items.count == events.count)
        #expect(store.pending.isEmpty)
        #expect(store.items.allSatisfy { $0.status == .telemetry })
        if case .toolResult(_, _, let isError) = store.items[1].payload {
            #expect(isError)
        } else {
            Issue.record("expected PostToolUseFailure to decode as an error tool result")
        }
        #expect(store.items.map(\.title).contains("Compaction"))
        #expect(store.items.map(\.title).contains("Subagent"))
        #expect(!store.items.map(\.title).contains("PreCompact"))
        #expect(!store.items.map(\.title).contains("PostCompact"))
        #expect(!store.items.map(\.title).contains("SubagentStart"))
        #expect(!store.items.contains { $0.kind == .sessionStart })
        #expect(!store.items.contains { $0.kind == .stop })
        if let compactionStartItem = store.items.first(where: {
            $0.title == "Compaction" && $0.kind == .toolUse
        }) {
            if case .toolUse(let toolName, _) = compactionStartItem.payload {
                #expect(toolName == "Compaction")
            } else {
                Issue.record("expected PreCompact to decode as toolUse telemetry")
            }
        } else {
            Issue.record("expected PreCompact item")
        }
        if let subagentStartItem = store.items.first(where: {
            $0.title == "Subagent" && $0.kind == .toolUse
        }) {
            #expect(subagentStartItem.kind == .toolUse)
            if case .toolUse(let toolName, _) = subagentStartItem.payload {
                #expect(toolName == "Subagent")
            } else {
                Issue.record("expected SubagentStart to decode as toolUse telemetry")
            }
        } else {
            Issue.record("expected SubagentStart item")
        }
        if let subagentStopItem = store.items.first(where: {
            $0.title == "Subagent" && $0.kind == .toolResult
        }) {
            #expect(subagentStopItem.kind == .toolResult)
            if case .toolResult(let toolName, _, _) = subagentStopItem.payload {
                #expect(toolName == "Subagent")
            } else {
                Issue.record("expected SubagentStop to decode as toolResult telemetry")
            }
        } else {
            Issue.record("expected SubagentStop item")
        }
    }

    @Test("Telemetry payloads preserve prompt, stop, and todo content")
    func telemetryContent() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .userPromptSubmit,
            source: "claude",
            toolInputJSON: #"{"prompt":"ship it"}"#
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .stop,
            source: "claude",
            toolInputJSON: #"{"reason":"done"}"#
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .todoWrite,
            source: "claude",
            toolInputJSON: #"{"todos":[{"id":"t1","content":"test","status":"in_progress"}]}"#
        ))

        if case .userPrompt(let text) = store.items[0].payload {
            #expect(text == "ship it")
        } else {
            Issue.record("expected user prompt payload")
        }
        if case .stop(let reason) = store.items[1].payload {
            #expect(reason == "done")
        } else {
            Issue.record("expected stop payload")
        }
        if case .todos(let todos) = store.items[2].payload {
            #expect(todos.first?.content == "test")
            #expect(todos.first?.state == .inProgress)
        } else {
            Issue.record("expected todos payload")
        }
    }

    @Test("Prompt context carries into later permission requests")
    func promptContextCarriesIntoPermission() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .userPromptSubmit,
            source: "claude",
            toolInputJSON: #"{"prompt":"demo the permission UI"}"#,
            context: WorkstreamContext(permissionMode: "plan")
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .permissionRequest,
            source: "claude",
            toolName: "Bash",
            toolInputJSON: #"{"command":"echo hi"}"#,
            requestId: "r1"
        ))

        #expect(store.items[1].context?.lastUserMessage == "demo the permission UI")
        #expect(store.items[1].context?.permissionMode == "plan")
    }

    @Test("Exit plan context parses plan JSON")
    func exitPlanParsesContext() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .exitPlanMode,
            source: "claude",
            toolName: "ExitPlanMode",
            toolInputJSON: #"""
            {
              "plan": "# Demo Plan\n\n## Context\nShow the new feed UI.",
              "allowedPrompts": [
                {"tool": "Bash", "prompt": "run reload.sh --tag feedctx"}
              ],
              "planFilePath": "/tmp/demo.md"
            }
            """#,
            context: WorkstreamContext(lastUserMessage: "make a plan"),
            requestId: "plan-1"
        ))

        let item = store.items[0]
        #expect(item.context?.lastUserMessage == "make a plan")
        #expect(item.context?.planSummary == "Show the new feed UI.")
        #expect(item.context?.allowedPrompts.first?.tool == "Bash")
        #expect(item.context?.allowedPrompts.first?.prompt == "run reload.sh --tag feedctx")
    }

    @Test("Legacy workstream ids normalize before context is carried forward")
    func legacyWorkstreamIDMigrationPreservesContext() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-identity-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        let legacyID = "claude-session-with-hyphens"
        let canonicalID = "cmux-feed-v1:canonical-session"
        try await persistence.append(WorkstreamItem(
            workstreamId: legacyID,
            source: .claude,
            kind: .userPrompt,
            payload: .userPrompt(text: "continue the migration")
        ))

        let store = WorkstreamStore(
            persistence: persistence,
            ringCapacity: 10,
            workstreamIDNormalizer: { rawValue, _ in
                rawValue == legacyID ? canonicalID : rawValue
            }
        )
        await store.start()
        #expect(store.items.first?.workstreamId == canonicalID)

        store.ingest(.permission(
            legacyID,
            requestId: "permission-1"
        ))
        #expect(store.items.last?.context?.lastUserMessage == "continue the migration")

        let unknownSourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-unknown-source-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: unknownSourceURL) }
        let persistedUnknown = WorkstreamItem(
            workstreamId: "grok-session",
            source: .claude,
            kind: .userPrompt,
            payload: .userPrompt(text: "raw producer")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var persistedObject = try #require(
            try JSONSerialization.jsonObject(
                with: encoder.encode(persistedUnknown)
            ) as? [String: Any]
        )
        persistedObject["sourceID"] = "grok"
        let persistedData = try JSONSerialization.data(withJSONObject: persistedObject)
        try persistedData.write(to: unknownSourceURL)

        let unknownSourceStore = WorkstreamStore(
            persistence: WorkstreamPersistence(fileURL: unknownSourceURL),
            ringCapacity: 10,
            workstreamIDNormalizer: { rawValue, source in
                source == "grok" ? "canonical-grok" : rawValue
            }
        )
        await unknownSourceStore.start()
        #expect(unknownSourceStore.items.first?.workstreamId == "canonical-grok")
        #expect(unknownSourceStore.items.first?.sourceID == "grok")

        let unknownSourceEventStore = WorkstreamStore(
            ringCapacity: 10,
            workstreamIDNormalizer: { rawValue, source in
                source == "grok" ? "canonical-grok" : rawValue
            }
        )
        unknownSourceEventStore.ingest(WorkstreamEvent(
            sessionId: "grok-session",
            hookEventName: .userPromptSubmit,
            source: "grok",
            toolInputJSON: #"{"prompt":"raw source"}"#
        ))
        #expect(unknownSourceEventStore.items.first?.workstreamId == "canonical-grok")
    }
}

/// Mutable clock wrapper safe to capture by a `@Sendable` closure in tests.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(initial: Date) { _now = initial }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(seconds)
    }
}

private extension WorkstreamEvent {
    static func permission(
        _ sessionId: String,
        requestId: String,
        at date: Date = Date(),
        ppid: Int? = nil
    ) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: sessionId,
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: "Write",
            toolInputJSON: "{}",
            requestId: requestId,
            ppid: ppid,
            receivedAt: date
        )
    }
}
