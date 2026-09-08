import CmuxMobileShellModel
import Testing

@Suite
@MainActor
struct MobileMacListAuthStateTests {
    @Test
    func comparesReportedVersionToServerFloor() {
        let outdated = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.19+123",
            minimumSupportedVersion: "0.64.20"
        )
        #expect(outdated.isOutdated)

        let current = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.20+1",
            minimumSupportedVersion: "0.64.20"
        )
        #expect(!current.isOutdated)
    }

    @Test
    func missingOrMalformedVersionWarns() {
        let unknown = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: nil,
            minimumSupportedVersion: "0.64.20"
        )
        #expect(unknown.isOutdated)

        let malformed = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "nightly",
            minimumSupportedVersion: "0.64.20"
        )
        #expect(malformed.isOutdated)
    }

    @Test
    func nightlyVersionIsNotComparedToStableFloor() {
        let current = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.22-nightly.3345650013202+202609081234",
            minimumSupportedVersion: "0.64.23"
        )
        #expect(!current.isOutdated)
    }

    @Test
    func nightlyRowsUseNightlyCounterInsteadOfStableFloor() {
        let current = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.22-nightly.3345650013202+202609081234",
            minimumSupportedVersion: "0.64.23",
            releaseTrack: "nightly",
            minimumSupportedNightlyVersion: "0.64.22-nightly.3345650013202"
        )
        #expect(!current.isOutdated)
        #expect(current.requiredVersionDisplay == nil)

        let older = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.22-nightly.3345650013201+202609081233",
            minimumSupportedVersion: "0.64.23",
            releaseTrack: "nightly",
            minimumSupportedNightlyVersion: "0.64.22-nightly.3345650013202"
        )
        #expect(older.isOutdated)
        #expect(older.requiredVersionDisplay == "0.64.22-nightly.3345650013202")
    }

    @Test
    func nightlyBaseAboveFloorIsAdmitted() {
        let newerBase = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.23-nightly.1+202609081235",
            minimumSupportedVersion: "0.64.23",
            releaseTrack: "nightly",
            minimumSupportedNightlyVersion: "0.64.22-nightly.3345650013202"
        )
        #expect(!newerBase.isOutdated)
    }

    @Test
    func policyFloorOverridesDirectoryFloorAndSurvivesLaterSnapshots() {
        let state = MobileMacListAuthState()
        let entry = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.20"
        )
        state.replace(
            entriesByEndpointID: ["endpoint": entry],
            entriesByDeviceID: ["device": entry],
            minimumSupportedMacVersion: "0.64.20"
        )
        #expect(!state.entry(deviceID: "device")!.isOutdated)

        state.applyPolicyMinimumSupportedMacVersion("0.64.23")
        #expect(state.entry(deviceID: "device")!.isOutdated)
        #expect(state.entry(deviceID: "device")!.minimumSupportedVersion == "0.64.23")

        // A directory refresh without the legacy server floor must not erase
        // the current iOS build's policy floor.
        state.replace(
            entriesByEndpointID: ["endpoint": entry],
            entriesByDeviceID: ["device": entry]
        )
        #expect(state.entry(deviceID: "device")!.isOutdated)
        #expect(state.minimumSupportedMacVersion == "0.64.23")
    }

    @Test
    func policyAppliesSeparateNightlyFloorToNightlyRows() {
        let state = MobileMacListAuthState()
        let nightly = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.22-nightly.3345650013202+202609081234",
            releaseTrack: "nightly"
        )
        state.replace(
            entriesByEndpointID: ["endpoint": nightly],
            entriesByDeviceID: ["device": nightly],
            minimumSupportedMacVersion: "0.64.23"
        )
        #expect(!state.entry(deviceID: "device")!.isOutdated)

        state.applyPolicyMinimumSupportedMacVersions(
            stable: "0.64.23",
            nightly: "0.64.22-nightly.3345650013202"
        )
        #expect(!state.entry(deviceID: "device")!.isOutdated)
        #expect(state.entry(deviceID: "device")!.requiredVersionDisplay == nil)
    }

    @Test
    func failOpenPolicyClearsExistingWarningWithoutLosingRememberedVersion() {
        let state = MobileMacListAuthState()
        let entry = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.20",
            minimumSupportedVersion: "0.64.23"
        )
        state.replace(
            entriesByEndpointID: ["endpoint": entry],
            entriesByDeviceID: ["device": entry],
            minimumSupportedMacVersion: "0.64.23"
        )
        #expect(state.entry(deviceID: "device")!.isOutdated)

        state.applyPolicyMinimumSupportedMacVersion(nil)
        #expect(state.entry(deviceID: "device")!.appVersion == "0.64.20")
        #expect(!state.entry(deviceID: "device")!.isOutdated)
    }
}
