import SwiftUI

struct PreparationView: View {
    @EnvironmentObject private var model: AppModel
    let navigate: (Int) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("准备你的第一项任务").font(.title2.weight(.semibold))
                    Text(model.settings.toolsOnly == true ? "确认模型与数据授权，工具操作将逐项确认。" : "连接模型和配件，让助手了解你的屏幕。").font(.subheadline).foregroundStyle(.secondary)
                    step(1, "选择模型服务", detail: "使用你自己的 API Key，或配置可信的兼容接口。", done: model.modelReady) { navigate(3) }
                    if model.settings.toolsOnly != true {
                    step(2, "连接 AgentMouse", detail: "手机需要将配件识别为辅助触控鼠标。", done: model.ble.ready || model.settings.previewOnly) { navigate(2) }
                    step(3, "完成定位校准", detail: "当前配件校准通过后，助手才能准确点击。", done: model.calibrationReady || model.settings.previewOnly) { navigate(2) }
                    }
                    step(4, "确认 AI 数据使用", detail: "接收方：\(PrivacyConsent.recipient(model.settings))。任务会发送画面、任务文字与行动摘要。", done: model.consentReady) { model.requestConsent() }
                    if model.settings.toolsOnly != true { step(5, "开启整屏共享", detail: "在系统窗口中选择整屏；结束后可随时停止共享。", done: model.capture.running && model.capture.frame?.fullDisplay == true) { navigate(1) } }
                    if model.preparationReady {
                        Label("已准备就绪，回到任务页开始", systemImage: "checkmark.circle").font(.headline)
                    }
                    Text("需要 iOS 27。仅系统工具模式无需配件或共享；视觉执行需配件、校准和整屏共享，预览模式只生成计划。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationTitle("使用准备").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("返回任务") { navigate(0) } } }
        }.tint(AgentPalette.accent).agentSheetStyle()
    }
    private func step(_ number: Int, _ title: String, detail: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(AgentPalette.surface).frame(width: 36, height: 36)
                    if done { Image(systemName: "checkmark") } else { Text("\(number)").font(.subheadline.weight(.semibold)) }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0); Image(systemName: "chevron.right").foregroundStyle(.secondary).padding(.top, 10)
            }.frame(maxWidth: .infinity, alignment: .leading).agentPanel()
        }.buttonStyle(AgentPressStyle()).accessibilityLabel("第 \(number) 步，\(title)，\(done ? "已完成" : "待准备")")
    }
}

struct TaskDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var controlGlass
    @State private var showActions = false
    @State private var renaming = false
    @State private var title = ""
    @State private var deleting = false
    let id: UUID
    private var current: Bool { model.engine.currentRecord?.id == id }
    private var record: PhoneTaskRecord? { model.history.records.first { $0.id == id } ?? (current ? model.engine.currentRecord : nil) }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let record {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(record.title).font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                        Label(record.outcome.label, systemImage: record.outcome == .completed ? "checkmark.circle" : "circle.dotted")
                            .font(.subheadline).padding(.horizontal, 14).padding(.vertical, 10)
                            .agentGlass(in: Capsule())
                        Text(record.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        AgentCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("任务内容").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                Text(record.goal).font(.body).textSelection(.enabled)
                                ForEach(record.amendments ?? []) { addition in
                                    Divider()
                                    Text("补充 · \(addition.createdAt.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(addition.text).textSelection(.enabled)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(current && model.engine.running ? "正在进行" : "执行结果").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Text(current ? model.engine.state : record.summary).font(.title3.weight(.medium))
                            if current, let action = model.engine.pendingAction { Text(action.reason).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        if let subtasks = record.subtasks {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("子任务 · \(subtasks.filter(\.completed).count)/\(subtasks.count)").font(.headline)
                                ForEach(subtasks) { item in
                                    Label(item.goal, systemImage: item.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(item.completed ? Color.green : .secondary)
                                    if let evidence = item.evidence { Text(evidence).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.agentPanel()
                        }
                        if current, !model.engine.error.isEmpty { AgentNotice(text: model.engine.error, error: true) }
                        DisclosureGroup("行动记录 · \(record.logs.count) 条", isExpanded: $showActions) {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                ForEach(record.logs) { log in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text("\(log.step)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            .frame(width: 28, height: 28).background(AgentPalette.surface, in: Circle())
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack { Text(log.title).font(.subheadline.weight(.semibold)); Spacer(); Text(log.date, style: .time).font(.caption2).foregroundStyle(.tertiary) }
                                            Text(log.detail).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                                        }
                                    }.padding(.top, 10)
                                }
                            }
                        }.font(.subheadline)
                    }.padding(20)
                } else { Text("该任务已删除").padding(20) }
            }.navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline).scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if let record {
                    VStack(spacing: 12) {
                        if current && (model.engine.running || model.engine.canResume || model.engine.releasing) { controls }
                        else if !model.engine.running && !model.engine.releasing {
                            Button("用作新任务") {
                                if !model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.goal != record.effectiveGoal { model.notice = "输入框里还有未提交的任务，请先处理草稿。" }
                                else { model.goal = record.effectiveGoal }
                                dismiss()
                            }.buttonStyle(AgentButtonStyle())
                            if record.outcome != .completed { Text("新任务会从头规划；上次可能已部分完成，请先删去无需重做的要求。不会自动恢复旧执行。") .font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 12)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("重命名") { title = record?.title ?? ""; renaming = true }
                        Button("删除任务", role: .destructive) { deleting = true }.disabled(model.engine.running || model.engine.releasing)
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("任务选项")
                }
            }
            .alert("任务名称", isPresented: $renaming) {
                TextField("名称", text: $title)
                Button("保存") {
                    if current { model.engine.renameCurrent(title) }
                    else { model.history.rename(id, title: title) }
                }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("删除这个任务及其行动记录？", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除任务", role: .destructive) { model.removeTask(id); dismiss() }
            }
        }.tint(AgentPalette.accent).agentSheetStyle()
    }
    private var controls: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 12) {
                if model.engine.phase == .awaitingApproval {
                    Button(model.engine.pendingAction?.kind == .complete_subtask ? "确认这项已完成" : "执行这一步") { model.engine.approve() }.buttonStyle(AgentButtonStyle())
                        .glassEffectID("approve", in: controlGlass)
                }
                if model.engine.running {
                    HStack(spacing: 12) {
                        Button("暂停任务") { model.pauseTask() }.buttonStyle(AgentButtonStyle(primary: false))
                            .glassEffectID("continue", in: controlGlass)
                            .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                        Button("停止", role: .destructive) { model.stop() }.buttonStyle(AgentButtonStyle(primary: false))
                            .glassEffectID("stop", in: controlGlass)
                    }
                    Button("接管并补充") { model.beginVoice(.supplement) }.buttonStyle(AgentButtonStyle(primary: false))
                } else if model.engine.canResume {
                    Button("补充要求") { model.beginVoice(.supplement) }.buttonStyle(AgentButtonStyle(primary: false))
                    Button(model.engine.phase == .needsUser ? "我已处理，继续任务" : "继续任务") { model.resumeAgent() }.buttonStyle(AgentButtonStyle())
                        .glassEffectID("continue", in: controlGlass)
                        .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                    Button("结束任务", role: .destructive) { model.stop() }.buttonStyle(AgentButtonStyle(primary: false))
                        .glassEffectID("stop", in: controlGlass)
                } else if model.engine.releasing {
                    ProgressView("正在释放输入…").padding(16).frame(maxWidth: .infinity)
                        .agentGlass(in: RoundedRectangle(cornerRadius: 20))
                        .glassEffectID("continue", in: controlGlass)
                }
            }
        }.animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.32), value: model.engine.phase)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.32), value: model.engine.releasing)
    }
}
