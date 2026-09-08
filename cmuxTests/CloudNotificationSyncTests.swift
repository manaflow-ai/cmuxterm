import Foundation
import Testing
#if DEBUG
@testable import cmux_DEV
#else
@testable import cmux
#endif

/// The Cloud notification sync must converge on one invariant under any
/// sequence of feed replays, evictions, reads on other clients, local reads,
/// failed and successful acknowledgements, and app restarts: a retained row
/// is delivered here at most once, every local read of a retained unread row
/// is acknowledged exactly once, and the unread set the tree shows equals the
/// rows this client has neither read nor acknowledged.
@Suite("CloudNotificationSync")
struct CloudNotificationSyncTests {
    private static let me = "mac-a"

    private static func row(
        _ id: String,
        terminal: String? = "term_00000000000000000000000000000001",
        readBy: [String] = [],
        createdAt: UInt64 = 1
    ) -> CloudVMNotificationRow {
        CloudVMNotificationRow(
            id: "notification_\(id.padding(toLength: 32, withPad: "0", startingAt: 0))",
            title: "title \(id)",
            body: "",
            level: "info",
            createdAtMs: createdAt,
            terminalID: terminal,
            readBy: readBy
        )
    }

    @Test func rowDecodesTheDaemonShapeAndToleratesOlderDaemons() throws {
        let object: [String: Any] = [
            "id": "notification_0000000000000000000000000000abcd",
            "session_id": "session_00000000000000000000000000000001",
            "title": "Claude needs approval",
            "body": "Bash",
            "level": "warning",
            "created_at_ms": "1725000000000",
            "unread": true,
            "read_by": ["mac-b", "phone-c"],
            "terminal_id": "term_00000000000000000000000000000009",
        ]
        let row = try #require(CloudVMNotificationRow.row(fromObject: object))
        #expect(row.id == "notification_0000000000000000000000000000abcd")
        #expect(row.title == "Claude needs approval")
        #expect(row.body == "Bash")
        #expect(row.level == "warning")
        #expect(row.createdAtMs == 1_725_000_000_000)
        #expect(row.terminalID == "term_00000000000000000000000000000009")
        #expect(row.readBy == ["mac-b", "phone-c"])
        #expect(row.isRead(by: "mac-b"))
        #expect(!row.isRead(by: Self.me))

        // A daemon from before per-client reads publishes no read_by.
        var legacy = object
        legacy.removeValue(forKey: "read_by")
        legacy["created_at_ms"] = 42
        let old = try #require(CloudVMNotificationRow.row(fromObject: legacy))
        #expect(old.readBy.isEmpty)
        #expect(old.createdAtMs == 42)
        #expect(CloudVMNotificationRow.row(fromObject: ["title": "no id"]) == nil)
    }

    @Test func rowsComeFromTheAcceptedStateDocument() throws {
        let snapshot: [String: Any] = [
            "machine": ["id": "machine_00000000000000000000000000000001", "name": "m", "origin": "local", "status": "running", "connectable": true, "deleted": false, "recoverable": false],
            "session": ["id": "session_00000000000000000000000000000001", "machine_id": "machine_00000000000000000000000000000001", "name": "main", "revision": "7"],
            "workspaces": [], "screens": [], "panes": [], "tabs": [], "terminals": [], "browsers": [], "agents": [],
            "notifications": [
                ["id": "notification_00000000000000000000000000000002", "session_id": "session_00000000000000000000000000000001", "title": "second", "body": "", "level": "info", "created_at_ms": "20", "unread": true, "read_by": []],
                ["id": "notification_00000000000000000000000000000001", "session_id": "session_00000000000000000000000000000001", "title": "first", "body": "", "level": "info", "created_at_ms": "10", "unread": false, "read_by": ["mac-a"]],
            ],
            "cursor": ["generation": "gen-1", "revision": "7"],
        ]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: .cloud("vm-1")))
        let rows = CloudVMNotificationRow.rows(from: state)
        #expect(rows.map(\.title) == ["first", "second"], "rows sort oldest first by created_at_ms")
        #expect(rows[0].readBy == ["mac-a"])
    }

    @Test func planDeliversEachUnreadRowOnceAndNeverRowsOtherClientsReadForUs() {
        let a = Self.row("a")
        let b = Self.row("b", readBy: [Self.me])
        let c = Self.row("c", readBy: ["mac-b"])
        var state = CloudNotificationSyncState()

        let first = CloudNotificationSyncReducer.plan(rows: [a, b, c], clientID: Self.me, state: state)
        #expect(first.deliver.map(\.id) == [a.id, c.id], "b was read by this client on the machine; c only by another client")
        state = first.state

        // A snapshot repair replays the same rows: nothing is delivered twice.
        let replay = CloudNotificationSyncReducer.plan(rows: [a, b, c], clientID: Self.me, state: state)
        #expect(replay.deliver.isEmpty)
        #expect(replay.state == state)

        // Restart: the durable state alone must prevent re-delivery.
        let data = try! JSONEncoder().encode(state)
        let restored = try! JSONDecoder().decode(CloudNotificationSyncState.self, from: data)
        let afterRestart = CloudNotificationSyncReducer.plan(rows: [a, b, c], clientID: Self.me, state: restored)
        #expect(afterRestart.deliver.isEmpty)

        // Eviction drops bookkeeping; a new row on the same terminal still delivers.
        let d = Self.row("d")
        let evicted = CloudNotificationSyncReducer.plan(rows: [c, d], clientID: Self.me, state: state)
        #expect(evicted.deliver.map(\.id) == [d.id])
        #expect(Set(evicted.state.delivered) == [c.id, d.id])
    }

    @Test func readsBecomeOneStableBatchThatSurvivesFailedSends() {
        let a = Self.row("a")
        let b = Self.row("b")
        let rows = [a, b]
        var state = CloudNotificationSyncReducer.plan(rows: rows, clientID: Self.me, state: CloudNotificationSyncState()).state
        var keys = ["k1", "k2", "k3"]
        let mint = { keys.removeFirst() }

        state = CloudNotificationSyncReducer.recordRead(ids: [a.id, a.id, "notification_unknown"], rows: rows, clientID: Self.me, state: state, newKey: mint)
        #expect(state.pendingAcks == [.init(key: "k1", ids: [a.id])], "duplicates and unknown ids never enter a batch")
        #expect(CloudNotificationSyncReducer.unreadTerminalIDs(rows: rows, clientID: Self.me, state: state) == [b.terminalID!],
                "a is pending, so the tree no longer shows it as unread")

        // Reading a again while pending mints nothing new: the key is stable across retries.
        let again = CloudNotificationSyncReducer.recordRead(ids: [a.id], rows: rows, clientID: Self.me, state: state, newKey: mint)
        #expect(again == state)
        #expect(keys == ["k2", "k3"])

        state = CloudNotificationSyncReducer.recordRead(ids: [b.id], rows: rows, clientID: Self.me, state: state, newKey: mint)
        #expect(state.pendingAcks.map(\.key) == ["k1", "k2"])
        #expect(CloudNotificationSyncReducer.unreadTerminalIDs(rows: rows, clientID: Self.me, state: state).isEmpty)

        // The daemon confirms k1; the feed then shows read_by for a; k2 stays.
        state = CloudNotificationSyncReducer.ackCompleted(key: "k1", state: state)
        let confirmed = [Self.row("a", readBy: [Self.me]), b]
        let next = CloudNotificationSyncReducer.plan(rows: confirmed, clientID: Self.me, state: state)
        #expect(next.deliver.isEmpty)
        #expect(next.state.pendingAcks.map(\.key) == ["k2"])

        // A row read on the machine by this client from another surface is
        // already acknowledged: no batch is minted for it.
        let none = CloudNotificationSyncReducer.recordRead(ids: [confirmed[0].id], rows: confirmed, clientID: Self.me, state: next.state, newKey: mint)
        #expect(none == next.state)
    }

    @Test func evictionPrunesPendingIDsButKeepsTheRestOfTheBatch() {
        let a = Self.row("a")
        let b = Self.row("b")
        var state = CloudNotificationSyncReducer.plan(rows: [a, b], clientID: Self.me, state: CloudNotificationSyncState()).state
        state = CloudNotificationSyncReducer.recordRead(ids: [a.id, b.id], rows: [a, b], clientID: Self.me, state: state, newKey: { "k" })
        let afterEviction = CloudNotificationSyncReducer.plan(rows: [b], clientID: Self.me, state: state).state
        #expect(afterEviction.pendingAcks == [.init(key: "k", ids: [b.id])])
        let allGone = CloudNotificationSyncReducer.plan(rows: [], clientID: Self.me, state: state).state
        #expect(allGone.pendingAcks.isEmpty)
        #expect(allGone.delivered.isEmpty)
    }

    @Test func correlationKeysRoundTripThroughTheLocalStore() throws {
        let key = CloudNotificationCorrelation.key(machineID: "vm-1", notificationID: "notification_0000000000000000000000000000000a")
        let parsed = try #require(CloudNotificationCorrelation.parse(key))
        #expect(parsed.machineID == "vm-1")
        #expect(parsed.notificationID == "notification_0000000000000000000000000000000a")
        #expect(CloudNotificationCorrelation.parse("cursor-approval:1") == nil)
        #expect(CloudNotificationCorrelation.parse("cloud-notification:") == nil)

        let workspace = UUID()
        func notification(_ correlation: String?, read: Bool) -> TerminalNotification {
            TerminalNotification(
                id: UUID(),
                tabId: workspace,
                surfaceId: nil,
                panelId: nil,
                retargetsToLiveSurfaceOwner: false,
                correlationKey: correlation,
                title: "t",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: read
            )
        }
        let cloudA = CloudNotificationCorrelation.key(machineID: "vm-1", notificationID: "a")
        let cloudB = CloudNotificationCorrelation.key(machineID: "vm-1", notificationID: "b")
        let before = CloudNotificationSyncHub.newlyReadKeys(
            previous: [],
            current: [notification(cloudA, read: false), notification(cloudB, read: false), notification("local", read: false)]
        )
        #expect(before.unread == [cloudA, cloudB], "local notifications never become acks")
        // A read and a dismissal (gone from the list) both count as read.
        let after = CloudNotificationSyncHub.newlyReadKeys(
            previous: before.unread,
            current: [notification(cloudA, read: true), notification("local", read: false)]
        )
        #expect(after.read == [cloudA, cloudB])
        #expect(after.unread.isEmpty)
    }

    @Test func ackArgumentsPinTheBatchKeyAndClient() {
        let arguments = CloudTuiCommandLine.notificationAckArguments(
            socketPath: "/tmp/s.sock",
            clientID: "mac-1",
            notificationIDs: ["notification_1", "notification_2"],
            idempotencyKey: "mac-ack-k"
        )
        #expect(arguments == [
            "--socket", "/tmp/s.sock", "--json", "--idempotency-key", "mac-ack-k",
            "notification", "ack", "--client", "mac-1", "notification_1", "notification_2",
        ])
        #expect(CloudTuiClientPaths.isValidNotificationClientID("mac-0123abcd"))
        #expect(!CloudTuiClientPaths.isValidNotificationClientID("has space"))
        #expect(!CloudTuiClientPaths.isValidNotificationClientID(""))
        #expect(!CloudTuiClientPaths.isValidNotificationClientID(String(repeating: "a", count: 129)))
    }

    /// Drives the live sync with injected effects: a flaky sender, a resolver
    /// that sometimes has no local placement, feed replays, evictions, other
    /// clients reading, and restarts through the durable store. Every step
    /// checks the invariant.
    @Test @MainActor func syncConvergesUnderRandomFaults() async throws {
        let defaults = try #require(UserDefaults(suiteName: "cmux.tests.cloud-notification-sync.\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "") }
        let store = CloudNotificationSyncStore(defaults: defaults)
        let machineID = "vm-fuzz"
        let clients = ["mac-b", "phone-c"]
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> UInt64 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return seed
        }

        final class Effects {
            var delivered: [String] = []
            var acked: [String: [String]] = [:] // key -> ids
            var sendFails = false
            var hasPlacement = true
            var unread: Set<String> = []
        }
        let effects = Effects()
        let workspace = UUID()
        let terminals = (1...4).map { "term_\(String(repeating: "0", count: 31))\($0)" }
        var keyCounter = 0

        func makeSync() -> CloudNotificationSync {
            CloudNotificationSync(
                machineID: machineID,
                clientID: Self.me,
                store: store,
                newKey: { keyCounter += 1; return "k\(keyCounter)" },
                resolveTarget: { _ in effects.hasPlacement ? CloudNotificationDeliveryTarget(workspaceID: workspace, panelID: nil) : nil },
                deliver: { row, _ in effects.delivered.append(row.id) },
                send: { batch in
                    if effects.sendFails { throw CancellationError() }
                    effects.acked[batch.key, default: []] += batch.ids
                },
                unreadChanged: { effects.unread = $0 }
            )
        }

        var sync = makeSync()
        var rows: [CloudVMNotificationRow] = []
        var counter = 0
        var readByMe: Set<String> = []          // acknowledged on the machine (simulated daemon)
        var locallyRead: Set<String> = []        // rows this Mac read

        func machineApplyAcks() {
            // The simulated daemon folds confirmed acks into read_by.
            for ids in effects.acked.values {
                for id in ids { readByMe.insert(id) }
            }
            rows = rows.map { row in
                var row = row
                if readByMe.contains(row.id), !row.readBy.contains(Self.me) { row.readBy.append(Self.me) }
                return row
            }
        }

        for step in 0..<300 {
            switch next() % 12 {
            case 0...3:
                counter += 1
                rows.append(Self.row("n\(counter)", terminal: terminals[Int(next() % 4)], createdAt: UInt64(counter)))
                if rows.count > 40 { rows.removeFirst() }
            case 4 where !rows.isEmpty:
                // Another client reads one row on the machine.
                let index = Int(next() % UInt64(rows.count))
                let other = clients[Int(next() % 2)]
                if !rows[index].readBy.contains(other) { rows[index].readBy.append(other) }
            case 5 where !rows.isEmpty:
                // This Mac reads a row it was shown.
                let candidates = rows.filter { effects.delivered.contains($0.id) }
                if let pick = candidates.isEmpty ? nil : candidates[Int(next() % UInt64(candidates.count))] {
                    locallyRead.insert(pick.id)
                    sync.noteRead(notificationIDs: [pick.id])
                    await Task.yield()
                }
            case 6:
                effects.sendFails.toggle()
                sync.linkDidConnect()
                await Task.yield()
            case 7:
                effects.hasPlacement.toggle()
            case 8:
                // Restart: a fresh sync over the durable store.
                sync = makeSync()
            default:
                break
            }
            machineApplyAcks()
            sync.apply(rows: rows)
            await Task.yield()
            await Task.yield()

            // Invariant 1: at most one delivery per retained id, and only for rows not read by me.
            let deliveredCounts = Dictionary(effects.delivered.map { ($0, 1) }, uniquingKeysWith: +)
            #expect(deliveredCounts.values.allSatisfy { $0 == 1 }, "step \(step): a row was delivered twice")
            // Invariant 2: every local read of a retained row is pending or acknowledged.
            let ackedIDs = Set(effects.acked.values.flatMap { $0 })
            let pending = sync.state.pendingIDs
            for id in locallyRead where rows.contains(where: { $0.id == id }) {
                #expect(pending.contains(id) || ackedIDs.contains(id) || readByMe.contains(id), "step \(step): read \(id) was lost")
            }
            // Invariant 3: the unread set is exactly what the reducer computes from the durable state.
            let expected = CloudNotificationSyncReducer.unreadTerminalIDs(rows: rows, clientID: Self.me, state: sync.state)
            #expect(sync.unreadTerminalIDs == expected, "step \(step): unread set diverged")
        }
        // Final drain: the link is healthy, everything pending must flush.
        effects.sendFails = false
        sync.linkDidConnect()
        for _ in 0..<20 { await Task.yield() }
        #expect(sync.state.pendingAcks.isEmpty, "pending acks after a healthy flush: \(sync.state.pendingAcks)")
        // No key was ever sent with two different id sets.
        #expect(effects.acked.values.allSatisfy { Set($0).count == $0.count })
    }
}
