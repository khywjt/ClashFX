import AppKit
import XCTest

final class AIFailoverSelectionTests: XCTestCase {
    private static let group = "Fixture-AI"

    private final class Harness {
        var current = true
        var coreChanging = false
        var benchmarkBusy = false
        var interactionReserved = false
        var selectCalls = [(String, String)]()
        var selectCompletion: ((Bool) -> Void)?
        var refreshCompletion: ((ClashProxyResp?) -> Void)?
        var refreshCount = 0
        var published = [ClashProxyResp]()
        var remembered = [(String, String)]()
        var closeCount = 0
        var errors = [String]()
        var automaticResult: Bool?

        func dependencies() -> ProxyGroupSelectionController.Dependencies {
            ProxyGroupSelectionController.Dependencies(
                isCurrent: { self.current },
                isCoreChanging: { self.coreChanging },
                isBusyBenchmark: { self.benchmarkBusy },
                isInteractionReserved: { self.interactionReserved },
                select: { group, name, complete in
                    self.selectCalls.append((group, name))
                    self.selectCompletion = complete
                },
                reset: { _, complete in complete(false) },
                refresh: { complete in
                    self.refreshCount += 1
                    self.refreshCompletion = complete
                },
                publish: { self.published.append($0) },
                rememberSelection: { self.remembered.append(($0, $1)) },
                closeConnections: { self.closeCount += 1 },
                showError: { self.errors.append($0) },
                stageTimeout: 1
            )
        }

        func automaticController(_ snapshot: ClashProxyResp) -> ProxyGroupSelectionController {
            ProxyGroupSelectionController(
                group: snapshot.proxiesMap[AIFailoverSelectionTests.group]!,
                snapshot: snapshot,
                dependencies: dependencies()
            )
        }

        func automaticSelect(on controller: ProxyGroupSelectionController,
                             validate: @escaping (ClashProxyResp) -> Bool = { _ in true }) {
            controller.selectAutomatically(name: "Fixture-AI-Secondary",
                                           expectedSelection: "Fixture-AI-Primary",
                                           validateSnapshot: validate) { self.automaticResult = $0 }
        }
    }

    override func setUp() {
        super.setUp()
        XCTAssertTrue(Thread.isMainThread)
        _ = NSApplication.shared
    }

    func testAutomaticSelectionRequiresFreshCurrentSelectionAndCandidateIdentity() {
        let initial = snapshot(now: "Fixture-AI-Primary")
        let harness = Harness()
        let controller = harness.automaticController(initial)
        harness.automaticSelect(on: controller) { fresh in
            fresh.proxiesMap[Self.group]?.now == "Fixture-AI-Primary"
                && fresh.proxiesMap["Fixture-AI-Secondary"]?.id == "leaf-b"
        }

        XCTAssertTrue(controller.isOperationInProgress)
        XCTAssertTrue(ProxyGroupSelectionController.isAnyOperationInProgress)
        XCTAssertEqual(harness.refreshCount, 1)
        XCTAssertTrue(harness.selectCalls.isEmpty)

        // The group identity and membership still match, but the target leaf
        // now has a different core identity. The preflight must reject it.
        harness.refreshCompletion?(snapshot(now: "Fixture-AI-Primary", leafBID: "replaced-leaf-b"))
        waitUntil("identity preflight settles") { harness.automaticResult != nil }

        XCTAssertEqual(harness.automaticResult, false)
        XCTAssertTrue(harness.selectCalls.isEmpty)
        XCTAssertTrue(harness.remembered.isEmpty)
        XCTAssertTrue(harness.published.isEmpty)
        XCTAssertEqual(harness.closeCount, 0)
        XCTAssertFalse(ProxyGroupSelectionController.isAnyOperationInProgress)
    }

    func testAutomaticSelectionDoesNotPutWhenFreshCurrentSelectionChanged() {
        let harness = Harness()
        let controller = harness.automaticController(snapshot(now: "Fixture-AI-Primary"))
        harness.automaticSelect(on: controller) { fresh in
            fresh.proxiesMap[Self.group]?.now == "Fixture-AI-Primary"
                && fresh.proxiesMap["Fixture-AI-Secondary"]?.id == "leaf-b"
        }

        harness.refreshCompletion?(snapshot(now: "Fixture-AI-Secondary"))
        waitUntil("selection preflight settles") { harness.automaticResult != nil }

        XCTAssertEqual(harness.automaticResult, false)
        XCTAssertTrue(harness.selectCalls.isEmpty)
        XCTAssertTrue(harness.remembered.isEmpty)
        XCTAssertEqual(harness.closeCount, 0)
    }

    func testAutomaticFlowUsesOneLeaseThroughPreflightPutAndReadback() {
        let initial = snapshot(now: "Fixture-AI-Primary")
        let harness = Harness()
        let controller = harness.automaticController(initial)
        let otherHarness = Harness()
        let otherSnapshot = snapshot(now: "Fixture-AI-Primary", groupName: "Other")
        let otherController = ProxyGroupSelectionController(
            group: otherSnapshot.proxiesMap["Other"]!,
            snapshot: otherSnapshot,
            dependencies: otherHarness.dependencies()
        )
        harness.automaticSelect(on: controller)

        otherController.select(group: "Other", name: "Fixture-AI-Secondary")
        XCTAssertTrue(otherHarness.selectCalls.isEmpty, "preflight must hold the shared selection lease")

        harness.refreshCompletion?(initial)
        waitUntil("PUT begins after preflight") { harness.selectCompletion != nil }
        XCTAssertEqual(harness.selectCalls.map(\.1), ["Fixture-AI-Secondary"])
        otherController.select(group: "Other", name: "Fixture-AI-Secondary")
        XCTAssertEqual(otherHarness.selectCalls.count, 0, "mutation must retain the same lease")

        harness.selectCompletion?(true)
        waitUntil("readback begins") { harness.refreshCount == 2 }
        otherController.select(group: "Other", name: "Fixture-AI-Secondary")
        XCTAssertEqual(otherHarness.selectCalls.count, 0, "readback must retain the same lease")
        XCTAssertEqual(harness.automaticResult, nil)

        harness.refreshCompletion?(snapshot(now: "Fixture-AI-Secondary"))
        waitUntil("automatic selection confirms") { harness.automaticResult != nil }

        XCTAssertEqual(harness.automaticResult, true)
        XCTAssertEqual(harness.remembered.map(\.1), ["Fixture-AI-Secondary"])
        XCTAssertEqual(harness.published.count, 1)
        XCTAssertEqual(harness.closeCount, 0, "automatic failover leaves existing connections intact")
        XCTAssertFalse(ProxyGroupSelectionController.isAnyOperationInProgress)
    }

    func testAutomaticMutationFailureDoesNotStartReadbackOrReportSuccess() {
        let harness = Harness()
        let controller = harness.automaticController(snapshot(now: "Fixture-AI-Primary"))
        harness.automaticSelect(on: controller)
        harness.refreshCompletion?(snapshot(now: "Fixture-AI-Primary"))
        waitUntil("automatic PUT begins") { harness.selectCompletion != nil }

        harness.selectCompletion?(false)
        waitUntil("failed PUT settles") { harness.automaticResult != nil }

        XCTAssertEqual(harness.automaticResult, false)
        XCTAssertEqual(harness.refreshCount, 1)
        XCTAssertTrue(harness.remembered.isEmpty)
        XCTAssertTrue(harness.published.isEmpty)
        XCTAssertEqual(harness.closeCount, 0)
        XCTAssertFalse(ProxyGroupSelectionController.isAnyOperationInProgress)
    }

    func testAutomaticReadbackMismatchDoesNotReportSuccess() {
        let harness = Harness()
        let controller = harness.automaticController(snapshot(now: "Fixture-AI-Primary"))
        harness.automaticSelect(on: controller)
        harness.refreshCompletion?(snapshot(now: "Fixture-AI-Primary"))
        waitUntil("automatic PUT begins") { harness.selectCompletion != nil }
        harness.selectCompletion?(true)
        waitUntil("automatic readback begins") { harness.refreshCount == 2 }

        harness.refreshCompletion?(snapshot(now: "Fixture-AI-Primary"))
        waitUntil("mismatched readback settles") { harness.automaticResult != nil }

        XCTAssertEqual(harness.automaticResult, false)
        XCTAssertTrue(harness.published.isEmpty, "unconfirmed automatic selection must not publish")
        XCTAssertTrue(harness.remembered.isEmpty)
        XCTAssertEqual(harness.closeCount, 0)
    }

    func testAutomaticReadbackCandidateIdentityChangeDoesNotPublishOrSucceed() {
        let harness = Harness()
        let controller = harness.automaticController(snapshot(now: "Fixture-AI-Primary"))
        harness.automaticSelect(on: controller) { fresh in
            fresh.proxiesMap[Self.group]?.id == "ai-group-id"
                && fresh.proxiesMap["Fixture-AI-Secondary"]?.id == "leaf-b"
        }
        harness.refreshCompletion?(snapshot(now: "Fixture-AI-Primary"))
        waitUntil("automatic PUT begins") { harness.selectCompletion != nil }
        harness.selectCompletion?(true)
        waitUntil("automatic readback begins") { harness.refreshCount == 2 }

        harness.refreshCompletion?(snapshot(now: "Fixture-AI-Secondary", leafBID: "replaced-leaf-b"))
        waitUntil("changed candidate identity settles") { harness.automaticResult != nil }

        XCTAssertEqual(harness.automaticResult, false)
        XCTAssertTrue(harness.published.isEmpty)
        XCTAssertTrue(harness.remembered.isEmpty)
        XCTAssertEqual(harness.closeCount, 0)
    }

    func testAutomaticUnreadableReadbackDoesNotReportSuccess() {
        let harness = Harness()
        let controller = harness.automaticController(snapshot(now: "Fixture-AI-Primary"))
        harness.automaticSelect(on: controller)
        harness.refreshCompletion?(snapshot(now: "Fixture-AI-Primary"))
        waitUntil("automatic PUT begins") { harness.selectCompletion != nil }
        harness.selectCompletion?(true)
        waitUntil("automatic readback begins") { harness.refreshCount == 2 }

        harness.refreshCompletion?(nil)
        waitUntil("unreadable readback settles") { harness.automaticResult != nil }

        XCTAssertEqual(harness.automaticResult, false)
        XCTAssertTrue(harness.published.isEmpty)
        XCTAssertTrue(harness.remembered.isEmpty)
        XCTAssertEqual(harness.closeCount, 0)
    }

    func testStaleScopePreflightCallbackCannotStartMutation() {
        let harness = Harness()
        let controller = harness.automaticController(snapshot(now: "Fixture-AI-Primary"))
        harness.automaticSelect(on: controller)
        harness.current = false
        harness.refreshCompletion?(snapshot(now: "Fixture-AI-Primary"))
        waitUntil("stale preflight callback settles") { !controller.isOperationInProgress }

        XCTAssertEqual(harness.automaticResult, false)
        XCTAssertTrue(harness.selectCalls.isEmpty)
        XCTAssertTrue(harness.remembered.isEmpty)
        XCTAssertTrue(harness.published.isEmpty)
        XCTAssertEqual(harness.closeCount, 0)
        XCTAssertFalse(ProxyGroupSelectionController.isAnyOperationInProgress)
    }

    func testManualSelectionStillRemembersAndClosesAfterReadback() {
        let harness = Harness()
        let controller = harness.automaticController(snapshot(now: "Fixture-AI-Primary"))
        controller.select(group: Self.group, name: "Fixture-AI-Secondary")
        XCTAssertEqual(harness.selectCalls.count, 1)

        harness.selectCompletion?(true)
        waitUntil("manual readback begins") { harness.refreshCompletion != nil }
        harness.refreshCompletion?(snapshot(now: "Fixture-AI-Secondary"))
        waitUntil("manual selection settles") { !controller.isOperationInProgress }

        XCTAssertEqual(harness.remembered.map(\.1), ["Fixture-AI-Secondary"])
        XCTAssertEqual(harness.closeCount, 1)
        XCTAssertTrue(harness.errors.isEmpty)
    }

    private func snapshot(now: String, leafBID: String = "leaf-b",
                          groupName: String = AIFailoverSelectionTests.group) -> ClashProxyResp {
        let leafA = "Fixture-AI-Primary"
        let leafB = "Fixture-AI-Secondary"
        let json: [String: Any] = [
            "proxies": [
                groupName: ["name": groupName, "type": "Selector", "id": "ai-group-id",
                            "all": [leafA, leafB], "now": now, "history": []],
                leafA: ["name": leafA, "id": "leaf-a", "type": "Vless", "history": []],
                leafB: ["name": leafB, "id": leafBID, "type": "Vless", "history": []]
            ]
        ]
        return ClashProxyResp(try! JSONSerialization.data(withJSONObject: json))
    }

    private func waitUntil(_ description: String, condition: @escaping () -> Bool) {
        let expectation = expectation(description: description)
        func poll() {
            if condition() {
                expectation.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.005, execute: poll)
            }
        }
        poll()
        wait(for: [expectation], timeout: 2)
    }
}
