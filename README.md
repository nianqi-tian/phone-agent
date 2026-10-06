<div align="center">

<img src="docs/icon.png" alt="Phone Agent 应用图标" width="128" height="128">

# Phone Agent

**让 AI 看懂屏幕，操作你的 iPhone**

<p>
  <img src="https://img.shields.io/badge/iOS-27-000000?style=flat-square&logo=apple&logoColor=white" alt="iOS 27">
  <img src="https://img.shields.io/badge/SwiftUI-Liquid%20Glass-007AFF?style=flat-square&logo=swift&logoColor=white" alt="SwiftUI Liquid Glass">
  <img src="https://img.shields.io/badge/ESP32-S3-007AFF?style=flat-square" alt="ESP32-S3">
  <img src="https://img.shields.io/badge/build-67-007AFF?style=flat-square" alt="Build 67">
</p>

<a href="https://github.com/boboabw/phone-agent/archive/refs/heads/main.zip"><b>下载源码</b></a> ·
<a href="#使用要求">使用要求</a> ·
<a href="#安装与配置">安装与配置</a> ·
<a href="docs/firmware.md">固件烧录</a>

</div>

Phone Agent 是原生 iPhone AI 助手。通过你授权的屏幕共享理解当前画面，再用 ESP32-S3 蓝牙鼠标与键盘配件执行点击、移动和输入。

> [!NOTE]
> 当前提供开发版源码，需使用 Xcode 自行编译安装。手机操控需要 ESP32-S3 配件、指针校准、整屏共享和支持图像输入的模型。

## 功能

**操控手机** — 观察画面、生成动作、执行后再次观察。支持任务队列，以及暂停、停止、接管和补充任务。

**问助手** — 文字、听写、屏幕与相机提问，提供可独立配置的实时语音对话。

**资料与工具** — 联网检索、记忆、文件和录音管理，生成会议纪要、鱼骨图与表格。

**系统集成** — Siri 与快捷指令、实时活动和动作画中画。使用 SwiftUI Liquid Glass，支持浅色和深色外观。

**蓝牙配件** — 鼠标、ASCII 键盘和快捷键，21 步精细校准。GPIO48 RGB 显示连接与任务状态：蓝色未连接、白色空闲、彩虹执行、红色失败、绿色完成。

## 使用要求

- 运行 iOS 27 的 iPhone。
- ESP32-S3 开发板与数据 USB 线；默认固件配置为 4 MB Flash，RGB 使用 GPIO48 上的 WS2812。
- 支持图像输入的 OpenAI 兼容模型接口，以及自己的 API Key。
- 开启辅助触控，并完成配件配对、指针校准和屏幕共享。
- 编译 App 需要 Mac 和 Xcode 27；真机安装时为两个 Target 设置自己的签名 Team。
- 编译固件需要 ESP-IDF 5.5.4。

## 安装与配置

1. 克隆源码，用 Xcode 打开工程：

   ```sh
   git clone https://github.com/boboabw/phone-agent.git
   cd phone-agent
   open PhoneAgent.xcodeproj
   ```

2. 为 `PhoneAgent` 和 `PhoneAgentActivity` 两个 Target 选择自己的 Team，选择 iPhone 后编译运行。
3. 在已启用 ESP-IDF 的终端执行 `bash scripts/build-firmware.sh`，按[固件说明](docs/firmware.md)烧录 ESP32-S3。
4. 在 App 的“模型连接”中填写服务商、完整 HTTPS 接口地址、模型 ID 和 API Key，确认数据使用授权。
5. 在系统辅助触控中配对 `AgentMouse-S3`，回到 App 连接并完成 21 步校准。开启整屏共享后，输入任务开始执行。

完整步骤见[配置与运行](docs/setup.md)。

## 界面

<div align="center">

<img src="docs/images/sidebar-light.jpg" alt="Phone Agent 浅色侧栏" width="300">

</div>

## 数据与运行说明

API Key 保存在 iPhone 钥匙串中。任务、记忆、录音和文件保存在本机；共享画面、任务文字和相关上下文会按对应授权发送到你配置的模型服务。

语音、Siri、画中画、BLE 和跨 App 执行需要真机验证。后台运行受 iOS 调度限制，持续常驻语音唤醒尚未实现。当前编译与离线检查记录见[验证说明](docs/verification.md)。

## 开发文档

[源码结构](docs/architecture.md) · [固件与协议](docs/firmware.md) · [配置与运行](docs/setup.md) · [检查与构建记录](docs/verification.md)

## 参考

[GestaltEdit](https://github.com/frs0n/GestaltEdit) — Swift 项目组织与 README 布局参考。
