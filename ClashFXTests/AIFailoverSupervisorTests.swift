import XCTest

final class AIFailoverSupervisorTests: XCTestCase {
    private final class Harness {
        var now = Date(timeIntervalSince1970: 1_000)
        var scope = "core-1"
        var profile = "profile-A"
        var enabledByProfile = [String: Bool]()
        var heldByProfile = [String: Bool]()
        var manualPauseByProfile = [String: Date]()
        var selected = AIFailoverTopology.candidates[0]
        var plan = [AIFailoverSupervisor.Reachability](repeating: .reachable, count: 4)
        var probeIndex = 0
        var probeCount = 0
        var refreshCount = 0
        var selectCalls = [(String, String)]()
        var selectSucceeds = true
        var refreshUnavailable = false
        var holdProbe = false
        var heldProbe: ((AIFailoverSupervisor.Reachability) -> Void)?
        var holdSelection = false
        var heldSelection: ((Bool) -> Void)?
        var selectIsCurrent: (() -> Bool)?
        var pause: String?
        var snapshotPause: String?
        var topologyMode = "valid"
        var supervisor: AIFailoverSupervisor!

        init() {
            supervisor = AIFailoverSupervisor(dependencies: .init(
                now: { self.now },
                scope: { AnyHashable(self.scope) },
                profile: { self.profile },
                enabled: { self.enabledByProfile[$0] ?? false },
                setEnabled: { self.enabledByProfile[$0] = $1 },
                held: { self.heldByProfile[$0] ?? false },
                setHeld: { self.heldByProfile[$0] = $1 },
                pauseReason: { self.pause },
                interactionBusy: { false },
                refresh: { completion in
                    self.refreshCount += 1
                    self.probeIndex = 0
                    completion(self.refreshUnavailable ? nil : self.snapshot())
                },
                probe: { _, _, completion in
                    self.probeCount += 1
                    let result = self.plan[min(self.probeIndex, self.plan.count - 1)]
                    self.probeIndex += 1
                    if self.holdProbe {
                        self.holdProbe = false
                        self.heldProbe = completion
                    } else {
                        completion(result)
                    }
                },
                cancel: {},
                select: { _, _, from, to, isCurrent, completion in
                    self.selectCalls.append((from, to))
                    self.selectIsCurrent = isCurrent
                    if self.holdSelection {
                        self.holdSelection = false
                        self.heldSelection = completion
                    } else {
                        if self.selectSucceeds { self.selected = to }
                        completion(self.selectSucceeds)
                    }
                },
                changed: { _, _ in },
                snapshotPauseReason: { _ in self.snapshotPause },
                manualPauseUntil: { self.manualPauseByProfile[$0] ?? .distantPast },
                setManualPauseUntil: { self.manualPauseByProfile[$0] = $1 }
            ))
        }

        func enableAndStabilize() {
            supervisor.setEnabled(true)
            now = now.addingTimeInterval(10)
            supervisor.tick()
        }

        func runRound(_ values: [AIFailoverSupervisor.Reachability]) {
            plan = values
            probeIndex = 0
            now = now.addingTimeInterval(30)
            supervisor.tick()
        }

        func failurePlan(for current: String) -> [AIFailoverSupervisor.Reachability] {
            let bad = AIFailoverSupervisor.Reachability.failed
            let good = AIFailoverSupervisor.Reachability.reachable
            // Request order is the two candidates, then each candidate's two
            // endpoints. Fail one endpoint on the current leaf; the peer
            // reaches that same endpoint and both peer checks pass.
            return current == AIFailoverTopology.candidates[0]
                ? [bad, good, good, good]
                : [good, good, bad, good]
        }

        func snapshot() -> ClashProxyResp {
            let names = AIFailoverTopology.candidates
            let groupMembers = topologyMode == "missing-member" ? [names[0]] : names
            var proxies: [String: [String: Any]] = [
                AIFailoverTopology.group: [
                    "name": AIFailoverTopology.group, "type": "Selector",
                    "id": "ai-selector-1", "all": groupMembers,
                    "now": selected, "history": []
                ],
                names[0]: [
                    "name": names[0], "type": topologyMode == "wrong-type" ? "Trojan" : "Vless",
                    "id": topologyMode == "missing-id" ? NSNull() : "node-1", "history": []
                ],
                names[1]: [
                    "name": names[1], "type": "Vless", "id": "node-2", "history": []
                ]
            ]
            // Keep a mutable dictionary here so malformed variants remain
            // explicit and localized to the owned test fixture.
            if topologyMode == "missing-leaf" { proxies.removeValue(forKey: names[1]) }
            let data = try! JSONSerialization.data(withJSONObject: ["proxies": proxies])
            return ClashProxyResp(data)
        }
    }

    override func setUp() {
        super.setUp()
        XCTAssertTrue(Thread.isMainThread)
    }

    func testDefaultIsDisabledAndProfilesHaveSeparatePreferences() {
        let h = Harness()
        h.supervisor.tick()
        XCTAssertFalse(h.supervisor.isEnabled)
        XCTAssertEqual(h.refreshCount, 0)

        h.pause = "test preference scope without probing"
        h.supervisor.setEnabled(true)
        XCTAssertTrue(h.supervisor.isEnabled)
        h.profile = "profile-B"
        h.supervisor.tick()
        XCTAssertFalse(h.supervisor.isEnabled)
        XCTAssertEqual(h.refreshCount, 0)
        h.profile = "profile-A"
        h.supervisor.tick()
        XCTAssertTrue(h.supervisor.isEnabled)
        XCTAssertEqual(h.refreshCount, 0)
    }

    func testThreeConfirmedRoundsSwitchBothDirectionsAndCooldownBlocksImmediateProbe() {
        let h = Harness()
        h.enableAndStabilize()
        for _ in 0 ..< 3 { h.runRound(h.failurePlan(for: h.selected)) }
        XCTAssertEqual(h.selectCalls.count, 1)
        XCTAssertEqual(h.selectCalls[0].0, AIFailoverTopology.candidates[0])
        XCTAssertEqual(h.selectCalls[0].1, AIFailoverTopology.candidates[1])
        XCTAssertEqual(h.selected, AIFailoverTopology.candidates[1])
        let requestsAfterSwitch = h.refreshCount
        h.now = h.now.addingTimeInterval(119)
        h.supervisor.tick()
        XCTAssertEqual(h.refreshCount, requestsAfterSwitch)

        h.now = h.now.addingTimeInterval(1)
        h.supervisor.tick()
        h.probeIndex = 0
        for _ in 0 ..< 3 { h.runRound(h.failurePlan(for: h.selected)) }
        XCTAssertEqual(h.selectCalls.count, 2)
        XCTAssertEqual(h.selectCalls[1].0, AIFailoverTopology.candidates[1])
        XCTAssertEqual(h.selectCalls[1].1, AIFailoverTopology.candidates[0])
    }

    func testSingleTypedTimeoutIsNotEnoughToSwitch() {
        let h = Harness()
        h.enableAndStabilize()
        let probesBeforeRound = h.probeCount
        XCTAssertEqual(AIFailoverSupervisor.Reachability(.timedOut), .failed)
        h.runRound([.init(.timedOut), .reachable, .reachable, .reachable])
        XCTAssertTrue(h.selectCalls.isEmpty)
        XCTAssertEqual(h.probeCount, probesBeforeRound + 4)
    }

    func testBothNodesFailingTheSameEndpointsDoesNotCreateFailureContrast() {
        let h = Harness()
        h.enableAndStabilize()
        let bothFail = Array(repeating: AIFailoverSupervisor.Reachability.failed, count: 4)
        for _ in 0 ..< 5 { h.runRound(bothFail) }
        XCTAssertTrue(h.selectCalls.isEmpty)
        XCTAssertTrue(h.supervisor.status.contains("两节点"))
    }

    func testCoreAPIUnknownBreaksFailureStreakAndHealthyAlternativeDoesNotWin() {
        let h = Harness()
        h.enableAndStabilize()
        h.runRound(h.failurePlan(for: h.selected))
        h.runRound(h.failurePlan(for: h.selected))
        // An unavailable fresh topology represents an API/auth failure, not a
        // failed leaf. It resets the streak and enters a short backoff.
        h.refreshUnavailable = true
        h.now = h.now.addingTimeInterval(30)
        h.supervisor.tick()
        XCTAssertEqual(h.selectCalls.count, 0)
        h.refreshUnavailable = false

        h.selected = AIFailoverTopology.candidates[1]
        h.scope = "core-2"
        h.topologyMode = "valid"
        h.supervisor.invalidate(reason: "fresh core", stabilization: 10)
        h.now = h.now.addingTimeInterval(10)
        let allGood = Array(repeating: AIFailoverSupervisor.Reachability.reachable, count: 4)
        for _ in 0 ..< 4 { h.runRound(allGood) }
        XCTAssertTrue(h.selectCalls.isEmpty, "A healthy 4x must remain selected")
        XCTAssertEqual(h.selected, AIFailoverTopology.candidates[1])
    }

    func testUnknownAndCancelledProbeOutcomesNeverCountAsNodeFailure() {
        let h = Harness()
        h.enableAndStabilize()
        let unknown = AIFailoverSupervisor.Reachability.unknown
        for _ in 0 ..< 5 {
            h.runRound([unknown, .reachable, .reachable, .reachable])
        }
        XCTAssertTrue(h.selectCalls.isEmpty)
        XCTAssertTrue(h.supervisor.status.contains("不确定"))
        XCTAssertEqual(AIFailoverSupervisor.Reachability(.cancelled), .unknown)
        XCTAssertEqual(AIFailoverSupervisor.Reachability(.unavailable), .unknown)
    }

    func testManualSelectionPausesFiveMinutesAndOtherNodeRequiresExplicitResume() {
        let h = Harness()
        h.enableAndStabilize()
        h.supervisor.manualSelection(group: AIFailoverTopology.group,
                                     name: AIFailoverTopology.candidates[0])
        let before = h.probeCount
        h.now = h.now.addingTimeInterval(299)
        h.supervisor.tick()
        XCTAssertEqual(h.probeCount, before)
        h.now = h.now.addingTimeInterval(1)
        h.supervisor.tick()
        XCTAssertEqual(h.probeCount, before + 4)

        h.supervisor.manualSelection(group: AIFailoverTopology.group, name: "Japan")
        XCTAssertTrue(h.supervisor.isHeld)
        let heldCount = h.probeCount
        h.now = h.now.addingTimeInterval(600)
        h.supervisor.tick()
        XCTAssertEqual(h.probeCount, heldCount)
        // The user explicitly returns to a managed member before resuming.
        h.selected = AIFailoverTopology.candidates[0]
        h.supervisor.resume()
        XCTAssertFalse(h.supervisor.isHeld)
        XCTAssertEqual(h.probeCount, heldCount + 4)
    }

    func testManualPauseSurvivesProfileRoundTripAndExplicitResumeClearsIt() {
        let h = Harness()
        h.enableAndStabilize()
        h.supervisor.manualSelection(group: AIFailoverTopology.group, name: h.selected)
        let before = h.probeCount
        h.profile = "profile-B"
        h.supervisor.tick()
        h.profile = "profile-A"
        h.supervisor.tick()
        h.now = h.now.addingTimeInterval(20)
        h.supervisor.tick()
        XCTAssertEqual(h.probeCount, before)
        XCTAssertTrue(h.supervisor.status.contains("5 分钟"))
        h.supervisor.resume()
        XCTAssertEqual(h.manualPauseByProfile["profile-A"], .distantPast)
        XCTAssertEqual(h.probeCount, before + 4)
    }

    func testMissingCandidateWrongTypeAndMissingIdentityPauseSafely() {
        for mode in ["missing-member", "missing-leaf", "wrong-type", "missing-id"] {
            let h = Harness()
            h.topologyMode = mode
            h.enableAndStabilize()
            XCTAssertTrue(h.selectCalls.isEmpty, mode)
            XCTAssertEqual(h.probeCount, 0, mode)
            XCTAssertTrue(h.supervisor.status.contains("暂停"), mode)
        }
    }

    func testStaleProbeCallbackAfterCoreScopeChangeIsDiscarded() {
        let h = Harness()
        h.enableAndStabilize()
        h.holdProbe = true
        let before = h.probeCount
        h.now = h.now.addingTimeInterval(30)
        h.supervisor.tick()
        XCTAssertEqual(h.probeCount, before + 1)
        let count = h.probeCount
        let pending = h.heldProbe
        h.scope = "core-2"
        h.supervisor.tick()
        pending?(.failed)
        XCTAssertEqual(h.probeCount, count)
        XCTAssertTrue(h.selectCalls.isEmpty)
    }

    func testSleepAndWakeDiscardOldProbeCallbackAndWaitForNetworkStability() {
        let h = Harness()
        h.enableAndStabilize()
        h.holdProbe = true
        h.now = h.now.addingTimeInterval(30)
        h.supervisor.tick()
        let pending = h.heldProbe
        h.supervisor.sleep()
        h.now = h.now.addingTimeInterval(10_000)
        h.supervisor.wake()
        pending?(.failed)
        let count = h.probeCount
        h.supervisor.tick()
        XCTAssertEqual(h.probeCount, count)
        h.now = h.now.addingTimeInterval(20)
        h.supervisor.tick()
        XCTAssertEqual(h.probeCount, count + 4)
        XCTAssertTrue(h.selectCalls.isEmpty)
    }

    func testExpiredProbeCallbackAfterFortySecondsCannotAdvanceRound() {
        let h = Harness()
        h.enableAndStabilize()
        h.holdProbe = true
        let before = h.probeCount
        h.now = h.now.addingTimeInterval(30)
        h.supervisor.tick()
        let pending = h.heldProbe
        XCTAssertEqual(h.probeCount, before + 1)

        h.now = h.now.addingTimeInterval(40)
        pending?(.failed)
        XCTAssertEqual(h.probeCount, before + 1)
        XCTAssertTrue(h.supervisor.status.contains("检测过期"))
        XCTAssertTrue(h.selectCalls.isEmpty)
    }

    func testFailureEvidenceOlderThanNinetySecondsStartsANewStreak() {
        let h = Harness()
        h.enableAndStabilize()
        for _ in 0 ..< 2 { h.runRound(h.failurePlan(for: h.selected)) }
        XCTAssertTrue(h.selectCalls.isEmpty)

        h.now = h.now.addingTimeInterval(91)
        h.plan = h.failurePlan(for: h.selected)
        h.supervisor.tick()
        XCTAssertTrue(h.selectCalls.isEmpty, "Stale failures must be cleared before this round")
        h.runRound(h.failurePlan(for: h.selected))
        XCTAssertTrue(h.selectCalls.isEmpty)
        h.runRound(h.failurePlan(for: h.selected))
        XCTAssertEqual(h.selectCalls.count, 1)
    }

    func testSnapshotPauseReasonStopsBeforeAnyLeafProbe() {
        let h = Harness()
        h.enableAndStabilize()
        h.snapshotPause = "Claude 专用锁状态无法分离"
        let before = h.probeCount
        h.now = h.now.addingTimeInterval(30)
        h.supervisor.tick()
        XCTAssertEqual(h.probeCount, before)
        XCTAssertTrue(h.supervisor.status.contains("Claude"))

        h.snapshotPause = nil
        h.now = h.now.addingTimeInterval(30)
        h.supervisor.tick()
        XCTAssertEqual(h.probeCount, before + 4)
    }

    func testFailedSelectionReadbackDoesNotPublishSuccessfulSwitch() {
        let h = Harness()
        h.enableAndStabilize()
        h.selectSucceeds = false
        for _ in 0 ..< 3 { h.runRound(h.failurePlan(for: h.selected)) }
        XCTAssertEqual(h.selectCalls.count, 1)
        XCTAssertNil(h.supervisor.lastSwitch)
        XCTAssertTrue(h.supervisor.status.contains("未确认"))
        XCTAssertEqual(h.selected, AIFailoverTopology.candidates[0])
    }

    func testStaleSelectionConfirmationAfterScopeChangeIsDiscarded() {
        let h = Harness()
        h.enableAndStabilize()
        h.holdSelection = true
        for _ in 0 ..< 3 { h.runRound(h.failurePlan(for: h.selected)) }
        XCTAssertEqual(h.selectCalls.count, 1)
        XCTAssertNil(h.supervisor.lastSwitch)
        let stillCurrent = h.selectIsCurrent

        h.scope = "core-after-handoff"
        h.supervisor.tick()
        XCTAssertFalse(stillCurrent?() ?? true)
        h.heldSelection?(true)
        XCTAssertNil(h.supervisor.lastSwitch)
    }
}

final class AIFailoverClaudeLockIndependenceTests: XCTestCase {
    private let aiGroup = AIFailoverTopology.group

    func testDirectFixedLeafIsIndependentOfAISelector() {
        let root: [String: Any] = [
            "proxy-groups": [["name": aiGroup, "type": "select", "proxies": ["AI leaf"]]],
            "proxies": [
                ["name": "AI leaf", "type": "vless", "server": "ai.example"],
                ["name": "Claude fixed", "type": "vless", "server": "claude.example"]
            ]
        ]
        XCTAssertTrue(ClaudeProxyLockPolicy.isIndependent(target: "Claude fixed", of: aiGroup, in: root))
    }

    func testFixedLeafDialingThroughAISelectorIsNotIndependent() {
        let root: [String: Any] = [
            "proxy-groups": [["name": aiGroup, "type": "select", "proxies": ["AI leaf"]]],
            "proxies": [
                ["name": "AI leaf", "type": "vless", "server": "ai.example"],
                ["name": "Claude fixed", "type": "vless", "server": "claude.example",
                 "dialer-proxy": aiGroup]
            ]
        ]
        XCTAssertFalse(ClaudeProxyLockPolicy.isIndependent(target: "Claude fixed", of: aiGroup, in: root))
    }

    func testFixedLeafThroughRelayGroupContainingAISelectorIsNotIndependent() {
        let root: [String: Any] = [
            "proxy-groups": [
                ["name": aiGroup, "type": "select", "proxies": ["AI leaf"]],
                ["name": "Relay", "type": "select", "proxies": [aiGroup]]
            ],
            "proxies": [
                ["name": "AI leaf", "type": "vless", "server": "ai.example"],
                ["name": "Claude fixed", "type": "vless", "server": "claude.example",
                 "dialer-proxy": "Relay"]
            ]
        ]
        XCTAssertFalse(ClaudeProxyLockPolicy.isIndependent(target: "Claude fixed", of: aiGroup, in: root))
    }

    func testUnresolvedProviderDialerDependencyIsNotIndependent() {
        let root: [String: Any] = [
            "proxy-groups": [["name": aiGroup, "type": "select", "proxies": ["AI leaf"]]],
            "proxy-providers": ["cloud": ["type": "http", "url": "https://example.invalid/list"]],
            "proxies": [["name": "AI leaf", "type": "vless", "server": "ai.example"]]
        ]
        let provider = ClaudeProxyLockPolicy.ProviderSnapshot(
            name: "cloud", dialerProxy: nil, overrideDialerProxy: nil,
            proxies: [["name": "Claude fixed", "type": "vless", "server": "claude.example",
                       "dialer-proxy": 17]]
        )
        XCTAssertFalse(ClaudeProxyLockPolicy.isIndependent(
            target: "Claude fixed", of: aiGroup, in: root, providers: [provider]
        ))
    }
}
