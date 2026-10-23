# iPhone Use Agent — 当前工作版本

本仓库保存 2026-10-23 已在真机验证的工作版本，基于 [boboabw/phone-agent](https://github.com/boboabw/phone-agent) 源码提交 `a90045074afcd4de69f885fba25b0b171d690f45`。原项目的代码、资源与原有说明保留；当前改动及验证边界见 [版本说明](docs/version-2026-10-23.md)。

本版增加本地手机操作 Harness、已验证布局复用、结束画面复用、页面转换等待和模型历史过滤，并保留静态取屏唤醒、停止后完成记录保护等修复。日常任务由 iPhone App 调用模型，通过 ESP32-S3 蓝牙鼠标/键盘执行；Mac 用于开发、安装与签名更新。ESP32 需要供电，不需要通过 USB 与手机交换控制数据。

- 打开 `PhoneAgent.xcodeproj`，选择自己的签名 Team，并将示例 Bundle ID 改为个人唯一标识。仓库不包含个人签名配置或 API Key。
- 通用 ESP32-S3 与实测 XIAO ESP32-S3 配置见 [固件说明](docs/firmware.md)。
- 完整离线检查：`bash scripts/check.sh`；测试不要求真实聊天记录、API Key、手机或开发板。
- 本地 Harness 的能力、回退与验证边界见 [Harness 说明](docs/phone-harness.md)。

以下保留原项目的功能与安装说明。

---

<div align="center">

<img src="docs/icon.png" alt="Phone Agent app icon" width="128" height="128">

# Phone Agent

**An AI assistant that sees your screen and operates your iPhone**

<p>
  <img src="https://img.shields.io/badge/iOS-27-000000?style=flat-square&logo=apple&logoColor=white" alt="iOS 27">
  <img src="https://img.shields.io/badge/SwiftUI-Liquid%20Glass-007AFF?style=flat-square&logo=swift&logoColor=white" alt="SwiftUI Liquid Glass">
  <img src="https://img.shields.io/badge/ESP32-S3-007AFF?style=flat-square" alt="ESP32-S3">
  <img src="https://img.shields.io/badge/build-70-007AFF?style=flat-square" alt="Build 70">
</p>

<a href="https://github.com/shkienao-pixel/iphone-use-agent/archive/refs/heads/main.zip"><b>Download Source</b></a> ·
<a href="#demo">Demo</a> ·
<a href="#requirements">Requirements</a> ·
<a href="#install">Install</a> ·
<a href="docs/firmware.md">Flash Firmware</a>

</div>

Phone Agent is a native iPhone AI assistant. It understands the screen you choose to share, then uses an ESP32-S3 Bluetooth mouse and keyboard accessory to move, click, and type.

> [!NOTE]
> This project currently provides development source code. Build and install the app with Xcode. Phone control requires an ESP32-S3 accessory, pointer calibration, full screen sharing, and a model that accepts images.

## Demo

Ask Phone Agent to open Meituan and find a Mixue lemon drink. These GIFs show each stage of the same iPhone recording at its original speed, with the action window visible during execution.

[Watch the full demo (MP4)](docs/demo/full-demo.mp4)

<table>
  <tr>
    <td align="center"><strong>1. Start a task</strong><br><br><img src="docs/demo/01-start-task.gif" alt="Phone Agent begins a natural language task after a countdown" width="240"><br><sub>Describe what you want to do.</sub></td>
    <td align="center"><strong>2. Open AssistiveTouch</strong><br><br><img src="docs/demo/02-open-assistivetouch.gif" alt="The pointer opens the AssistiveTouch menu" width="240"><br><sub>Open the system navigation menu.</sub></td>
  </tr>
  <tr>
    <td align="center"><strong>3. Return Home</strong><br><br><img src="docs/demo/03-return-home.gif" alt="Phone Agent uses AssistiveTouch to return to the iPhone Home Screen" width="240"><br><sub>Return to the Home Screen.</sub></td>
    <td align="center"><strong>4. Open Meituan</strong><br><br><img src="docs/demo/04-open-meituan.gif" alt="The pointer selects Meituan and opens the app" width="240"><br><sub>Find and launch the target app.</sub></td>
  </tr>
  <tr>
    <td align="center"><strong>5. Find drink deals</strong><br><br><img src="docs/demo/05-find-drink-deals.gif" alt="Phone Agent opens the drink promotion listing in Meituan" width="240"><br><sub>Navigate to the relevant offers.</sub></td>
    <td align="center"><strong>6. Inspect the results</strong><br><br><img src="docs/demo/06-inspect-results.gif" alt="Phone Agent observes the available drink offers" width="240"><br><sub>Observe the screen before the next action.</sub></td>
  </tr>
  <tr>
    <td align="center"><strong>7. Select the lemon drink</strong><br><br><img src="docs/demo/07-select-lemon-drink.gif" alt="The pointer selects the lemon drink offer and opens order review" width="240"><br><sub>Open the matching offer.</sub></td>
    <td align="center"><strong>8. Review the order</strong><br><br><img src="docs/demo/08-review-order.gif" alt="The order review page displays the selected lemon drink" width="240"><br><sub>View the item and price before payment.</sub></td>
  </tr>
</table>

The recording ends at order review, before payment. Location and account balance are blurred; the published clips are silent.

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
   git clone https://github.com/shkienao-pixel/iphone-use-agent.git
   cd iphone-use-agent
   open PhoneAgent.xcodeproj
   ```

2. Select your signing team for the `PhoneAgent` and `PhoneAgentActivity` targets. Choose your iPhone, then build and run.
3. In a terminal with ESP-IDF activated, run `bash scripts/build-firmware.sh`. Follow the [firmware guide](docs/firmware.md) to flash the ESP32-S3.
4. In the app's model connection settings, enter your provider name, complete HTTPS endpoint URL, model ID, and API key. Confirm the data sharing consent.
5. Pair `AgentMouse-S3` in the system AssistiveTouch settings. Connect in the app and complete pointer calibration. Start full screen sharing, enter a task, and begin execution.

See [Setup and Usage](docs/setup.md) for detailed instructions.

## Project Structure

[GestaltEdit](https://github.com/frs0n/GestaltEdit) served as a reference for Swift source organization and README layout.

The Swift app separates its entry point, interface, coordination, services, and local storage. Shared models and the Live Activity extension live alongside the app; ESP32-S3 firmware has its own ESP-IDF project.

```text
phone-agent/
├── PhoneAgent.xcodeproj/          # App and Live Activity targets
├── PhoneAgent/
│   ├── PhoneAgentApp.swift        # App entry point and shared state
│   ├── ContentView.swift         # Main workspace and navigation
│   ├── PhoneAgentViewModel.swift # Task and interaction coordination
│   ├── Models/                   # Workspace and navigation types
│   ├── Views/                    # SwiftUI screens and components
│   ├── Services/                 # Capture, AI, BLE, voice, and tools
│   ├── Stores/                   # Settings and local persistence
│   ├── Appearance/               # Theme, glass surfaces, and motion
│   ├── Resources/                # Assets, strings, and privacy metadata
│   └── Debug/                    # Development review screens
├── Shared/                       # Data models and accessory protocol
├── Activity/                     # Live Activity and Dynamic Island UI
├── Skills/                       # Bundled phone control instructions
├── firmware/                     # ESP32-S3 BLE HID and GPIO48 RGB
├── scripts/                      # Firmware build and check entry points
├── Tests/                        # Existing offline checks
└── docs/                         # Setup, architecture, and build records
```

### Module Responsibilities

| Area | Responsibility |
| --- | --- |
| App and coordination | `PhoneAgentApp` creates shared state. `ContentView` presents the workspace. `PhoneAgentViewModel` connects user input, task execution, queue state, and services. |
| Views and appearance | SwiftUI pages present state and route user actions to the coordinator or services. `Appearance` centralizes light and dark themes, glass surfaces, and transitions. |
| Phone control | `AgentEngine` coordinates `CaptureService`, `VisionClient`, and `MouseExecutor`. `BLETransport` sends mouse and keyboard commands to the ESP32-S3. |
| Conversations and tools | Services handle assistant conversations, voice, camera input, web research, system actions, and file processing. Corresponding views provide their interfaces. |
| Local storage | Stores manage settings, task history and queues, memory, recordings, and service preferences. API credentials use the Keychain. |
| Shared types | `Shared` defines action, protocol, and feature data models. Live Activity attributes and controls are also compiled into the extension. |
| System surfaces | `Activity` renders Live Activities and Dynamic Island content. App services manage Activity updates, Picture in Picture, Siri, and Shortcuts. |
| Control instructions | `Skills` contains bundled instructions loaded by `PhoneControlSkill` for the visual phone control loop. |
| Accessory firmware | `firmware/main` implements BLE services, HID reports, command execution, and RGB status feedback for the ESP32-S3. |

### Where to Make Changes

- Add or update a screen in `PhoneAgent/Views`; use `Appearance` for shared styling.
- Add service behavior in `PhoneAgent/Services`, persistent state in `Stores`, and reusable data types in `Shared`.
- Update phone control rules in `Skills` and accessory commands in `Shared/MouseProtocol.swift` together with the firmware.
- Keep extension UI in `Activity`; shared extension types belong in `Shared` with the appropriate target membership.

Xcode uses synchronized source folders. Swift files inside those folders are included automatically, subject to target membership exceptions. `Skills` is explicitly bundled as a folder resource. See [Architecture](docs/architecture.md) for the execution flow and detailed component boundaries.

## Data and Runtime

API keys are stored in the iPhone Keychain. Tasks, memory, recordings, and files are stored locally. Shared screen images, task text, and relevant context are sent to your configured model service after the required consent.

Voice, Siri, Picture in Picture, BLE, and execution across apps require verification on an actual iPhone. Background execution is subject to iOS scheduling. Continuous listening for a wake word is not implemented. See [Verification](docs/verification.md) for build and offline check records.

## Development Docs

[Architecture](docs/architecture.md) · [Firmware and Protocol](docs/firmware.md) · [Setup and Usage](docs/setup.md) · [Checks and Build Records](docs/verification.md)
