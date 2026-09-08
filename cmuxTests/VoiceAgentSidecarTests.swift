import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Voice agent sidecar handshake and launcher helpers. Mirrors the agent-chat
/// state-file tests: the readiness file must carry a valid port and PID and
/// echo the launch id the app minted, or the launch is treated as failed.
@MainActor
struct VoiceAgentSidecarTests {
    @Test func stateFileParsesValidPortAndPID() throws {
        let data = Data(#"{"port": 53848, "pid": 26549, "launchId": "launch-1", "protocolVersion": 1}"#.utf8)
        let file = try JSONDecoder().decode(VoiceAgentSidecarStateFile.self, from: data)
        let session = try #require(file.session(token: "tok", launchId: "launch-1"))
        #expect(session.port == 53848)
        #expect(session.pid == 26549)
        #expect(session.token == "tok")
        #expect(session.healthURL.absoluteString == "http://127.0.0.1:53848/healthz")
        #expect(session.audioPageURL(resumingConversation: false).absoluteString == "http://127.0.0.1:53848/tok/audio.html?autostart=1&session=fresh")
        #expect(session.audioPageURL(resumingConversation: true).absoluteString == "http://127.0.0.1:53848/tok/audio.html?autostart=1&session=resume")
    }

    @Test func stateFileRejectsInvalidPortPIDOrLaunchID() throws {
        let badPort = try JSONDecoder().decode(VoiceAgentSidecarStateFile.self, from: Data(#"{"port": 0, "pid": 1, "launchId": "l"}"#.utf8))
        let badPID = try JSONDecoder().decode(VoiceAgentSidecarStateFile.self, from: Data(#"{"port": 8000, "pid": 0, "launchId": "l"}"#.utf8))
        let staleLaunch = try JSONDecoder().decode(VoiceAgentSidecarStateFile.self, from: Data(#"{"port": 8000, "pid": 1, "launchId": "old"}"#.utf8))
        let missingLaunch = try JSONDecoder().decode(VoiceAgentSidecarStateFile.self, from: Data(#"{"port": 8000, "pid": 1}"#.utf8))
        #expect(badPort.session(token: "t", launchId: "l") == nil)
        #expect(badPID.session(token: "t", launchId: "l") == nil)
        #expect(staleLaunch.session(token: "t", launchId: "new") == nil)
        #expect(missingLaunch.session(token: "t", launchId: "new") == nil)
    }

    @Test func stateFileStoreBuildsPerLaunchPaths() {
        let store = VoiceAgentSidecarStateFileStore(directoryURL: URL(fileURLWithPath: "/tmp/voice-agent-tests", isDirectory: true))
        #expect(store.stateFileURL(launchId: "abc").path == "/tmp/voice-agent-tests/state-abc.json")
    }

    @Test func waitForSessionReadsFileWrittenAfterPrepare() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-agent-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceAgentSidecarStateFileStore(directoryURL: directory)
        let launchDate = Date()
        let url = try #require(await store.prepareStateFileURL(launchId: "L", launchDate: launchDate))
        try Data(#"{"port": 4321, "pid": 99, "launchId": "L"}"#.utf8).write(to: url)
        let session = try #require(await store.waitForSession(token: "tok", launchId: "L", launchDate: launchDate, timeout: .seconds(3)))
        #expect(session.port == 4321)
        #expect(!FileManager.default.fileExists(atPath: url.path), "state file is consumed once read")
    }

    @Test func waitForSessionTimesOutWithoutFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-agent-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceAgentSidecarStateFileStore(directoryURL: directory)
        let launchDate = Date()
        _ = await store.prepareStateFileURL(launchId: "L", launchDate: launchDate)
        let session = await store.waitForSession(token: "tok", launchId: "L", launchDate: launchDate, timeout: .milliseconds(400))
        #expect(session == nil)
    }

    @Test func tokenIsURLSafeAndUnpredictable() throws {
        let a = try #require(VoiceAgentSidecarLauncher.generateToken())
        let b = try #require(VoiceAgentSidecarLauncher.generateToken())
        #expect(a != b)
        #expect(a.count >= 40)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    /// The greeting depends on whether the chat log was empty when the session
    /// started: a first start says "Hi there, what should we build?"; toggling
    /// the microphone off and on mid-conversation gets "Hey." The choice is
    /// made once, when the session starts, and carried in the audio page URL.
    @Test func sessionResumesWhenTheTranscriptIsNotEmpty() {
        let state = VoiceAgentSessionState()
        let sidecar = VoiceAgentSidecarSession(port: 53848, pid: 42, token: "tok")

        state.beginStarting()
        state.sidecar = sidecar
        state.isSessionRequested = true
        #expect(state.isResumingConversation == false)
        #expect(state.audioPageURL?.query == "autostart=1&session=fresh")

        // A conversation happened; the user turned the mic off and on again.
        state.handleBridgeMessage(["type": "transcript", "role": "user", "text": "split right", "final": true])
        state.reset()
        #expect(state.audioPageURL == nil)
        state.beginStarting()
        state.isSessionRequested = true
        #expect(state.isResumingConversation == true)
        #expect(state.audioPageURL?.query == "autostart=1&session=resume")

        // Clearing the chat log makes the next start a fresh session again.
        state.reset()
        state.clearTranscript()
        state.beginStarting()
        state.isSessionRequested = true
        #expect(state.isResumingConversation == false)
        #expect(state.audioPageURL?.query == "autostart=1&session=fresh")
    }

    @Test func shellQuotingEscapesSingleQuotes() {
        #expect(VoiceAgentSidecarLauncher.shellQuoted("/a b/c") == "'/a b/c'")
        #expect(VoiceAgentSidecarLauncher.shellQuoted("it's") == #"'it'\''s'"#)
    }
}
