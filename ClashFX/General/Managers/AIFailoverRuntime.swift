import AppKit

/// App-owned adapter: no helper, extra process, routing port, or live config edits.
final class AIFailoverRuntime: NSObject {
    private weak var app: AppDelegate?
    private var timer: Timer?
    private var session: ApiRequest.BenchmarkSession?
    private var manualObserver: NSObjectProtocol?
    private let menuItems = NSHashTable<NSMenuItem>.weakObjects()

    private(set) lazy var supervisor = AIFailoverSupervisor(dependencies: .init(
        now: Date.init,
        scope: { ApiRequest.currentAIFailoverScope() },
        profile: { Self.profileKey },
        enabled: { Settings.aiFailoverEnabledProfiles.contains($0) },
        setEnabled: { profile, enabled in
            var profiles = Settings.aiFailoverEnabledProfiles.filter { $0 != profile }
            if enabled { profiles.append(profile) }
            Settings.aiFailoverEnabledProfiles = profiles
        },
        held: { Settings.aiFailoverHeldProfiles.contains($0) },
        setHeld: { profile, held in
            var profiles = Settings.aiFailoverHeldProfiles.filter { $0 != profile }
            if held { profiles.append(profile) }
            Settings.aiFailoverHeldProfiles = profiles
        },
        pauseReason: { [weak self] in
            guard let app = self?.app else { return "应用尚未就绪" }
            return app.aiFailoverPauseReason()
        },
        interactionBusy: { ProxyGroupSelectionController.isAnyOperationInProgress },
        refresh: { [weak self] complete in
            guard let self else { complete(nil); return }
            ApiRequest.getFreshProxyGroupList(session: self.currentSession(), quiet: true, callback: complete)
        },
        probe: { [weak self] leaf, url, complete in
            guard let self else { complete(.unknown); return }
            ApiRequest.getAIFailoverReachability(proxyName: leaf, url: url,
                                                 session: self.currentSession(), callback: complete)
        },
        cancel: { [weak self] in self?.cancelRequests() },
        select: { [weak self] snapshot, topology, from, to, isCurrent, complete in
            self?.select(snapshot, topology: topology, from: from, to: to,
                         isCurrent: isCurrent, completion: complete)
        },
        changed: { [weak self] status, lastSwitch in
            let detail = status.hasPrefix("切换已读回确认") ? lastSwitch.map { "；\($0)" } ?? "" : ""
            Logger.log("[AI Failover] \(status)\(detail)")
            self?.updateMenuItems()
        },
        snapshotPauseReason: { [weak self] snapshot in
            if let reason = self?.app?.aiFailoverClaudeLockPauseReason() { return reason }
            return Self.claudeLockIsSeparate(snapshot) ? nil : "Claude 固定锁目标无法与 AI 分组安全分离"
        },
        manualPauseUntil: { profile in
            Settings.aiFailoverManualPauseUntil[profile].map(Date.init(timeIntervalSince1970:)) ?? .distantPast
        },
        setManualPauseUntil: { profile, until in
            var values = Settings.aiFailoverManualPauseUntil
            values[profile] = until == .distantPast ? nil : until.timeIntervalSince1970
            Settings.aiFailoverManualPauseUntil = values
        }
    ))

    private static var profileKey: String {
        if let remote = RemoteControlManager.selectConfig?.uuid { return "remote:\(remote)" }
        return "local:\(ConfigManager.selectConfigName)"
    }

    init(app: AppDelegate) {
        self.app = app
        super.init()
    }

    func start() {
        AIFailoverMenuIntegration.makeMenuItem = { [weak self] in
            self?.makeMenuItem() ?? NSMenuItem()
        }
        manualObserver = NotificationCenter.default.addObserver(
            forName: ProxyGroupSelectionController.manualSelectionWillBegin, object: nil, queue: .main
        ) { [weak self] note in
            self?.supervisor.manualSelection(group: note.userInfo?["group"] as? String ?? "",
                                             name: note.userInfo?["name"] as? String)
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.supervisor.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        supervisor.tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        supervisor.invalidate(reason: "应用退出")
        if let manualObserver { NotificationCenter.default.removeObserver(manualObserver) }
        manualObserver = nil
        AIFailoverMenuIntegration.makeMenuItem = nil
    }

    private func currentSession() -> ApiRequest.BenchmarkSession {
        if let session { return session }
        let session = ApiRequest.BenchmarkSession()
        self.session = session
        return session
    }

    private func cancelRequests() {
        session?.cancel()
        session = nil
    }

    private func select(_ snapshot: ClashProxyResp, topology: AIFailoverTopology,
                        from: String, to: String, isCurrent: @escaping () -> Bool,
                        completion: @escaping (Bool) -> Void) {
        guard isCurrent(), let app, app.aiFailoverPauseReason() == nil,
              let group = snapshot.proxiesMap[AIFailoverTopology.group] else {
            completion(false)
            return
        }
        let session = currentSession()
        let profile = ConfigManager.selectConfigName
        let controller = ProxyGroupSelectionController(group: group, snapshot: snapshot, dependencies: .init(
            isCurrent: isCurrent,
            isCoreChanging: { [weak app] in app?.aiFailoverPauseReason() != nil },
            isBusyBenchmark: { [weak app] in app?.isSpeedTesting != false },
            isInteractionReserved: { [weak app] in app?.isConfigUpdateQueued != false },
            select: { group, leaf, done in
                ApiRequest.updateProxyGroup(group: group, selectProxy: leaf, session: session, callback: done)
            },
            reset: { _, done in done(false) },
            refresh: { done in
                ApiRequest.getFreshProxyGroupList(session: session, quiet: true, callback: done)
            },
            publish: { fresh in
                // Menu rebuilds may invalidate old menu controllers. Defer the
                // render until this confirmed operation has released its lease.
                DispatchQueue.main.async {
                    guard isCurrent() else { return }
                    MenuItemFactory.applyRefreshResult(fresh, mode: .incremental)
                }
            },
            rememberSelection: { group, name in
                MenuItemFactory.rememberSelection(group: group, name: name, configName: profile)
            },
            closeConnections: {},
            showError: { _ in },
            stageTimeout: 10
        ))
        controller.selectAutomatically(name: to, expectedSelection: from, validateSnapshot: { fresh in
            isCurrent() && AIFailoverTopology(fresh) == topology && Self.claudeLockIsSeparate(fresh)
                && app.aiFailoverClaudeLockPauseReason() == nil
        }, completion: completion)
    }

    /// A lock aimed at a selector cannot be treated as an independent fixed leaf.
    private static func claudeLockIsSeparate(_ snapshot: ClashProxyResp) -> Bool {
        guard Settings.claudeProxyLockEnabled else { return true }
        guard let target = snapshot.proxiesMap[Settings.claudeProxyLockTarget] else { return false }
        return !ClashProxyType.isProxyGroup(target) && !ClashProxyType.isBuiltInProxy(target)
            && target.all == nil && target.id != nil
    }

    private func makeMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: NSLocalizedString("AI Node Automatic Failover", comment: ""), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: root.title)
        let toggle = NSMenuItem(title: NSLocalizedString("Enable AI Node Automatic Failover", comment: ""),
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let status = NSMenuItem(title: supervisor.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let last = NSMenuItem(title: supervisor.lastSwitch ?? "最近切换：尚无", action: nil, keyEquivalent: "")
        last.isEnabled = false
        menu.addItem(last)
        let resume = NSMenuItem(title: NSLocalizedString("Resume AI Node Automatic Failover", comment: ""),
                                action: #selector(resume), keyEquivalent: "")
        resume.target = self
        menu.addItem(resume)
        menu.addItem(.separator())
        let scope = NSMenuItem(title: "仅检查 HTTPS 可达性；不覆盖独立 Claude 代理锁", action: nil, keyEquivalent: "")
        scope.isEnabled = false
        menu.addItem(scope)
        root.submenu = menu
        menuItems.add(root)
        updateMenuItems()
        return root
    }

    private func updateMenuItems() {
        for root in menuItems.allObjects {
            root.state = supervisor.isEnabled ? .on : .off
            guard let items = root.submenu?.items, items.count >= 4 else { continue }
            items[0].state = root.state
            items[1].title = supervisor.status
            items[2].title = supervisor.lastSwitch ?? "最近切换：尚无"
            items[2].toolTip = supervisor.lastSwitch
            items[3].isEnabled = supervisor.isEnabled
        }
    }

    @objc private func toggleEnabled() {
        supervisor.setEnabled(!supervisor.isEnabled)
        updateMenuItems()
    }

    @objc private func resume() { supervisor.resume(); updateMenuItems() }
}
