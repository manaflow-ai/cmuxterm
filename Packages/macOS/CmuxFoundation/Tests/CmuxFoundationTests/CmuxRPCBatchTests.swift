import Foundation
import Testing
@testable import CmuxFoundation

struct CmuxRPCBatchTests {
    private func plan(_ json: String) throws -> CmuxRPCBatchPlan {
        try CmuxRPCBatchPlan(data: Data(json.utf8))
    }

    @Test(arguments: [
        "null", "{}", "[]", "[true]", "[", "[{}]",
        #"[{"id":"a","method":""}]"#,
        #"[{"id":"a","method":"window.list\n"}]"#,
        #"[{"id":"a","method":"window.list","params":null}]"#,
        #"[{"id":"a","method":"window.list","params":[]}]"#,
        #"[{"id":"a","method":"window.list","extra":true}]"#,
        #"[{"id":"a#","method":"window.list"}]"#,
        #"[{"id":"a","method":"window.list"},{"id":"a","method":"window.list"}]"#,
        #"[{"id":"a","method":"events.stream"}]"#,
        #"[{"id":"a","method":"AUTH.login"}]"#,
        #"[{"id":"a","method":"window.list","params":{"x":{"$ref":"a#"}}}]"#,
        #"[{"id":"a","method":"window.list","params":{"x":{"$ref":"b#"}}},{"id":"b","method":"window.list"}]"#,
        #"[{"id":"a","method":"window.list"},{"id":"b","method":"window.list","params":{"x":{"$ref":"a#/bad~2"}}}]"#,
        #"[{"id":"a","method":"window.list"},{"id":"b","method":"window.list","params":{"x":{"$ref":4}}}]"#,
        #"[{"id":"a","method":"window.list"},{"id":"b","method":"window.list","params":{"x":{"$ref":"a#","extra":1}}}]"#,
        #"[{"id":"a","method":"window.list"},{"id":"b","method":"window.list","params":{"x":{"$ref":"a#no-slash"}}}]"#,
    ])
    func rejectsInvalidPlans(json: String) {
        #expect(throws: CmuxRPCBatchError.self) { try plan(json) }
    }

    @Test func reportsRequestIndexWithoutInputValues() throws {
        do {
            _ = try plan(#"[{"id":"a","method":"window.list"},{"id":"b","method":"window.list","params":"secret"}]"#)
            Issue.record("Invalid trailing request was accepted")
        } catch let error as CmuxRPCBatchError {
            #expect(error.code == .invalidPlan)
            #expect(error.index == 1)
        }
    }

    @Test func resolvesTypedReferencesAndJSONPointerEscapes() throws {
        let batch = try plan(#"""
        [
          {"id":"create","method":"workspace.create"},
          {"id":"use","method":"surface.send_text","params":{
            "workspace_id":{"$ref":"create#/workspace_id"},
            "nested":[{"enabled":{"$ref":"create#/a~1b/~0key/0"}}],
            "null":{"$ref":"create#/null"},
            "empty_key":{"$ref":"create#/"},
            "whole":{"$ref":"create#"},
            "literal":"create#/workspace_id"
          }}
        ]
        """#)
        var methods: [String] = []
        let report = batch.execute(now: { 0 }) { method, params in
            methods.append(method)
            if method == "workspace.create" {
                #expect(params.isEmpty)
                return ["workspace_id": "uuid", "a/b": ["~key": [true]], "null": NSNull(), "": 42]
            }
            #expect(params["workspace_id"] as? String == "uuid")
            let nested = try #require(params["nested"] as? [[String: Any]])
            #expect(nested[0]["enabled"] as? Bool == true)
            #expect(params["null"] is NSNull)
            #expect(params["empty_key"] as? Int == 42)
            #expect((params["whole"] as? [String: Any])?["workspace_id"] as? String == "uuid")
            #expect(params["literal"] as? String == "create#/workspace_id")
            return ["sent": true]
        }
        #expect(methods == ["workspace.create", "surface.send_text"])
        #expect(report.ok)
        #expect(report.attempted == 2)
        #expect(JSONSerialization.isValidJSONObject(report.jsonObject))
    }

    @Test func substitutesResultsOnceWithoutInterpretingReturnedReferences() throws {
        let batch = try plan(#"[{"id":"a","method":"read"},{"id":"b","method":"write","params":{"value":{"$ref":"a#/value"}}}]"#)
        let report = batch.execute(now: { 0 }) { method, params in
            if method == "read" { return ["value": ["$ref": "malicious#/other"]] }
            #expect((params["value"] as? [String: String])?["$ref"] == "malicious#/other")
            return [:]
        }
        #expect(report.ok)
    }

    @Test(arguments: ["/missing", "/items/2", "/items/01", "/items/-1", "/items/+0", "/items/-", "/items/", "/items/9999999999999999999999999"])
    func missingPathsDoNotSendDependentRequest(pointer: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            ["id": "a", "method": "read"],
            ["id": "b", "method": "write", "params": ["x": ["$ref": "a#" + pointer]]],
            ["id": "c", "method": "read"],
        ])
        let batch = try CmuxRPCBatchPlan(data: data)
        var calls = 0
        let report = batch.execute(continueOnError: true, now: { 0 }) { _, _ in
            calls += 1
            return ["items": [1]]
        }
        #expect(calls == 2)
        #expect(report.records[1]["status"] as? String == "failed")
        #expect((report.records[1]["error"] as? [String: String])?["code"] == "unresolved_reference")
        #expect(!report.ok)
    }

    @Test(arguments: [false, true])
    func applicationFailuresRespectContinueOption(continueOnError: Bool) throws {
        let batch = try plan(#"""
        [{"id":"a","method":"fail"},
         {"id":"b","method":"dependent","params":{"x":{"$ref":"a#/id"}}},
         {"id":"c","method":"independent"}]
        """#)
        var called: [String] = []
        let report = batch.execute(continueOnError: continueOnError, now: { 0 }) { method, _ in
            called.append(method)
            if method == "fail" {
                throw CmuxRPCBatchCallFailure(code: "not_found", message: "Missing workspace", canContinue: true)
            }
            return [:]
        }
        #expect(called == (continueOnError ? ["fail", "independent"] : ["fail"]))
        #expect(report.attempted == called.count)
        #expect(report.records[1]["status"] as? String == (continueOnError ? "failed" : "skipped"))
        #expect(report.succeeded == (continueOnError ? 1 : 0))
        #expect(!report.ok)
    }

    @Test(arguments: [false, true])
    func transportFailureAlwaysStopsWithoutRetry(classified: Bool) throws {
        let batch = try plan(#"[{"id":"a","method":"write"},{"id":"b","method":"write"}]"#)
        var calls = 0
        let report = batch.execute(continueOnError: true, now: { 0 }) { _, _ in
            calls += 1
            if classified {
                throw CmuxRPCBatchCallFailure(code: "transport_error", message: "Lost reply", canContinue: false)
            }
            throw CocoaError(.fileReadUnknown)
        }
        #expect(calls == 1)
        #expect(report.records[1]["status"] as? String == "skipped")
        #expect(report.attempted == 1)
    }

    @Test func deterministicMetricsIncludeFailuresAndSkips() throws {
        let batch = try plan(#"[{"id":"a","method":"read"},{"id":"b","method":"fail"},{"id":"c","method":"read"}]"#)
        var clock = 0.0
        let report = batch.execute(now: { clock }) { method, _ in
            clock += 0.025
            if method == "fail" { throw CmuxRPCBatchCallFailure(code: "failed", message: "Failure", canContinue: true) }
            return [:]
        }
        #expect(report.durationMilliseconds == 50)
        #expect(report.records[0]["duration_ms"] as? Double == 25)
        #expect(report.records[1]["duration_ms"] as? Double == 25)
        #expect(report.records[2]["duration_ms"] as? Int == 0)
        let metrics = try #require(report.jsonObject["metrics"] as? [String: Any])
        #expect(metrics["requests"] as? Int == 3)
        #expect(metrics["attempted"] as? Int == 2)
        #expect(metrics["failed"] as? Int == 1)
        #expect(metrics["skipped"] as? Int == 1)
    }

    @Test func enforcesByteAndNestingLimitsBeforeParsing() throws {
        #expect(throws: CmuxRPCBatchError.self) {
            try CmuxRPCBatchPlan(data: Data(repeating: 32, count: CmuxRPCBatchPlan.maximumInputBytes + 1))
        }
        let deep = String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)
        do {
            _ = try plan(deep)
            Issue.record("Excessively nested input was accepted")
        } catch let error as CmuxRPCBatchError { #expect(error.code == .inputLimit) }
        // Braces and escaped quotes inside strings are data, not nesting.
        let data = try JSONSerialization.data(withJSONObject: [[
            "id": "a", "method": "write", "params": ["text": String(repeating: "[\"\\", count: 100)],
        ]])
        #expect(try CmuxRPCBatchPlan(data: data).requests.count == 1)
    }

    @Test func maximumPlanExecutesInOrderAndRejectsOneExtraRequest() throws {
        let requests = (0..<CmuxRPCBatchPlan.maximumRequests).map { ["id": "r\($0)", "method": "read"] }
        let batch = try CmuxRPCBatchPlan(data: JSONSerialization.data(withJSONObject: requests))
        var calls = 0
        let report = batch.execute(now: { 0 }) { _, _ in
            calls += 1
            return ["ordinal": calls]
        }
        #expect(report.ok)
        #expect(calls == 256)
        #expect((report.records.last?["result"] as? [String: Int])?["ordinal"] == 256)
        #expect(throws: CmuxRPCBatchError.self) {
            try CmuxRPCBatchPlan(data: JSONSerialization.data(withJSONObject: requests + [["id": "extra", "method": "read"]]))
        }
    }
}
