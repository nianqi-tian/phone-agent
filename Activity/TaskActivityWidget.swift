import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents
import UIKit

@main
struct PhoneAgentActivityBundle: WidgetBundle {
    var body: some Widget { PhoneAgentActivityWidget() }
}
struct PhoneAgentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 14) {
              HStack(spacing: 16) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Phone Agent").font(.headline)
                    Text(context.isStale ? "状态暂未更新，打开 App 核对" : context.state.status).font(.subheadline).invalidatableContent()
                }
                Spacer()
                Text("\(context.state.step)").font(.title2.monospacedDigit()).accessibilityLabel("第 \(context.state.step) 步")
              }
              ActivityTaskButtons(attributes: context.attributes, state: context.state)
            }.padding(18).widgetURL(URL(string: "phoneagent://task"))
                .activityBackgroundTint(Color(uiColor: .systemBackground).opacity(0.95))
                .activitySystemActionForegroundColor(.primary).foregroundStyle(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("Phone Agent", systemImage: "sparkles").font(.headline) }
                DynamicIslandExpandedRegion(.trailing) { Text("第 \(context.state.step) 步").font(.subheadline.monospacedDigit()) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(context.isStale ? "状态暂未更新，打开 App 核对" : context.state.status).font(.subheadline).invalidatableContent()
                        ActivityTaskButtons(attributes: context.attributes, state: context.state)
                    }.padding(.top, 8)
                }
            } compactLeading: { Image(systemName: "sparkles").foregroundStyle(.blue) }
            compactTrailing: { Text("\(context.state.step)").monospacedDigit() }
            minimal: { Image(systemName: "sparkles").foregroundStyle(.blue) }
            .widgetURL(URL(string: "phoneagent://task")).keylineTint(.blue)
        }
    }
}

private struct ActivityTaskButtons: View {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState
    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(axis: false)
            controls(axis: true)
        }
    }
    @ViewBuilder private func controls(axis vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            if let session = state.controlSessionID {
                if state.canPause == true {
                    Button(intent: PauseActivityPhoneTaskIntent(taskID: attributes.taskID, sessionID: session)) {
                        Label("暂停", systemImage: "pause.fill")
                    }.accessibilityHint("暂停此任务并保留进度，系统可能要求认证设备")
                }
                if state.canStop == true {
                    Button(intent: StopActivityPhoneTaskIntent(taskID: attributes.taskID, sessionID: session)) {
                        Label("停止", systemImage: "stop.fill")
                    }.accessibilityHint("结束此任务，暂停队列并保留等待项，系统可能要求认证设备")
                }
            }
            Link(destination: URL(string: "phoneagent://task")!) {
                Label("打开 App", systemImage: "arrow.up.forward.app")
            }.accessibilityHint("回到 App 核对任务；打开不会自动继续")
        }.font(.subheadline.weight(.semibold)).buttonStyle(.bordered).tint(.primary)
    }
}
