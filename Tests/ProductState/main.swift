import Foundation

@main struct ProductStateChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
            precondition(condition(), description); checks += 1
        }
        func voiceRoute(current: Bool = false, pending: Int = 0, queueRunning: Bool = false,
                        engineRunning: Bool = false, switching: Bool = false, releasing: Bool = false,
                        voicePending: Bool = false, manualBusy: Bool = false, calibrating: Bool = false) -> VoiceTaskRequestRoute {
            VoiceTaskRequestRouter.route(hasCurrentTask: current, pendingTaskCount: pending,
                                         queueRunning: queueRunning, engineRunning: engineRunning,
                                         queueSwitching: switching, engineReleasing: releasing,
                                         voicePending: voicePending, manualBusy: manualBusy,
                                         calibrating: calibrating)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneAgentChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "PhoneAgentConsentChecks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite); PrivacyConsent.revoke() }
        var settings = AgentSettings(); settings.startDelay = 0; settings.stepInterval = 0.5
        expect(!PrivacyConsent.allowed(settings, defaults: defaults), "Consent must be explicit")
        PrivacyConsent.grant(settings, defaults: defaults)
        expect(PrivacyConsent.allowed(settings, defaults: defaults), "Authorized recipient should be usable")
        var changed = settings; changed.endpoint = "https://other.example/v1/chat/completions"
        expect(!PrivacyConsent.allowed(changed, defaults: defaults), "Changed recipient needs new consent")
        changed = settings; changed.providerName = "Changed recipient"
        expect(!PrivacyConsent.allowed(changed, defaults: defaults), "Provider name change invalidates consent")
        defaults.set(Data("corrupt".utf8), forKey: "agent.aiConsent.v1")
        expect(!PrivacyConsent.allowed(settings, defaults: defaults), "Malformed grants fail closed")
        PrivacyConsent.grant(settings, defaults: defaults); PrivacyConsent.revoke(defaults: defaults)
        expect(!PrivacyConsent.allowed(settings, defaults: defaults), "Revocation must take effect")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        object.removeValue(forKey: "providerName")
        let migrated = try JSONDecoder().decode(AgentSettings.self, from: JSONSerialization.data(withJSONObject: object))
        expect(migrated.endpoint == settings.endpoint && migrated.providerName == nil, "Old settings retain endpoint")

        let path = directory.appendingPathComponent("tasks.json")
        let store = TaskHistoryStore(url: path)
        let original = PhoneTaskRecord(title: "Original", goal: "Original goal")
        store.upsert(original); store.rename(original.id, title: "Renamed")
        expect(store.records[0].title == "Renamed", "Rename preserves identity")
        expect(store.records[0].goal == "Original goal", "Rename does not change task instructions")
        let reloaded = TaskHistoryStore(url: path)
        expect(reloaded.records[0].outcome == .interrupted, "Restart never restores an active task")
        expect(reloaded.records[0].id == original.id, "Stored task identity survives restart")
        for i in 0..<55 { store.upsert(PhoneTaskRecord(title: "Task \(i)", goal: "Offline")) }
        expect(store.records.count == 50, "History retention is bounded")
        let newest = store.records[0].id; store.remove(newest)
        expect(!store.records.contains { $0.id == newest }, "Delete persists")
        expect(TaskHistoryStore(url: path).records.count == 49, "Deletion survives reload")
        let corrupt = Data("broken document".utf8); try corrupt.write(to: path)
        let broken = TaskHistoryStore(url: path)
        expect(!broken.error.isEmpty, "Corrupt history shows a recoverable error")
        broken.upsert(original)
        let preserved = try Data(contentsOf: path)
        expect(preserved == corrupt, "Corrupt file must not be overwritten")
        broken.clear(); expect(broken.records.isEmpty && broken.error.isEmpty, "Explicit clear restores storage")
        broken.upsert(original); expect(broken.records.count == 1, "Storage works after clear")

        func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() {
                precondition(Date() < deadline, "State transition timed out")
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let capture = CaptureService(), executor = MouseExecutor()
        let engine = AgentEngine(capture: capture, executor: executor)
        PrivacyConsent.revoke(); ModelProbe.calls = 0
        engine.start(task: "Offline task", settings: settings)
        expect(!engine.running && ModelProbe.calls == 0, "Missing consent blocks inference")
        PrivacyConsent.grant(settings)
        executor.actionDelay = 1_000_000_000
        ModelProbe.action = AgentAction(kind: .tap, x: 0.5, y: 0.5, reason: "Offline tap")
        engine.start(task: "Offline task", settings: settings)
        try await waitUntil { engine.phase == .acting }
        engine.pause()
        expect(engine.phase == .paused && !engine.running, "Pause cancels execution")
        expect(engine.releasing, "Pause closes input before allowing resume")
        engine.resume()
        expect(ModelProbe.calls == 1, "Resume cannot race old release")
        try await waitUntil { !engine.releasing }
        expect(executor.ble.releases > 0 && engine.canResume, "Paused task becomes resumable after cleanup")
        ModelProbe.action = AgentAction(kind: .finish, reason: "Verified offline result")
        engine.resume()
        try await waitUntil { engine.phase == .completed && !engine.releasing }
        expect(executor.actions == [.tap], "Resume does not replay the interrupted action")
        expect(ModelProbe.calls == 2, "Resume obtains a new observation")
        expect(engine.currentRecord?.outcome == .completed, "Completion reaches the history record")
        expect(!engine.canResume, "Completed task cannot resume")

        ModelProbe.action = AgentAction(kind: .ask_user, reason: "Offline human handoff")
        engine.start(task: "Needs human", settings: settings)
        try await waitUntil { engine.phase == .needsUser && !engine.releasing }
        expect(engine.canResume && engine.pendingAction?.kind == .ask_user, "Human handoff retains task context")
        ModelProbe.action = AgentAction(kind: .finish, reason: "Human issue resolved")
        engine.resume()
        try await waitUntil { engine.phase == .completed && !engine.releasing }
        expect(engine.pendingAction == nil, "Resume discards the old pending action")

        ModelProbe.delay = 1_000_000_000; ModelProbe.action = AgentAction(kind: .tap, x: 0.5, y: 0.5, reason: "Cancelled plan")
        engine.start(task: "Cancel inference", settings: settings)
        try await waitUntil { engine.phase == .observing }
        engine.stop(); try await waitUntil { !engine.releasing }
        expect(engine.phase == .stopped && !engine.canResume, "Explicit stop ends the session")
        expect(executor.actions == [.tap], "Cancelled inference never executes its plan")
        expect(engine.currentRecord?.outcome == .stopped, "Stop is persisted")
        expect(VoiceCommand.parse("助手助手，暂停。") == .pause, "Wake prefix and punctuation support a local pause")
        expect(VoiceCommand.parse("豆包豆包，帮我暂停一下任务") == .pause, "Doubao wake prefix and natural pause wording are recognized")
        expect(VoiceCommand.parse("请帮我暂停当前任务") == .pause, "Polite pause command is recognized")
        expect(VoiceCommand.parse("豆包豆包，我来接管") == .handoff, "Doubao wake prefix supports human handoff")
        expect(VoiceCommand.parse("豆包豆包，帮我继续任务") == .resume, "Doubao wake prefix supports resume")
        expect(VoiceCommand.parse("豆包豆包，停止任务") == .stop, "Doubao wake prefix supports stop")
        expect(VoiceCommand.parse("豆包豆包，我还要补充要求") == .supplement, "Doubao wake prefix supports supplemental instructions")
        expect(VoiceCommand.parse("豆包豆包豆包豆包，先停一下") == .pause, "Repeated wake phrases still allow an exact pause command")
        expect(VoiceCommand.parse("豆包豆包，我来处理") == .handoff, "Natural handoff wording is recognized")
        expect(VoiceCommand.parse("豆包豆包，可以继续了") == .resume, "Natural resume wording is recognized")
        expect(VoiceCommand.parse("豆包豆包，再加一个要求") == .supplement, "Natural supplement wording is recognized")
        expect(VoiceCommand.parse("我有一个补充要求") == nil, "Non-command supplemental prose is preserved as task text")
        expect(VoiceCommand.parse("我来接管") == .handoff, "Handoff is a local command")
        expect(VoiceCommand.parse("继续任务") == .resume, "Resume is a local command")
        expect(VoiceCommand.parse("不要暂停") == nil, "Negated commands are not intercepted")
        expect(VoiceCommand.parse("打开微信然后暂停") == nil, "A task sentence is not a control command")
        expect(VoiceCommand.parse("补充") == .supplement, "Supplement starts the pause-first input flow")
        expect(voiceRoute() == .start, "An idle voice task starts directly")
        expect(voiceRoute(current: true, engineRunning: true) == .queue, "A spoken task during active execution is queued")
        expect(voiceRoute(current: true) == .queue, "A spoken task during a paused task is queued")
        expect(voiceRoute(pending: 1) == .queue, "A spoken task joins an existing queue")
        expect(voiceRoute(current: true, pending: 1, queueRunning: true, engineRunning: true) == .queue,
               "A spoken task joins a queue while it is running")
        expect(voiceRoute(current: true, switching: true) == .busy, "Task switching blocks voice queue changes")
        expect(voiceRoute(current: true, releasing: true) == .busy, "Input release blocks voice queue changes")
        expect(voiceRoute(voicePending: true) == .busy, "Voice preparation blocks duplicate requests")
        expect(voiceRoute(manualBusy: true) == .busy, "Manual input blocks voice queue changes")
        expect(voiceRoute(current: true, calibrating: true) == .busy, "Calibration blocks voice queue changes")
        expect(voiceRoute(queueRunning: true) == .busy, "An inconsistent active queue cannot start a second task")
        var oldTask = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        oldTask.removeValue(forKey: "amendments")
        let oldRecord = try JSONDecoder().decode(PhoneTaskRecord.self, from: JSONSerialization.data(withJSONObject: oldTask))
        expect(oldRecord.effectiveGoal == oldRecord.goal, "Older history has no implicit supplemental instructions")

        let actionCount = executor.actions.count
        engine.start(task: "Open a page", settings: settings)
        try await waitUntil { engine.phase == .observing }
        let taskID = engine.currentRecord?.id, step = engine.currentStep
        do { try engine.amendTask("  "); preconditionFailure("Empty supplement was accepted") } catch {}
        expect(engine.running, "An invalid supplement cannot interrupt the task")
        try engine.amendTask("Only inspect; do not send anything")
        expect(engine.phase == .paused && !engine.running, "Supplement cancels the old plan and waits for Continue")
        expect(engine.currentRecord?.id == taskID && engine.currentStep == step, "Supplement preserves task identity and progress")
        expect(engine.currentRecord?.goal == "Open a page", "Original goal remains visible")
        expect(engine.currentRecord?.amendments?.count == 1, "Supplement is recorded once")
        try await waitUntil { !engine.releasing }
        expect(executor.actions.count == actionCount, "The interrupted model response cannot execute")
        let supplemented = engine.currentRecord!
        store.upsert(supplemented)
        expect(TaskHistoryStore(url: path).records.first?.effectiveGoal == supplemented.effectiveGoal, "Supplement survives history reload")
        ModelProbe.delay = 0; ModelProbe.action = AgentAction(kind: .finish, reason: "New requirements verified")
        engine.resume()
        try await waitUntil { engine.phase == .completed && !engine.releasing }
        expect(ModelProbe.goals.last?.contains("Only inspect; do not send anything") == true, "The next model observation receives the new instructions")
        do { try engine.amendTask("Too late"); preconditionFailure("Completed task was amended") } catch {}
        expect(engine.currentRecord?.amendments?.count == 1, "A completed task rejects amendments")

        ModelProbe.delay = 1_000_000_000
        engine.start(task: "Human takeover", settings: settings)
        try await waitUntil { engine.phase == .observing }
        engine.handoff()
        expect(engine.phase == .needsUser && !engine.running && engine.pendingAction == nil, "User takeover discards the pending plan")
        try await waitUntil { !engine.releasing }
        expect(engine.canResume, "Takeover retains a resumable task")
        expect(executor.actions.count == actionCount, "Takeover prevents the old action")
        engine.stop(); try await waitUntil { !engine.releasing }
        expect(!engine.hasCurrentTask, "Stop removes resume eligibility even after handoff")
        print("\(checks) product-state checks passed. No network, phone or BLE actions.")
    }
}
