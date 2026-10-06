import SwiftUI

private struct SidebarMainSurface: ViewModifier {
    let open: Bool
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        let edge = MainSurfaceLeadingEdge(radius: 32)
        content
            .mask {
                UnevenRoundedRectangle(topLeadingRadius: open ? 32 : 0,
                                       bottomLeadingRadius: open ? 32 : 0, style: .continuous)
                    .ignoresSafeArea(.container, edges: .vertical)
            }
            .overlay {
                if open {
                    edge.stroke(AgentPalette.ink.opacity(colorScheme == .light ? 0.18 : 0.08),
                                style: StrokeStyle(lineWidth: 0.75, lineCap: .round))
                        .ignoresSafeArea(.container, edges: .vertical)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct MainSurfaceLeadingEdge: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height / 2))
        var path = Path()
        path.move(to: CGPoint(x: r, y: 0))
        path.addCurve(to: CGPoint(x: 0, y: r),
                      control1: CGPoint(x: r * 0.46, y: 0),
                      control2: CGPoint(x: 0, y: r * 0.46))
        path.addLine(to: CGPoint(x: 0, y: rect.maxY - r))
        path.addCurve(to: CGPoint(x: r, y: rect.maxY),
                      control1: CGPoint(x: 0, y: rect.maxY - r * 0.46),
                      control2: CGPoint(x: r * 0.46, y: rect.maxY))
        return path
    }
}

private enum WorkspaceSheet: Identifiable {
    case task(UUID), plan, preparation, consent, policy, settings, tool(ToolApproval)
    var id: String {
        switch self {
        case .task(let id): return id.uuidString
        case .plan: return "plan"
        case .preparation: return "preparation"
        case .consent: return "consent"
        case .policy: return "policy"
        case .settings: return "settings"
        case .tool(let value): return "tool:" + value.id.uuidString
        }
    }
}
private enum TaskScreen: Hashable {
    case draft, conversation(UUID)
}

private enum ConversationEvent: Identifiable {
    case activity(AgentLogEntry), amendment(TaskAmendment)
    var id: UUID {
        switch self { case .activity(let log): return log.id; case .amendment(let addition): return addition.id }
    }
    var date: Date {
        switch self { case .activity(let log): return log.date; case .amendment(let addition): return addition.createdAt }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var tab = 0
    @State private var navigationForward = true
    @State private var calibration: CalibrationModel?
    @State private var showCalibration = false
    @State private var sheet: WorkspaceSheet?
    @State private var pendingSheet: WorkspaceSheet?
    @State private var dismissingSheet = false
    @State private var confirmingWorkbenchExit = false
    @State private var pendingDestination: Int?
    @State private var pendingDestinationSheet: WorkspaceSheet?
    @State private var screen: TaskScreen = .draft
    @State private var sidebarOpen = false
    @State private var modeSwitcherOpen = false
    @State private var newAssistantRequest = UUID()
    @State private var reviewVoicePhase: DictationPhase?
    private let reviewVoiceError: String
    @State private var dictatedDraft: String?
    @State private var voiceCommandTask: Task<Void, Never>?
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.28, dampingFraction: 1))) private var sidebarDrag: CGFloat = 0
    @State private var viewportWidth: CGFloat = 393
    @State private var preparationExpanded = false
    @State private var expandedSteps = false
    @State private var followLatest = true
    @State private var appeared = false
    @State private var discardingDraft = false
    @State private var amendmentDrafts: [UUID: String] = [:]
    @State private var searchText = ""
    @State private var sidebarSearchExpanded = false
    @FocusState private var composing: Bool
    @Namespace private var glassNamespace
    private var calibrated: Bool { model.calibrationReady }
    private var sidebarWidth: CGFloat { min(viewportWidth * 0.77, 360) }
    private var sidebarScrimColor: Color {
        colorScheme == .light ? Color.white.opacity(0.4) : Color.black.opacity(0.4)
    }
    private var busy: Bool { model.recordingAudioOwner != nil || model.queueSwitching || model.engine.running || model.engine.releasing || model.manualBusy || model.voicePending }
    private var filteredTasks: [PhoneTaskRecord] {
        guard !searchText.isEmpty else { return model.history.records }
        return model.history.records.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.effectiveGoal.localizedCaseInsensitiveContains(searchText) }
    }
    private var groupedHistory: [(title: String, records: [PhoneTaskRecord])] {
        let calendar = Calendar.current
        let now = Date()
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        var today: [PhoneTaskRecord] = []
        var yesterday: [PhoneTaskRecord] = []
        var pastWeek: [PhoneTaskRecord] = []
        var older: [PhoneTaskRecord] = []
        for record in filteredTasks {
            if calendar.isDateInToday(record.createdAt) {
                today.append(record)
            } else if calendar.isDateInYesterday(record.createdAt) {
                yesterday.append(record)
            } else if record.createdAt >= sevenDaysAgo {
                pastWeek.append(record)
            } else {
                older.append(record)
            }
        }
        var sections: [(title: String, records: [PhoneTaskRecord])] = []
        if !today.isEmpty { sections.append(("今天", today)) }
        if !yesterday.isEmpty { sections.append(("昨天", yesterday)) }
        if !pastWeek.isEmpty { sections.append(("过去 7 天", pastWeek)) }
        if !older.isEmpty { sections.append(("更早", older)) }
        return sections
    }
    private var displayedRecord: PhoneTaskRecord? {
        guard case .conversation(let id) = screen else { return nil }
        if model.engine.currentRecord?.id == id { return model.engine.currentRecord }
        return model.history.records.first { $0.id == id }
    }
    private var isCurrentConversation: Bool {
        guard let record = displayedRecord else { return false }
        return record.id == model.engine.currentRecord?.id
    }
    private var composingSupplement: Bool {
        guard let record = displayedRecord, isCurrentConversation else { return false }
        return model.engine.hasCurrentTask || !(amendmentDrafts[record.id] ?? "").isEmpty
    }
    private var composerText: Binding<String> {
        if composingSupplement, let id = displayedRecord?.id {
            return Binding(get: { amendmentDrafts[id] ?? "" }, set: { amendmentDrafts[id] = $0 })
        }
        return $model.goal
    }
    private var queueingDraft: Bool { !composingSupplement && (model.engine.hasCurrentTask || model.taskQueue.pendingCount > 0 || model.queueRunning) }
    private var inputBlocked: Bool {
        model.recordingAudioOwner != nil || model.queueSwitching || model.calibrating || model.manualBusy || model.voicePending || model.engine.releasing
    }
    init(reviewTab: Int = 0, reviewConversation: UUID? = nil, reviewVoice: DictationPhase? = nil, reviewVoiceError: String = "") {
        _tab = State(initialValue: reviewTab)
        _reviewVoicePhase = State(initialValue: reviewVoice)
        self.reviewVoiceError = reviewVoiceError
        _screen = State(initialValue: reviewConversation.map { .conversation($0) } ?? .draft)
    }
    var body: some View {
        ZStack {
            // The shifted main page is the raised surface; the sidebar stays flat.
            (sidebarOpen ? AgentPalette.surface : AgentPalette.background)
                .ignoresSafeArea().accessibilityHidden(true)
            Group {
                switch tab {
                case 1: capturePage
                case 2: mousePage
                case 3: SettingsView(onBack: { navigate(0) })
                case 4: AssistantView(newConversationRequest: newAssistantRequest, reviewDictation: reviewVoicePhase, allowsDictation: sheet == nil && !sidebarOpen && !modeSwitcherOpen, onModelSetup: { navigate(3) })
                case 5: MemoryView()
                case 6: WorkbenchView()
                case 7: TaskQueueView()
                default: taskPage
                }
            }.id(tab).transition(pageTransition)
        }
        .animation(pageAnimation, value: tab).tint(AgentPalette.accent)
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if tab != 3 { topBar }
                AgentPiPPanel(controller: model.pip)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .modifier(SidebarMainSurface(open: sidebarOpen))
        .offset(x: sidebarOpen && !reduceMotion ? max(0, sidebarWidth + sidebarDrag) : 0)
        .accessibilityHidden(sidebarOpen)
        .overlay { sidebarOverlay }
        .sheet(item: $sheet, onDismiss: {
            dismissingSheet = false
            if let next = pendingSheet {
                pendingSheet = nil
                sheet = next
            } else { consumeModalRequests() }
        }) { route in
            Group { switch route {
            case .task(let id): TaskDetailView(id: id)
            case .plan: TaskPlanView()
            case .preparation:
                PreparationView { destination in sheet = nil; model.showPreparation = false; navigate(destination) }
            case .consent: DataConsentView(onDecision: dismissCurrentSheet)
            case .policy: DataPolicyView()
            case .settings: SettingsView(onBack: dismissCurrentSheet)
            case .tool(let value): ToolApprovalView(approval: value)
            } }.agentSheetStyle()
        }
        .fullScreenCover(isPresented: $showCalibration, onDismiss: { model.calibrating = false; model.cancelCalibration = nil }) {
            if let calibration { CalibrationView(model: calibration) }
        }
        .onAppear {
            if model.engine.hasCurrentTask, let record = model.engine.currentRecord { screen = .conversation(record.id) }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { appeared = true }
            configureAutomaticPiP(model.settings.autoPiPOnExit ?? false)
            consumeModalRequests()
            if let mode = model.voiceMode { routeInlineVoice(mode) }
        }
        .onOpenURL { url in if url.scheme == "phoneagent", url.host == "task", let record = model.engine.currentRecord { openConversation(record) } }
        .onChange(of: model.engine.currentRecord?.id) { _, id in
            if let id {
                if screen == .draft, model.goal == model.engine.currentRecord?.goal { model.goal = "" }
                screen = .conversation(id); expandedSteps = false; followLatest = true
            }
        }
        .onChange(of: model.history.records.map(\.id)) { _, ids in
            if case .conversation(let id) = screen, !ids.contains(id), model.engine.currentRecord?.id != id { screen = .draft }
        }
        .onChange(of: model.showPrivacyConsent) { _, show in
            if show { consumeModalRequests() }
        }
        .onChange(of: model.showPreparation) { _, show in if show { consumeModalRequests() } }
        .onChange(of: model.showPrivacyPolicy) { _, show in if show { consumeModalRequests() } }
        .onChange(of: model.voiceRequestID) { _, _ in navigate(model.voiceMode == .question ? 4 : 0); setSidebar(false); composing = false }
        .onChange(of: model.voiceMode) { _, mode in
            if let mode { routeInlineVoice(mode) }
        }
        .onChange(of: model.tools.pending?.id) { _, id in
            if let value = model.tools.pending { present(.tool(value)) }
            else {
                if pendingSheet?.id.hasPrefix("tool:") == true { pendingSheet = nil }
                if sheet?.id.hasPrefix("tool:") == true { dismissCurrentSheet() }
            }
        }
        .onChange(of: model.showAssistant) { _, show in if show { model.showAssistant = false; navigate(4) } }
        .onChange(of: model.settings.autoPiPOnExit) { _, value in
            configureAutomaticPiP(value ?? false)
        }
        .alert("离开记录与文件？", isPresented: $confirmingWorkbenchExit) {
            Button("继续编辑", role: .cancel) { pendingDestination = nil; pendingDestinationSheet = nil }
            Button("离开并清空草稿", role: .destructive) {
                if let destination = pendingDestination {
                    let route = pendingDestinationSheet
                    pendingDestination = nil; pendingDestinationSheet = nil
                    completeNavigation(destination, showing: route)
                }
            }
        } message: { Text("原文、文件草稿和纪要仅保留在当前工作台会话。继续编辑后可以保存到记忆或导出；离开会清空此页内容。") }
        .confirmationDialog("清空未提交的任务？", isPresented: $discardingDraft, titleVisibility: .visible) {
            Button("清空并新建", role: .destructive) { resetDraft() }
            Button("继续编辑", role: .cancel) {}
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentPiPController.restoreTask)) { _ in
            if let record = model.engine.currentRecord { openConversation(record) } else { navigate(0) }
        }
        .onChange(of: phase) { _, new in
            if new == .active { model.ble.refresh() }
            if new == .active && !model.speech.usingAudio { model.pip.applicationBecameActive() }
            if new == .background && !model.speech.usingAudio { model.pip.applicationEnteredBackground() }
            if new == .background {
                voiceCommandTask?.cancel(); voiceCommandTask = nil
                // The inline composer retains partial text before releasing audio.
                if model.voiceMode == nil { model.speech.cancel() }
            }
            if new != .active && model.manualBusy { model.stop() }
        }
    }
    private func routeInlineVoice(_ mode: VoiceInputMode) {
        composing = false; setSidebar(false)
        navigate(mode == .question ? 4 : 0)
        if mode == .supplement, let record = model.engine.currentRecord {
            screen = .conversation(record.id)
        }
        if sheet != nil { pendingSheet = nil; dismissCurrentSheet() }
    }
    private var voiceComposerText: Binding<String> {
        if model.voiceMode == .supplement, let id = model.engine.currentRecord?.id {
            return Binding(get: { amendmentDrafts[id] ?? "" }, set: { amendmentDrafts[id] = $0 })
        }
        return $model.goal
    }
    private func consumeModalRequests() {
        if model.showPrivacyConsent {
            model.showPrivacyConsent = false; composing = false; present(.consent)
        } else if model.showPreparation {
            model.showPreparation = false; composing = false; present(.preparation)
        } else if model.showPrivacyPolicy {
            model.showPrivacyPolicy = false; present(.policy)
        }
    }
    private func present(_ route: WorkspaceSheet) {
        composing = false
        setSidebar(false)
        if sheet == nil, !dismissingSheet { sheet = route }
        else if sheet?.id != route.id {
            pendingSheet = route; dismissingSheet = true; sheet = nil
        }
    }
    private func dismissCurrentSheet() {
        // A queued destination opens only after the current presentation has closed.
        dismissingSheet = true; sheet = nil
    }
    private var pageAnimation: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.28, bounce: 0) }
    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(x: navigationForward ? 18 : -18)),
            removal: .opacity.combined(with: .offset(x: navigationForward ? -10 : 10)))
    }
    private func navigate(_ destination: Int, showing route: WorkspaceSheet? = nil) {
        setSidebar(false)
        if destination == 3 { present(.settings); return }
        guard destination != tab else { if let route { present(route) }; return }
        if tab == 6 && model.workbenchHasDraft {
            pendingDestination = destination; pendingDestinationSheet = route
            composing = false; confirmingWorkbenchExit = true; return
        }
        completeNavigation(destination, showing: route)
    }
    private func completeNavigation(_ destination: Int, showing route: WorkspaceSheet? = nil) {
        if (4...6).contains(destination) && (model.engine.running || model.voicePending) { model.pauseTask() }
        navigationForward = destination != 0; tab = destination; composing = false
        if let route { present(route) }
    }
    private var isConversationMode: Bool { tab == 0 || tab == 4 }
    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                if isConversationMode { composing = false; setSidebar(true) } else { navigate(0) }
            } label: {
                Image(systemName: isConversationMode ? "line.3.horizontal" : "chevron.left")
                    .font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44)
                    .agentGlass(in: Circle(), interactive: true)
            }.buttonStyle(AgentPressStyle()).tint(.primary)
                .accessibilityLabel(isConversationMode ? "打开任务与工具侧栏" : "返回任务")
            if !isConversationMode { Text(pageTitle).font(.headline).lineLimit(1) }
            Spacer(minLength: 8)
            if !isConversationMode {
                Button { navigate(3) } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                    .tint(.primary).buttonStyle(AgentPressStyle()).accessibilityLabel("设置")
            }
        }
        .overlay {
            if isConversationMode { modeSwitcher }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
    private var modeSwitcher: some View {
        Button { composing = false; modeSwitcherOpen.toggle() } label: {
            HStack(spacing: 6) {
                Text(tab == 4 ? "问助手" : "操控手机").font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(modeSwitcherOpen ? 180 : 0))
            }
            .padding(.horizontal, 10).frame(height: 44)
            .frame(maxWidth: max(92, min(184, viewportWidth - 216)))
            .agentGlass(in: Capsule(), interactive: true)
        }
        .tint(.primary).buttonStyle(AgentPressStyle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: modeSwitcherOpen)
        .accessibilityLabel("切换模式，当前" + (tab == 4 ? "问助手" : "操控手机"))
        .popover(isPresented: $modeSwitcherOpen, arrowEdge: .top) {
            VStack(spacing: 4) {
                modeOption(title: "操控手机", detail: "执行任务与操控手机", icon: "computermouse", destination: 0)
                modeOption(title: "问助手", detail: model.engine.running || model.voicePending ? "暂停任务，进入对话" : "提问与交流", icon: "bubble.left.and.bubble.right", destination: 4)
            }
            .padding(10).frame(width: min(320, max(240, viewportWidth - 40)))
            .presentationCompactAdaptation(.popover)

        }
    }
    private func modeOption(title: String, detail: String, icon: String, destination: Int) -> some View {
        Button {
            modeSwitcherOpen = false
            navigate(destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 19)).frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if tab == destination { Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)) }
            }
            .foregroundStyle(.primary).padding(14).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(tab == destination ? AgentPalette.ink.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(AgentPressStyle()).accessibilityLabel(title + "，" + detail)
            .accessibilityAddTraits(tab == destination ? .isSelected : [])
    }
    private var pageTitle: String {
        switch tab {
        case 1: return "屏幕共享"
        case 2: return "设备"
        case 4: return "问助手"
        case 5: return "记忆"
        case 6: return "记录与文件"
        case 7: return "任务队列"
        default: return "Phone Agent"
        }
    }
    private var taskPage: some View {
        VStack(spacing: 0) {
            if let active = model.engine.currentRecord, model.engine.hasCurrentTask, !isCurrentConversation {
                Button { openConversation(active) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: model.engine.running ? "circle.dotted" : "pause.circle")
                        Text(active.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(active.outcome.label).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption2)
                    }.font(.caption).frame(minHeight: 44).padding(.horizontal, 14)
                        .background(AgentPalette.inset, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(AgentPressStyle()).padding(.horizontal, 20).padding(.bottom, 8)
            }
            if let record = displayedRecord { conversation(record) }
            else { draftCanvas }
        }
        .opacity(appeared ? 1 : 0).offset(y: appeared || reduceMotion ? 0 : 6)
        .safeAreaBar(edge: .bottom, spacing: 0) { composerArea }
    }
    private var draftCanvas: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 32)
                    VStack(spacing: 14) {
                        AgentOrb(size: 56)
                        Text("让手机为你做些什么？").font(.title2.weight(.semibold))
                        Text("说出目标，让助手操控手机。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.multilineTextAlignment(.center)
                    Spacer(minLength: 32)
                    if !composing {
                        HStack(spacing: 10) {
                            suggestion("浏览朋友圈", icon: "bubble.left", text: "打开微信朋友圈，停留在页面，不发布内容")
                            suggestion("查看电量", icon: "battery.75percent", text: "打开设置，查看电池用量")
                        }.transition(.opacity).padding(.bottom, 12)
                    }
                }.padding(.horizontal, 20).frame(maxWidth: .infinity).frame(minHeight: geometry.size.height)
            }.scrollDismissesKeyboard(.interactively).animation(pageAnimation, value: composing)
        }
    }
    private func suggestion(_ title: String, icon: String, text: String) -> some View {
        Button { model.goal = text; composing = true } label: {
            Label(title, systemImage: icon).font(.subheadline).frame(maxWidth: .infinity, minHeight: AgentInputMetrics.height)
                .agentGlass(in: AgentInputMetrics.shape, interactive: true)
        }.tint(.primary).buttonStyle(AgentPressStyle()).disabled(model.voiceMode != nil || reviewVoicePhase != nil)
    }
    private func promptCard(title: String, subtitle: String, icon: String, goal: String) -> some View {
        Button {
            model.goal = goal
            composing = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(AgentPalette.ink.opacity(0.08), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.left")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AgentPalette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(AgentPalette.ink.opacity(0.08), lineWidth: 0.5)
            }
        }
        .buttonStyle(AgentPressStyle())
        .accessibilityHint("填入输入框，确认后才开始任务")
    }
    private func conversation(_ record: PhoneTaskRecord) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    userMessage(record.goal)

                    operationAccordion(record)

                    ForEach(record.amendments ?? []) { addition in
                        userMessage(addition.text)
                    }

                    taskResponse(record)

                    if !(record.subtasks ?? []).isEmpty {
                        DisclosureGroup("任务清单 · \(record.subtasks?.filter(\.completed).count ?? 0)/\(record.subtasks?.count ?? 0)") {
                            ForEach(record.subtasks ?? []) { item in
                                Label(item.goal, systemImage: item.completed ? "checkmark.circle.fill" : "circle")
                                    .font(.subheadline).padding(.vertical, 6)
                            }
                        }
                        .font(.subheadline)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(AgentPalette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                    }

                    Color.clear.frame(height: 1).id("conversationBottom")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 80
            } action: { _, nearBottom in followLatest = nearBottom }
            .onAppear { reader.scrollTo("conversationBottom", anchor: .bottom) }
            .onChange(of: record.logs.last?.id) { _, _ in
                if followLatest { reader.scrollTo("conversationBottom", anchor: .bottom) }
            }
            .onChange(of: record.amendments?.last?.id) { _, _ in
                if followLatest { reader.scrollTo("conversationBottom", anchor: .bottom) }
            }
        }.id(record.id)
    }

    private func userMessage(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 36)
            Text(text)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(AgentPalette.userBubble, in: RoundedRectangle(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(AgentPalette.ink.opacity(0.08), lineWidth: 0.5)
                }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func operationAccordion(_ record: PhoneTaskRecord) -> some View {
        let activities = record.logs.filter { $0.title != "补充要求" }
        guard !activities.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(pageAnimation) { expandedSteps.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isCurrentConversation && model.engine.running ? "gearshape.2.fill" : "list.bullet.rectangle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isCurrentConversation && model.engine.running ? Color.green : AgentPalette.ink)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("执行步骤")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("\(activities.count)")
                                    .font(.caption2.monospacedDigit().weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(AgentPalette.ink.opacity(0.08), in: Capsule())
                            }
                            if !expandedSteps, let last = activities.last {
                                Text(last.title + (last.detail.isEmpty ? "" : " · " + last.detail))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        if isCurrentConversation && model.engine.running {
                            HStack(spacing: 5) {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                Text("运行中").font(.caption2.weight(.medium)).foregroundStyle(.green)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.green.opacity(0.12), in: Capsule())
                        } else if record.outcome == .completed {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                Text("已完成").font(.caption2.weight(.medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(AgentPalette.ink.opacity(0.06), in: Capsule())
                        }

                        Image(systemName: expandedSteps ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AgentPressStyle())

                if expandedSteps {
                    VStack(alignment: .leading, spacing: 0) {
                        Divider().overlay(AgentPalette.ink.opacity(0.08)).padding(.horizontal, 14)

                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(activities.enumerated()), id: \.element.id) { index, entry in
                                HStack(alignment: .top, spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(index == activities.count - 1 && isCurrentConversation && model.engine.running ? AgentPalette.ink : AgentPalette.ink.opacity(0.12))
                                            .frame(width: 22, height: 22)
                                        Text("\(entry.step > 0 ? entry.step : index + 1)")
                                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                                            .foregroundStyle(index == activities.count - 1 && isCurrentConversation && model.engine.running ? AgentPalette.onContrast : AgentPalette.ink.opacity(0.8))
                                    }

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        if !entry.detail.isEmpty {
                                            Text(entry.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(14)
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(AgentPalette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(AgentPalette.ink.opacity(0.09), lineWidth: 0.5)
            }
        )
    }

    private func taskResponse(_ record: PhoneTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: record.outcome == .completed ? "checkmark.circle.fill" : (record.outcome == .failed ? "exclamationmark.circle.fill" : "sparkles"))
                    .foregroundStyle(record.outcome == .completed ? Color.green : (record.outcome == .failed ? Color.red : AgentPalette.ink))
                    .font(.system(size: 16))
                Text(isCurrentConversation && model.engine.releasing ? "正在停下操作" : record.outcome.label)
                    .font(.subheadline.weight(.semibold))
            }

            Text(isCurrentConversation ? (model.engine.executingAction?.reason ?? model.engine.state) : record.summary)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)

            HStack(spacing: 16) {
                Button {
                    let content = isCurrentConversation ? (model.engine.executingAction?.reason ?? model.engine.state) : record.summary
                    UIPasteboard.general.string = content
                    model.notice = "已复制结果"
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .accessibilityLabel("复制任务结果")

                if !(isCurrentConversation && model.engine.hasCurrentTask) {
                    Button { reuseTask(record) } label: {
                        Label("用作新任务", systemImage: "arrow.up.left")
                    }
                    .accessibilityLabel("把此任务用作新任务草稿")
                }

                ShareLink(item: record.summary) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("分享任务结果")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .buttonStyle(AgentPressStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.top, 4)
    }

    private var taskControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.engine.phase == .awaitingApproval, let action = model.engine.pendingAction {
                Button(action.kind == .complete_subtask ? "确认完成这一步" : "确认执行这一步") { model.engine.approve() }
                    .buttonStyle(AgentButtonStyle()).disabled(model.engine.releasing)
            }
            controlButtons
        }
    }
    private var controlButtons: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            if model.engine.running {
                taskControl("暂停", icon: "pause.fill") { model.pauseTask() }
                taskControl("接管", icon: "hand.raised.fill") { model.pauseTask(handoff: true) }
            } else if model.engine.canResume {
                taskControl("继续", icon: "play.fill") { model.resumeAgent() }
                taskControl("补充", icon: "text.bubble.fill") { composing = true }
            }
            taskControl("停止", icon: "stop.fill", destructive: true) { model.stop() }
        }.disabled(model.engine.releasing || model.voiceMode != nil).padding(.top, 2)
    }
    private func taskControl(_ title: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.subheadline.weight(.medium))
                .foregroundStyle(destructive ? Color.red : AgentPalette.ink)
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(destructive ? Color.red.opacity(0.12) : AgentPalette.ink.opacity(0.08), in: Capsule())
                .overlay { Capsule().stroke(destructive ? Color.red.opacity(0.3) : AgentPalette.ink.opacity(0.12), lineWidth: 0.5) }
        }.buttonStyle(AgentPressStyle())
    }
    private var composerArea: some View {
        VStack(spacing: 8) {
            if isCurrentConversation && model.engine.hasCurrentTask { taskControls }
            if !model.notice.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.caption2)
                    Text(model.notice).font(.caption).lineLimit(2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .accessibilityLabel(model.notice)
            }
            if isCurrentConversation, !model.engine.error.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
                    Text(model.engine.error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
            }
            if preparationExpanded { readiness.transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)) }

            HStack(spacing: 8) {
                Button { withAnimation(pageAnimation) { preparationExpanded.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.preparationReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(model.preparationReady ? Color.green : Color.orange)
                        Text(model.preparationReady ? "已就绪" : "使用准备")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)
                        Image(systemName: preparationExpanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .agentGlass(in: Capsule(), interactive: true)
                }
                .buttonStyle(AgentPressStyle())
                .accessibilityLabel(preparationExpanded ? "收起使用准备" : model.preparationReady ? "已就绪，查看使用准备" : "展开使用准备")

                if model.taskQueue.pendingCount > 0 {
                    Button { navigate(7) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet").font(.system(size: 10))
                            Text("队列 \(model.taskQueue.pendingCount)").font(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .agentGlass(in: Capsule(), interactive: true)
                    }
                    .buttonStyle(AgentPressStyle())
                    .accessibilityLabel("任务队列，\(model.taskQueue.pendingCount) 项待处理")
                }

                Spacer(minLength: 4)

                if composingSupplement || queueingDraft {
                    Text(composingSupplement ? (model.engine.hasCurrentTask ? "补充要求" : "转为新任务") : "加入队列")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)

            composer
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.voiceMode != nil)
        }
        .agentComposerLeadingGlyph(recording: reviewVoicePhase != nil || (model.voiceMode != nil && model.voiceMode != .question))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var composer: some View {
        if let phase = reviewVoicePhase {
            InlineVoiceBar(phase: phase, transcript: phase == .preparing ? "" : "打开微信朋友圈，只查看。",
                           status: "本机语音识别", error: reviewVoiceError, startedAt: Date().addingTimeInterval(-8),
                           onCancel: { reviewVoicePhase = nil }, onFinish: { reviewVoicePhase = nil }, onRetry: {})
        } else if let mode = model.voiceMode, mode != .question {
            let requestID = model.voiceRequestID
            InlineDictationComposer(speech: model.speech, draft: voiceComposerText,
                                    isVisible: sheet == nil && !showCalibration && !sidebarOpen && !modeSwitcherOpen,
                                    isCurrent: { model.voiceMode == mode && model.voiceRequestID == requestID }) { text in
                guard model.voiceMode == mode, model.voiceRequestID == requestID else { return }
                dictatedDraft = text; model.voiceMode = nil
            }.id(requestID).transition(.opacity)
        } else { textComposer.transition(.opacity) }
    }
    private var textComposer: some View {
        HStack(alignment: .center, spacing: 8) {
            Menu {
                Button { navigate(1) } label: { Label("共享屏幕", systemImage: "rectangle.on.rectangle") }
                Button { navigate(2) } label: { Label("设备与校准", systemImage: "computermouse") }
                Button { present(.plan) } label: { Label("组合任务清单", systemImage: "list.number") }.disabled(busy || composingSupplement)
                Button { model.pip.enabled ? model.pip.close() : model.pip.open() } label: { Label("动作画中画", systemImage: "pip.enter") }
            } label: {
                AgentComposerLeadingSlot()
            }
            .tint(.primary).accessibilityLabel("添加任务工具")

            TextField(composingSupplement ? "补充要求…" : "告诉我你想做什么…", text: composerText,
                      prompt: Text(composingSupplement ? "补充要求…" : "告诉我你想做什么…").foregroundStyle(AgentPalette.placeholder), axis: .vertical)
                .lineLimit(1...(typeSize.isAccessibilitySize ? 3 : 5))
                .font(.body)
                .focused($composing)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .accessibilityLabel(composingSupplement ? "补充当前任务的要求" : "新任务内容")

            if !model.taskPlan.isEmpty && !composingSupplement {
                Button { present(.plan) } label: {
                    Text("清单 \(model.taskPlan.count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(AgentPalette.ink.opacity(0.12), in: Capsule())
                }
                .buttonStyle(AgentPressStyle())
            }

            if composerText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    composing = false
                    model.beginVoice(composingSupplement ? .supplement : .task)
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(AgentPalette.ink.opacity(0.08), in: Circle())
                }
                .buttonStyle(AgentPressStyle())
                .disabled(inputBlocked)
                .accessibilityLabel(composingSupplement ? "语音补充要求" : "语音输入任务")
                .transition(.opacity)
            } else {
                Button { submitComposer() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 44, height: 44)
                        .background(AgentPalette.accent, in: Circle())
                }
                .buttonStyle(AgentPressStyle())
                .disabled(inputBlocked)
                .accessibilityLabel(composingSupplement ? (model.engine.hasCurrentTask ? "提交补充并暂停，确认后继续" : "把补充转为新任务草稿") : (queueingDraft ? "加入任务队列" : "开始任务"))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: AgentInputMetrics.height)
        .agentGlass(in: AgentInputMetrics.shape)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: composerText.wrappedValue.isEmpty)
    }
    private func configureAutomaticPiP(_ enabled: Bool) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-review") { return }
        #endif
        model.pip.setAutomaticOnExit(enabled)
    }
    private func submitComposer() {
        guard !inputBlocked else { return }
        composing = false
        let draft = composerText.wrappedValue
        if dictatedDraft == draft, let command = VoiceCommand.parse(draft) {
            composerText.wrappedValue = ""; dictatedDraft = nil
            voiceCommandTask?.cancel()
            voiceCommandTask = Task {
                let result = await model.handleVoiceCommand(command)
                guard !Task.isCancelled else { return }
                model.notice = result; voiceCommandTask = nil
            }
            return
        }
        dictatedDraft = nil
        if composingSupplement, let record = displayedRecord {
            let text = amendmentDrafts[record.id] ?? ""
            if model.engine.hasCurrentTask {
                let previousCount = record.amendments?.count ?? 0
                model.supplementTask(text)
                if (model.engine.currentRecord?.amendments?.count ?? 0) > previousCount { amendmentDrafts[record.id] = nil }
            } else {
                model.goal = text; amendmentDrafts[record.id] = nil; screen = .draft
                model.notice = "补充已保留为新任务。确认后再开始。"
            }
        } else { model.startAgent() }
    }
    private var readiness: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.modelReady ? "连接你的手机" : "准备第一项任务").font(.subheadline.weight(.medium))
                Spacer(minLength: 4)
                Button("查看全部") { present(.preparation) }.font(.caption).frame(minHeight: 44)
            }
            HStack(spacing: 10) {
                if model.settings.toolsOnly == true {
                    setupItem("模型", active: model.modelReady, icon: "sparkles") { navigate(3) }
                    setupItem("授权", active: model.consentReady, icon: "hand.raised") { if model.modelReady { model.requestConsent() } else { navigate(3) } }
                    setupItem("工具", active: model.settings.systemToolsEnabled == true, icon: "wrench") { navigate(3) }
                } else {
                    setupItem("画面", active: model.capture.frame?.fullDisplay == true && model.capture.running, icon: "rectangle.on.rectangle") { navigate(1) }
                    setupItem("配件", active: model.ble.ready, icon: "computermouse") { navigate(2) }
                    setupItem("校准", active: calibrated, icon: "scope") { navigate(2) }
                }
            }.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }.padding(.horizontal, 6).padding(.bottom, 4)
    }
    private func setupItem(_ title: String, active: Bool, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) { Image(systemName: active ? "checkmark.circle" : icon); Text(title) }
                .font(.caption).frame(maxWidth: .infinity, minHeight: 64)
                .agentGlass(in: RoundedRectangle(cornerRadius: 20), interactive: !busy)
        }.buttonStyle(AgentPressStyle()).disabled(busy).opacity(busy ? 0.4 : 1)
            .accessibilityLabel("\(title)：\(active ? "已就绪" : "点按准备")")
    }
    private var sidebarOverlay: some View {
        GeometryReader { geometry in
            if sidebarOpen {
                ZStack(alignment: .leading) {
                    Button { setSidebar(false) } label: { sidebarScrimColor.ignoresSafeArea() }
                    .buttonStyle(.plain).accessibilityLabel("关闭侧栏")
                    sidebar.frame(width: min(geometry.size.width * 0.77, 360), height: geometry.size.height)
                        .background(AgentPalette.background.ignoresSafeArea(.container, edges: .vertical))
                        .transition(reduceMotion ? .opacity : .move(edge: .leading))
                        .offset(x: reduceMotion ? 0 : sidebarDrag)
                        .gesture(DragGesture(minimumDistance: 12)
                            .updating($sidebarDrag) { value, state, _ in
                                if abs(value.translation.width) > abs(value.translation.height) { state = min(0, value.translation.width) }
                            }.onEnded { value in
                                if value.predictedEndTranslation.width < -80 { setSidebar(false) }
                            })
                }.transition(.opacity)
            }
        }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Phone Agent").font(.title2.weight(.semibold))
                Spacer()
                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22)) {
                        sidebarSearchExpanded.toggle()
                        if !sidebarSearchExpanded { searchText = "" }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .agentGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(AgentPressStyle())
                .accessibilityLabel(sidebarSearchExpanded ? "收起搜索" : "搜索历史任务")
            }
            .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 6)

            if sidebarSearchExpanded {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    TextField("搜索历史任务", text: $searchText,
                              prompt: Text("搜索历史任务").foregroundStyle(AgentPalette.placeholder))
                        .font(.subheadline)
                        .autocorrectionDisabled()
                        .accessibilityLabel("搜索任务历史")
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(.horizontal, 14).frame(height: 42)
                .agentGlass(in: Capsule(), interactive: true)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if tab == 0, let record = displayedRecord {
                        sidebarButton("任务详情与管理", icon: "checklist") { present(.task(record.id)) }
                    }
                    sidebarButton("任务队列", icon: "list.bullet", count: model.taskQueue.pendingCount) { navigate(7) }
                    sidebarButton("设备与校准", icon: "computermouse") { navigate(2) }
                    sidebarButton("屏幕共享", icon: "rectangle.on.rectangle") { navigate(1) }
                    sidebarButton("记忆与上下文", icon: "bookmark") { navigate(5) }
                    sidebarButton("记录与文件", icon: "doc.text") { navigate(6) }
                    sidebarButton("使用准备", icon: "checklist") { setSidebar(false); present(.preparation) }

                    if searchText.isEmpty {
                        Text("最近")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 4)
                    }

                    if !searchText.isEmpty || !model.history.records.isEmpty {
                        if filteredTasks.isEmpty {
                            Text("没有找到相关任务")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.vertical, 14)
                        } else if !searchText.isEmpty {
                            Text("搜索结果")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
                            ForEach(filteredTasks) { record in
                                sidebarTaskRow(record)
                            }
                        } else {
                            ForEach(groupedHistory, id: \.title) { group in
                                Text(group.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
                                ForEach(group.records) { record in
                                    sidebarTaskRow(record)
                                }
                            }
                        }
                    } else if searchText.isEmpty {
                        Text("任务会显示在这里")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }

                    if !model.history.error.isEmpty {
                        AgentNotice(text: model.history.error, error: true).padding(.horizontal, 14)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)

            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 16) {
                    Button {
                        if tab == 4 { setSidebar(false); newAssistantRequest = UUID() }
                        else { requestNewTask() }
                    } label: {
                        Label("新建", systemImage: "square.and.pencil")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 22).frame(minHeight: 40)
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                    .tint(AgentPalette.accent).foregroundStyle(.white)
                    .disabled(model.voiceMode != nil)
                    .accessibilityLabel("新建")
                    Spacer(minLength: 8)
                    Button { navigate(3) } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 23, weight: .medium))
                            .foregroundStyle(.primary).frame(width: 52, height: 52)
                            .agentGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(AgentPressStyle()).accessibilityLabel("Phone Agent 设置")
                }
            }
            .padding(.leading, 40).padding(.trailing, 30).padding(.top, 10).padding(.bottom, 12)
        }
    }
    private func sidebarTaskRow(_ record: PhoneTaskRecord) -> some View {
        Button { openConversation(record) } label: {
            HStack(spacing: 10) {
                Image(systemName: record.outcome == .completed ? "checkmark.circle" : "bubble.left")
                    .font(.system(size: 14))
                    .foregroundStyle(record.outcome == .completed ? Color.green.opacity(0.8) : AgentPalette.ink.opacity(0.4))

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    Text(record.outcome.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if screen == .conversation(record.id) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(screen == .conversation(record.id) ? AgentPalette.ink.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(AgentPressStyle())
    }
    private func sidebarButton(_ title: String, icon: String, count: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 22)
                Text(title).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                if count > 0 { Text(String(count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }.padding(.horizontal, 14).frame(minHeight: 50).contentShape(Rectangle())
        }.buttonStyle(AgentPressStyle())
    }
    private func setSidebar(_ open: Bool) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: open ? 0.28 : 0.20, bounce: 0)) { sidebarOpen = open }
    }
    private func openConversation(_ record: PhoneTaskRecord) {
        screen = .conversation(record.id); expandedSteps = false; followLatest = true
        navigate(0); composing = false
    }
    private func requestNewTask() {
        setSidebar(false)
        if screen == .draft && !model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { discardingDraft = true }
        else {
            if model.goal == displayedRecord?.goal { model.goal = ""; model.removeTaskPlan() }
            screen = .draft; model.notice = ""; navigate(0); composing = true
        }
    }
    private func resetDraft() {
        model.removeTaskPlan(); model.goal = ""; model.notice = ""; screen = .draft; navigate(0); composing = true
    }
    private func reuseTask(_ record: PhoneTaskRecord) {
        // Keep an existing unsent task intact; reuse opens only an editable draft.
        if !model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.goal != record.effectiveGoal {
            screen = .draft; model.notice = "输入框里还有未提交的任务，请先处理草稿。"
        } else { model.goal = record.effectiveGoal; screen = .draft }
        composing = true
    }
    private var capturePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AgentPageIntro(title: "共享手机画面", subtitle: "让助手看到当前屏幕。由你开启，随时结束。")
                HStack {
                    Circle().fill(model.capture.running ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                    Text(model.capture.state).font(.subheadline.weight(.medium))
                    Spacer()
                    if model.capture.running { Text("LIVE").font(.caption2.weight(.bold)).foregroundStyle(AgentPalette.accent) }
                }
                Group {
                    if let frame = model.capture.frame {
                        VStack(spacing: 12) {
                            Image(uiImage: frame.image).resizable().scaledToFit().frame(maxHeight: 390)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            HStack {
                                Text("\(frame.sourceWidth) × \(frame.sourceHeight)")
                                Spacer(); Text("\(model.capture.fps, specifier: "%.1f") FPS")
                            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(spacing: 18) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 27).stroke(AgentPalette.accent.opacity(0.20), lineWidth: 2).frame(width: 126, height: 220)
                                VStack(spacing: 14) {
                                    Image(systemName: "viewfinder").font(.system(size: 39, weight: .ultraLight)).foregroundStyle(AgentPalette.accent)
                                    Text("等待画面").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 17)
                            Text("通过系统选择器共享整屏").font(.subheadline.weight(.medium))
                            Text("切换到其他 App 后，助手仍能观察当前画面。")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity)
                    }
                }.agentPanel()
                if model.capture.running {
                    Button("停止屏幕共享", role: .destructive) { model.stop(); model.capture.stop() }.buttonStyle(AgentButtonStyle(primary: false))
                } else {
                    Button { model.capture.start() } label: { Label("共享整屏", systemImage: "rectangle.on.rectangle") }
                        .buttonStyle(AgentButtonStyle()).disabled(model.capture.waitingForPicker || busy)
                }
                if !model.capture.error.isEmpty { AgentNotice(text: model.capture.error, error: true) }
                Text("开始任务后，画面会发送到你配置的模型。停止任务不会结束共享；受保护的内容可能显示为空白。")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 3)
            }.padding(20)
        }
    }
    private var mousePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AgentPageIntro(title: "连接 AgentMouse", subtitle: "配件负责点击与输入，校准后开始操控。")
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 15) {
                        Image(systemName: "computermouse.fill").font(.system(size: 32)).foregroundStyle(AgentPalette.accent)
                            .frame(width: 68, height: 68).background(AgentPalette.accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 22))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AgentMouse").font(.title3.weight(.semibold))
                            Text(model.ble.state).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.ble.ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    if model.ble.connected {
                        if model.ble.ready {
                            Text(model.ble.bufferedMotionReady ? "鼠标移动已就绪" : "请升级配件固件")
                                .font(.caption).foregroundStyle(.secondary)
                            Label(model.ble.keyboardReady ? "蓝牙键盘已就绪" :
                                (model.ble.status?.keyboardSupported == true ? "等待系统连接键盘" : "配件尚未支持键盘"),
                                systemImage: "keyboard").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Label(model.ble.ready ? "鼠标已就绪" : "连接中", systemImage: "circle.fill").font(.caption)
                            Spacer()
                            Button("刷新") { model.ble.refresh() }
                            Button("断开", role: .destructive) { model.stop(); Task { await model.ble.release(); model.ble.disconnect() } }
                        }.font(.caption)
                    } else {
                        Button(model.ble.scanning ? "停止查找" : "连接 AgentMouse") {
                            if model.ble.scanning { model.ble.stopScan() } else { model.ble.scan() }
                        }.buttonStyle(AgentButtonStyle()).disabled(busy)
                        ForEach(model.ble.devices) { device in
                            Button { model.ble.connect(device) } label: {
                                HStack { Label(device.name, systemImage: "dot.radiowaves.left.and.right"); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                                    .font(.subheadline).frame(minHeight: 48)
                            }.disabled(busy)
                        }
                    }
                    if !model.ble.error.isEmpty { AgentNotice(text: model.ble.error, error: true) }
                }.padding(20).background(AgentPalette.inset, in: RoundedRectangle(cornerRadius: 18))
                if !model.ble.ready {
                    DisclosureGroup("连接帮助") { VStack(alignment: .leading, spacing: 14) {
                        AgentSectionTitle(title: "首次连接", subtitle: "系统配对与 App 连接分两步；首次完成后通常无需重复。")
                        connectionStep(1, "在 iOS 中配对", "设置 → 辅助功能（或“无障碍”）→ 触控 → 辅助触控 → 设备 → 蓝牙设备，选择 AgentMouse。系统询问时点“配对”。")
                        connectionStep(2, "回到 Phone Agent", "配对成功后返回此页，再点“连接 AgentMouse”。看到“鼠标已就绪”后再开始校准。")
                        connectionStep(3, "连接超时", "确认配件有电且 iPhone 蓝牙已开启；刚配对后可关闭再开启辅助触控，然后回此页重试。")
                        Link("查看 Apple 官方指针设备说明", destination: URL(string: "https://support.apple.com/zh-cn/111775")!)
                            .font(.footnote.weight(.medium))
                    }.padding(.top, 12) }.agentPanel()
                }
                VStack(alignment: .leading, spacing: 15) {
                    AgentSectionTitle(title: "把每一次点击对准", subtitle: "首次使用或更改指针速度后，校准一次。")
                    if let c = model.executor.calibration {
                        HStack {
                            Label(model.calibrationReady ? "当前配件已校准" : "需要校准当前配件", systemImage: "scope").foregroundStyle(AgentPalette.accent)
                        }.font(.footnote)
                        if model.calibrationReady { Text("最大误差 \(c.validationError, specifier: "%.1f") 点").font(.caption).foregroundStyle(.secondary) }
                    }
                    Button(model.calibrationReady ? "重新校准" : "开始校准") { beginCalibration() }.buttonStyle(AgentButtonStyle(primary: false)).disabled(!model.ble.ready || busy || model.executor.calibrationInProgress)
                    DisclosureGroup("校准前的准备") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("保持竖屏，在 21 步校准过程中不要触碰屏幕。")
                            Text("每次定位先回左上角，再斜向移动。建议关闭“吸附到项目”，并固定指针速度。")
                            if let c = model.executor.calibration, model.calibrationReady, let rms = c.validationRMS, let drift = c.returnDrift {
                                Text("最近校准：RMS \(rms, specifier: "%.1f") 点 · 往返漂移 \(drift, specifier: "%.1f") 点")
                            }
                        }.font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
                    }.font(.subheadline)
                }.padding(20).background(AgentPalette.inset, in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 13) {
                    DisclosureGroup("返回桌面：先验证辅助触控映射") {
                    VStack(alignment: .leading, spacing: 14) {
                    Toggle("我已验证中键可以回到主屏幕", isOn: Binding(
                        get: { model.settings.homeButtonIsMapped(to: model.ble.selectedID) },
                        set: { model.settings.homeMappedPeripheralID = $0 ? model.ble.selectedID : nil }
                    )).tint(.green).disabled(busy || model.ble.selectedID == nil)
                    Text("先在 iPhone 设置 → 辅助功能 → 触控 → 辅助触控 → 设备 → AgentMouse 中，把中键分配为“主屏幕”。手动按一次中键，确认确实回到桌面后，再开启上面的选项。每个配件需单独设置。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("未开启时，助手会尝试点击画面上可见的辅助触控按钮，再观察菜单并点“主屏幕”；看不到菜单按钮时会停下来请你显示，不会反复盲按。")
                        .font(.footnote).foregroundStyle(.secondary)
                    }.padding(.top, 14)
                    }.font(.subheadline)
                }.padding(20).background(AgentPalette.inset, in: RoundedRectangle(cornerRadius: 18))
                if !model.notice.isEmpty { AgentNotice(text: model.notice) }

            }.padding(20)
        }
    }
    private func beginCalibration() {
        let next = CalibrationModel(executor: model.executor)
        model.calibrating = true
        model.cancelCalibration = { [weak next] in next?.cancel() }
        next.onSaved = { model.objectWillChange.send() }
        calibration = next; showCalibration = true
    }
    private func connectionStep(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.caption.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 24, height: 24).background(AgentPalette.surface, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func pageHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }.padding(.top, 8).padding(.bottom, 3)
    }
}
