import SwiftUI
import AppIntents

@main
struct PhoneAgentApp: App {
    @StateObject private var model = AppModel.shared
    init() { PhoneAgentShortcuts.updateAppShortcutParameters() }
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--ui-page"), ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
                    PhoneAgentReviewPage(name: ProcessInfo.processInfo.arguments[index + 1])
                } else { RootView() }
                #else
                RootView()
                #endif
            }.environmentObject(model).agentTheme()
        }
    }
}

#if DEBUG
// Visual-only launch routes. Never start hardware, permissions, or network work.
private struct PhoneAgentReviewPage: View {
    let name: String
    @EnvironmentObject private var model: AppModel
    private var recording: LocalRecording {
        model.recordings.records.first ?? .init(id: UUID(), title: "产品讨论", createdAt: Date(), updatedAt: Date(), duration: 180, interrupted: false)
    }
    private var meeting: MeetingEditorSeed {
        let source = "周五完成首页设计。下周评审交互流程。"
        var notes = MeetingNotes.empty(title: "产品讨论")
        notes.summary = .init(text: "完成首页设计并准备交互评审。", quote: source)
        notes.points = [.init(text: "周五完成首页设计", quote: "周五完成首页设计。")]
        notes.actions = [.init(text: "评审交互流程", quote: "下周评审交互流程。", owner: nil, due: "下周")]
        return .init(source: source, sourceName: "会议记录", notes: notes)
    }
    var body: some View {
        page.tint(AgentPalette.accent).background(AgentPalette.background)
    }
    @ViewBuilder private var page: some View {
        switch name {
        case "settings": SettingsView(onBack: {})
        case "task": TaskDetailView(id: model.history.records.first?.id ?? UUID())
        case "conversation": RootView(reviewConversation: model.history.records.first?.id)
        case "device": RootView(reviewTab: 2)
        case "share": RootView(reviewTab: 1)
        case "assistant": RootView(reviewTab: 4)
        case "memory": RootView(reviewTab: 5)
        case "workbench": RootView(reviewTab: 6)
        case "queue": RootView(reviewTab: 7)
        case "voice", "voice-listening": RootView(reviewVoice: .listening)
        case "voice-preparing": RootView(reviewVoice: .preparing)
        case "voice-finalizing": RootView(reviewVoice: .finalizing)
        case "voice-error": RootView(reviewVoice: .idle, reviewVoiceError: "语音识别中断，已保留识别文字")
        case "assistant-voice": RootView(reviewTab: 4, reviewVoice: .listening)
        case "memory-editor": MemoryEditor(seed: .init(value: .init(title: "我的偏好", text: "请优先使用简短、清晰的中文回复。")))
        case "realtime": RealtimeView()
        case "recordings": RecordingsView(store: model.recordings) { _ in }
        case "speaker": SpeakerView(record: recording, store: model.recordings) { _ in }
        case "meeting": MeetingNotesView(seed: meeting, onApply: { _ in }, onRetainDraft: { _ in })
        case "spreadsheet": SpreadsheetView(seed: .init(title: "计划", text: "项目\t状态\n首页设计\t已完成\n交互评审\t待进行"))
        case "search": WebSearchView()
        case "search-settings": NavigationStack { WebSearchSettingsView().navigationTitle("搜索服务").navigationBarTitleDisplayMode(.inline) }
        case "research": WebInvestigationView(initialQuestion: "")
        case "webpage": WebPageView(source: .init(id: 1, title: "阅读来源", url: URL(string: "https://example.com/article")!, excerpt: "", publishedLabel: nil, excerptShortened: false), onUse: { _ in })
        case "plan": TaskPlanView()
        case "preparation": PreparationView(navigate: { _ in })
        case "policy": DataPolicyView()
        case "consent": DataConsentView(onDecision: {})
        case "tool": ToolApprovalView(approval: .init(request: .init(operation: .reminder_create, title: "周五核对设计稿", notes: "确认界面和交互")))
        case "calibration": CalibrationView(model: .init(executor: model.executor))
        default:
            if name.hasPrefix("settings-") { SettingsView(reviewPage: String(name.dropFirst(9)), onBack: {}) }
            else { RootView() }
        }
    }
}
#endif
