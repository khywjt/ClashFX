import AppKit

/// Only this exact selector and these two identified Vless leaves are owned.
struct AIFailoverTopology: Equatable {
    static let group = "Fixture-AI"
    static let candidates = ["Fixture-AI-Primary", "Fixture-AI-Secondary"]
    static let urls = ["https://api.openai.com/v1/models", "https://www.gstatic.com/generate_204"]

    let groupID: String?
    let members: Set<String>
    let leafIDs: [String: String]

    init?(_ snapshot: ClashProxyResp) {
        guard let group = snapshot.proxiesMap[Self.group], group.type == .select,
              Set(Self.candidates).isSubset(of: Set(group.all ?? [])) else { return nil }
        var ids = [String: String]()
        for name in Self.candidates {
            guard let leaf = snapshot.proxiesMap[name], leaf.name == name,
                  leaf.type == .vless, leaf.all == nil,
                  let id = leaf.id, !id.isEmpty else { return nil }
            ids[name] = id
        }
        guard Set(ids.values).count == Self.candidates.count else { return nil }
        groupID = group.id
        members = Set(group.all ?? [])
        leafIDs = ids
    }
}

/// A menu hook keeps the unhosted menu tests independent of AppDelegate/runtime.
enum AIFailoverMenuIntegration {
    static var makeMenuItem: (() -> NSMenuItem)?
}

final class AIFailoverSupervisor {
    enum Reachability: Equatable {
        case reachable, failed, unknown

        init(_ outcome: ProxyDelayOutcome) {
            switch outcome {
            case .measured: self = .reachable
            // timedOut is a recognized core HTTP 504 probe result. A timeout
            // reaching the controller itself is decoded as unavailable instead.
            case .failed, .timedOut: self = .failed
            case .unavailable, .cancelled: self = .unknown
            }
        }
    }

    struct Dependencies {
        let now: () -> Date
        let scope: () -> AnyHashable
        let profile: () -> String
        let enabled: (_ profile: String) -> Bool
        let setEnabled: (_ profile: String, _ enabled: Bool) -> Void
        let held: (_ profile: String) -> Bool
        let setHeld: (_ profile: String, _ held: Bool) -> Void
        let pauseReason: () -> String?
        let interactionBusy: () -> Bool
        let refresh: (@escaping (ClashProxyResp?) -> Void) -> Void
        let probe: (_ leaf: String, _ url: String, _ completion: @escaping (Reachability) -> Void) -> Void
        let cancel: () -> Void
        let select: (_ snapshot: ClashProxyResp, _ topology: AIFailoverTopology,
                     _ from: String, _ to: String, _ isCurrent: @escaping () -> Bool,
                     _ completion: @escaping (Bool) -> Void) -> Void
        let changed: (_ status: String, _ lastSwitch: String?) -> Void
        var snapshotPauseReason: (ClashProxyResp) -> String? = { _ in nil }
        var manualPauseUntil: (String) -> Date = { _ in .distantPast }
        var setManualPauseUntil: (String, Date) -> Void = { _, _ in }
    }

    private let dependencies: Dependencies
    private var generation: UInt64 = 0
    private var capturedScope: AnyHashable?
    private var capturedProfile: String?
    private var topology: AIFailoverTopology?
    private var selection: String?
    private var failures = [String: Int]()
    private var successes = [String: Int]()
    private var manualUntil = Date.distantPast
    private var cooldownUntil = Date.distantPast
    private var stableAfter = Date.distantPast
    private var nextProbe = Date.distantPast
    private var lastEvidence: Date?
    private var roundStarted: Date?
    private var switching = false
    private var sleeping = false
    private(set) var status = "已关闭"
    private(set) var lastSwitch: String?

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    var isEnabled: Bool { dependencies.enabled(dependencies.profile()) }
    var isHeld: Bool { dependencies.held(dependencies.profile()) }

    func setEnabled(_ enabled: Bool) {
        dependencies.setEnabled(dependencies.profile(), enabled)
        if enabled {
            dependencies.setHeld(dependencies.profile(), false)
            clearManualPause()
            selection = nil
        }
        invalidate(reason: enabled ? "等待新一轮 HTTPS 可达性检查" : "已关闭")
        tick()
    }

    func resume() {
        dependencies.setHeld(dependencies.profile(), false)
        clearManualPause()
        selection = nil
        invalidate(reason: "等待重新确认当前节点")
        tick()
    }

    /// All methods and callbacks run on main. Invalidation also abandons an
    /// in-flight PUT's publication; its selection controller retains the lease.
    func invalidate(reason: String, stabilization: TimeInterval = 0) {
        generation &+= 1
        dependencies.cancel()
        roundStarted = nil
        switching = false
        failures.removeAll()
        successes.removeAll()
        lastEvidence = nil
        stableAfter = max(stableAfter, dependencies.now().addingTimeInterval(stabilization))
        nextProbe = stableAfter
        setStatus(isEnabled ? "暂停：\(reason)" : "已关闭")
    }

    func sleep() {
        sleeping = true
        invalidate(reason: "系统睡眠")
    }

    func wake() {
        sleeping = false
        invalidate(reason: "唤醒后等待网络稳定", stabilization: 20)
    }

    func manualSelection(group: String, name: String?) {
        invalidate(reason: "手动选择进行中")
        guard isEnabled, group == AIFailoverTopology.group else { return }
        selection = name
        if let name, AIFailoverTopology.candidates.contains(name) {
            manualUntil = dependencies.now().addingTimeInterval(300)
            dependencies.setManualPauseUntil(dependencies.profile(), manualUntil)
            setStatus("暂停：手动选择后保留 5 分钟")
        } else {
            dependencies.setHeld(dependencies.profile(), true)
            setStatus("暂停：已手选其他节点；请明确恢复自动切换")
        }
    }

    func tick() {
        dispatchPrecondition(condition: .onQueue(.main))
        let scope = dependencies.scope()
        let profile = dependencies.profile()
        if scope != capturedScope || profile != capturedProfile {
            let profileChanged = profile != capturedProfile
            invalidate(reason: "配置或核心范围变化", stabilization: 10)
            capturedScope = scope
            capturedProfile = profile
            topology = nil
            selection = nil
            if profileChanged {
                manualUntil = dependencies.manualPauseUntil(profile)
                cooldownUntil = .distantPast
                lastSwitch = nil
            }
        }
        guard isEnabled else { setStatus("已关闭"); return }
        guard !sleeping else { return }
        if let reason = dependencies.pauseReason() {
            invalidate(reason: reason, stabilization: 10)
            return
        }
        if !switching, dependencies.interactionBusy() {
            invalidate(reason: "节点选择进行中", stabilization: 10)
            return
        }
        guard !isHeld else {
            setStatus("暂停：已手选其他节点；请明确恢复自动切换")
            return
        }
        let now = dependencies.now()
        guard now >= stableAfter else { return }
        guard now >= manualUntil else { setStatus("暂停：手动选择后保留 5 分钟"); return }
        guard now >= cooldownUntil else { setStatus("冷却中：保持当前节点至少 120 秒"); return }
        if let started = roundStarted {
            if now.timeIntervalSince(started) >= 40 {
                invalidate(reason: "检测过期，保留当前选择", stabilization: 30)
            }
            return
        }
        guard !switching, now >= nextProbe else { return }
        if let lastEvidence, now.timeIntervalSince(lastEvidence) > 90 {
            failures.removeAll()
            successes.removeAll()
        }
        roundStarted = now
        let token = generation
        dependencies.refresh { [weak self] snapshot in
            guard let self, self.isCurrent(token) else { return }
            guard let snapshot else {
                self.finishUnknown("核心 API 不可用，保留当前选择")
                return
            }
            self.beginProbes(snapshot: snapshot, token: token)
        }
    }

    private func beginProbes(snapshot: ClashProxyResp, token: UInt64) {
        guard let liveTopology = AIFailoverTopology(snapshot) else {
            finishUnknown("候选缺失、身份不可确认或 AI 分组不是 Selector")
            return
        }
        if let reason = dependencies.snapshotPauseReason(snapshot) {
            finishUnknown(reason)
            return
        }
        if topology != nil, topology != liveTopology {
            topology = liveTopology
            selection = nil
            invalidate(reason: "AI 分组或候选身份变化", stabilization: 30)
            return
        }
        topology = liveTopology
        guard let current = snapshot.proxiesMap[AIFailoverTopology.group]?.now,
              AIFailoverTopology.candidates.contains(current) else {
            dependencies.setHeld(dependencies.profile(), true)
            invalidate(reason: "当前选择不在两个候选内；请明确恢复自动切换")
            return
        }
        if let selection, selection != current {
            manualSelection(group: AIFailoverTopology.group, name: current)
            return
        }
        selection = current
        // Serial requests avoid overlap and shared core URLTest state races.
        let work = AIFailoverTopology.candidates.flatMap { leaf in
            AIFailoverTopology.urls.map { (leaf, $0) }
        }
        probe(work, index: 0, results: [:], snapshot: snapshot, topology: liveTopology,
              current: current, token: token)
    }

    private func probe(_ work: [(String, String)], index: Int,
                       results: [String: [Reachability]], snapshot: ClashProxyResp,
                       topology: AIFailoverTopology, current: String, token: UInt64) {
        guard isCurrent(token) else { return }
        guard index < work.count else {
            evaluate(results, snapshot: snapshot, topology: topology, current: current, token: token)
            return
        }
        let (leaf, url) = work[index]
        dependencies.probe(leaf, url) { [weak self] outcome in
            guard let self, self.isCurrent(token) else { return }
            var updated = results
            updated[leaf, default: []].append(outcome)
            self.probe(work, index: index + 1, results: updated, snapshot: snapshot,
                       topology: topology, current: current, token: token)
        }
    }

    private func evaluate(_ results: [String: [Reachability]], snapshot: ClashProxyResp,
                          topology: AIFailoverTopology, current: String, token: UInt64) {
        guard let other = AIFailoverTopology.candidates.first(where: { $0 != current }) else { return }
        let currentResults = results[current] ?? []
        let otherResults = results[other] ?? []
        guard currentResults.count == AIFailoverTopology.urls.count,
              otherResults.count == AIFailoverTopology.urls.count,
              !currentResults.contains(.unknown), !otherResults.contains(.unknown) else {
            finishUnknown("检测结果不确定，保留当前选择")
            return
        }
        for name in AIFailoverTopology.candidates {
            let values = results[name] ?? []
            let healthy = values.allSatisfy { $0 == .reachable }
            successes[name] = healthy ? successes[name, default: 0] + 1 : 0
            // Count a failed endpoint only when the other node reached that
            // SAME endpoint in this round; shared service failures cannot vote.
            let peer = name == current ? other : current
            let peerValues = results[peer] ?? []
            let contrastedFailure = values.indices.contains {
                values[$0] == .failed && peerValues[$0] == .reachable
            }
            failures[name] = contrastedFailure ? failures[name, default: 0] + 1 : 0
        }
        lastEvidence = dependencies.now()
        guard failures[current, default: 0] >= 3, successes[other, default: 0] >= 2 else {
            roundStarted = nil
            dependencies.cancel()
            nextProbe = dependencies.now().addingTimeInterval(30)
            if currentResults.allSatisfy({ $0 == .reachable }) {
                setStatus("监督中：当前节点 HTTPS 可达，保持选择")
            } else if !otherResults.allSatisfy({ $0 == .reachable }) {
                setStatus("两节点未同时满足可达条件，保留当前选择")
            } else {
                setStatus("当前节点连续失败 \(failures[current, default: 0])/3，等待确认")
            }
            return
        }
        roundStarted = nil
        switching = true
        setStatus("正在确认 AI 分组并切换候选")
        dependencies.select(snapshot, topology, current, other, { [weak self] in
            self?.isCurrent(token) == true
        }) { [weak self] confirmed in
            guard let self, self.isCurrent(token) else { return }
            self.roundStarted = nil
            self.switching = false
            self.dependencies.cancel()
            self.failures.removeAll()
            self.successes.removeAll()
            // Also back off after an uncertain PUT/readback. Never blindly retry.
            self.cooldownUntil = self.dependencies.now().addingTimeInterval(120)
            if confirmed {
                self.selection = other
                self.lastSwitch = "\(current) → \(other)：连续 3 轮失败，另一节点连续通过"
                self.setStatus("切换已读回确认；冷却 120 秒，保留现有连接")
            } else {
                self.selection = nil
                self.setStatus("切换未确认；保留核心实际选择，120 秒后重新观察")
            }
        }
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        if generation == token, let started = roundStarted,
           dependencies.now().timeIntervalSince(started) >= 40 {
            invalidate(reason: "检测过期，保留当前选择", stabilization: 30)
            return false
        }
        guard generation == token, isEnabled, !sleeping,
              capturedScope == dependencies.scope(), capturedProfile == dependencies.profile(),
              dependencies.pauseReason() == nil else {
            if generation == token { invalidate(reason: "操作范围变化或检测已暂停", stabilization: 10) }
            return false
        }
        if !switching, dependencies.interactionBusy() {
            invalidate(reason: "节点选择进行中", stabilization: 10)
            return false
        }
        return true
    }

    private func finishUnknown(_ reason: String) {
        invalidate(reason: reason, stabilization: 30)
    }

    private func clearManualPause() {
        manualUntil = .distantPast
        dependencies.setManualPauseUntil(dependencies.profile(), .distantPast)
    }

    private func setStatus(_ value: String) {
        guard value != status else { return }
        status = value
        dependencies.changed(value, lastSwitch)
    }
}
