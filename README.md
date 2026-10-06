<div align="center">

<img src="docs/icon.png" alt="Phone Agent app icon" width="128" height="128">

# Phone Agent

**An AI assistant that sees your screen and operates your iPhone**

<p>
  <img src="https://img.shields.io/badge/iOS-27-000000?style=flat-square&logo=apple&logoColor=white" alt="iOS 27">
  <img src="https://img.shields.io/badge/SwiftUI-Liquid%20Glass-007AFF?style=flat-square&logo=swift&logoColor=white" alt="SwiftUI Liquid Glass">
  <img src="https://img.shields.io/badge/ESP32-S3-007AFF?style=flat-square" alt="ESP32-S3">
  <img src="https://img.shields.io/badge/build-67-007AFF?style=flat-square" alt="Build 67">
</p>

<a href="https://github.com/boboabw/phone-agent/archive/refs/heads/main.zip"><b>Download Source</b></a> ·
<a href="#requirements">Requirements</a> ·
<a href="#install">Install</a> ·
<a href="docs/firmware.md">Flash Firmware</a>

</div>

Phone Agent is a native iPhone AI assistant. It understands the screen you choose to share, then uses an ESP32-S3 Bluetooth mouse and keyboard accessory to move, click, and type.

> [!NOTE]
> This project currently provides development source code. Build and install the app with Xcode. Phone control requires an ESP32-S3 accessory, pointer calibration, full screen sharing, and a model that accepts images.

## Features

**Phone control** — Observe the screen, generate an action, execute it, and observe the result. Queue tasks, pause or stop execution, take over manually, and add instructions during a task.

**Conversations** — Chat using text, dictation, shared screen images, or the camera. A separate configuration is available for real-time voice conversations.

**Files and tools** — Web search, memory, file and recording management, meeting notes, fishbone diagrams, and spreadsheets.

**System integration** — Siri and Shortcuts, Live Activities, and an action status window using Picture in Picture. Built with SwiftUI Liquid Glass, with light and dark appearances.

**Bluetooth accessory** — Mouse input, an ASCII keyboard, shortcuts, and pointer calibration in 21 steps. The GPIO48 RGB LED shows connection and task status: blue when disconnected, white when idle, rainbow during execution, red on failure, and green on completion.

## Requirements

- An iPhone running iOS 27.
- An ESP32-S3 development board and a USB data cable. The default firmware configuration uses 4 MB flash and a WS2812 RGB LED on GPIO48.
- An OpenAI-compatible model endpoint that accepts images, and your own API key.
- AssistiveTouch enabled, with accessory pairing, pointer calibration, and screen sharing completed.
- A Mac and Xcode 27 to build the app. Select your signing team for both targets when installing on an iPhone.
- ESP-IDF 5.5.4 to build the firmware.

## Install

1. Clone the repository and open the Xcode project:

   ```sh
   git clone https://github.com/boboabw/phone-agent.git
   cd phone-agent
   open PhoneAgent.xcodeproj
   ```

2. Select your signing team for the `PhoneAgent` and `PhoneAgentActivity` targets. Choose your iPhone, then build and run.
3. In a terminal with ESP-IDF activated, run `bash scripts/build-firmware.sh`. Follow the [firmware guide](docs/firmware.md) to flash the ESP32-S3.
4. In the app's model connection settings, enter your provider name, complete HTTPS endpoint URL, model ID, and API key. Confirm the data sharing consent.
5. Pair `AgentMouse-S3` in the system AssistiveTouch settings. Connect in the app and complete pointer calibration. Start full screen sharing, enter a task, and begin execution.

See [Setup and Usage](docs/setup.md) for detailed instructions.

## Data and Runtime

API keys are stored in the iPhone Keychain. Tasks, memory, recordings, and files are stored locally. Shared screen images, task text, and relevant context are sent to your configured model service after the required consent.

Voice, Siri, Picture in Picture, BLE, and execution across apps require verification on an actual iPhone. Background execution is subject to iOS scheduling. Continuous listening for a wake word is not implemented. See [Verification](docs/verification.md) for build and offline check records.

## Development Docs

[Architecture](docs/architecture.md) · [Firmware and Protocol](docs/firmware.md) · [Setup and Usage](docs/setup.md) · [Checks and Build Records](docs/verification.md)

## Reference

[GestaltEdit](https://github.com/frs0n/GestaltEdit) — reference for the Swift project organization and README layout.
