# 源码结构

## 执行循环

`CaptureService` 提供用户授权的画面，`VisionClient` 请求配置的模型，`AgentEngine` 管理观察、动作校验、暂停、停止与重试。动作由 `MouseExecutor` 转换为 `MouseProtocol` 数据包，通过 `BLETransport` 交给配件执行。执行后重新观察，避免继续使用旧画面。

固件通过自定义 BLE 服务接收命令，再用 HID 报告控制同一台 iPhone。手机系统 HID 与 CoreBluetooth 可以使用同一物理连接，固件最多允许两路连接。配对、加密、HID 订阅和控制通道分别有自己的就绪状态。

## 页面和状态

- `RootView`：模式切换、侧栏、任务会话、准备流程和导航。
- `AppModel`：组合各服务，协调任务、队列、语音和系统状态。
- `AssistantViews` / `AssistantConversation`：助手聊天与输入。
- `SettingsView`：模型、检索、执行、画中画、Siri、外观和隐私配置。
- `Shared`：模型回复验证、校准算法、协议和文件／工具数据类型。
- `Activity`：ActivityKit 实时活动与控制扩展。

源文件保留原项目相对路径，Xcode 工程和资源打包关系可直接复用。`Skills` 中的文档属于运行时资源，不是联网下载内容。

## 数据和密钥

`SettingsStore` 将模型密钥保存到 Keychain。任务、记忆、录音和文件由各自 Store 在本机管理；发送到模型或其他服务前由对应数据授权和工具确认流程控制。API 响应、捕获画面和用户数据不属于源码仓库内容。

更改模型动作需要同步 `Shared/AgentModels.swift`、执行器、固件协议及手机操控 Skill；不能只在提示词里增加尚未实现的动作。
