# 源码结构

## Swift 和 Xcode 组织

参考 [GestaltEdit](https://github.com/frs0n/GestaltEdit/tree/bca57fdd8858f5906952f4fe20b22486f3b87bf1) 的 App 入口、ContentView、ViewModel、模型与 Store 分工，以及 Xcode 同步文件夹。Phone Agent 功能更多，按职责增加子目录；项目继续使用 SwiftUI、Combine 和显式 `@MainActor` 隔离。

```text
PhoneAgent.xcodeproj/
PhoneAgent/
├── PhoneAgentApp.swift           # 依赖注入和 Scene 入口
├── ContentView.swift             # 导航、任务会话和输入区域
├── PhoneAgentViewModel.swift     # 服务组合和业务协调
├── Models/                      # 页面、弹层和会话事件类型
├── Views/                       # 独立页面与侧栏
├── Services/                    # BLE、捕获、模型、语音和执行
├── Stores/                      # 本机存储与 Keychain
├── Appearance/                  # 玻璃、主题、按钮和侧栏表面
├── Resources/                   # Assets、Info.plist、隐私和快捷指令
└── Debug/                       # 仅 Debug 编译的界面预览入口
Shared/                          # 协议、数据模型和跨 Target 类型
Activity/                        # 实时活动扩展
Skills/                          # App 打包的运行时规则
firmware/                        # ESP32-S3 固件
Tests/                           # 已有离线检查
scripts/
docs/
```

Xcode 使用 `PBXFileSystemSynchronizedRootGroup`，文件夹内容与工程导航自动同步，新增 Swift 文件无需手工维护逐文件引用。主 App 编译 `PhoneAgent` 和 `Shared`；实时活动扩展只编译 `Activity` 及 `Shared` 中的 `AgentActivityAttributes`、`AgentActivityControls`。两个 Target 的 Info.plist 均排除在自动资源复制之外。

`Skills` 仍作为文件夹资源显式打包，保留 App 中读取 `Skills/<名称>/SKILL.md` 的路径。固件、文档、脚本和检查文件不加入 App 编译。

## 页面和状态

- `PhoneAgentApp` 在 Scene 中持有 `@StateObject`，通过 `environmentObject` 提供 `PhoneAgentViewModel`；Siri 与 App 复用同一协调对象。
- `ContentView` 管理导航、弹层、任务会话和输入区域；页面选项使用 `WorkspaceDestination` 枚举，避免数字页码。
- `SidebarView` 接收当前页面、会话、搜索绑定和事件回调；历史筛选与分组留在侧栏内。
- `CaptureView`、`DeviceView`、`PreparationView` 分别负责共享、连接／校准入口和首次准备。
- `PhoneAgentViewModel` 组合服务并协调任务、队列、语音和系统状态；统一提供交互占用状态。
- `AssistantViews` / `AssistantConversation` 管理助手聊天；`SettingsView` 管理各项配置。
- `GitHubSettingsFooter` 放在设置总览最底部，提供作者头像、主页、仓库路径和 Star 页面入口；头像随 Assets 打包，设置页不会为显示它发起网络请求。Star 入口只打开仓库页面，由用户在 GitHub 上决定是否收藏。
- 持久数据用 `struct` / `enum` 表达，Store 负责本机读写；资源生命周期和共享可变状态由对应服务管理。

这次调整不改变持久化键、模型 JSON、BLE 协议、Bundle ID、用户界面文案或现有玻璃与动画参数。并发语言模式迁移与结构调整分开处理，继续保持原工程的 Swift 5 模式和显式主 actor 标注。

## 执行循环

`CaptureService` 提供用户授权的画面，`VisionClient` 请求配置的模型，`AgentEngine` 管理观察、动作校验、暂停、停止与重试。动作由 `MouseExecutor` 转换为 `MouseProtocol` 数据包，通过 `BLETransport` 交给配件执行。执行后重新观察，避免继续使用旧画面。

画面的 `capturedAt` 保存像素采集时间，`confirmedAt` 保存系统最近确认当前画面的时间。仅在收到同一个捕获流的完整帧或明确的 [idle 状态](https://developer.apple.com/documentation/screencapturekit/scframestatus/idle) 时更新确认时间；idle 表示内容未变化，复用当前流的最后一张完整图像。空白、暂停、未知状态和共享切换会清除可用画面。转换节流期间保留最后一个完整像素缓冲区，进入 idle 前先处理它，避免把较早的图像当作当前内容。流 ID 和事件序号拦截旧流或乱序回调。

模型返回和用户确认之后，执行器最多等待 6 秒取得最近 1.5 秒内被系统确认的整屏画面。拿到画面后核对捕获流、源尺寸、模型图像尺寸和图像差异；发生变化时丢弃旧动作并重新观察。共享停止会立即取消执行，短暂不可用期间不发送输入，持续不可用则保留任务供恢复。等待和恢复信息写入任务日志。本地时间流逝不会延长任何图像的有效期。

固件通过自定义 BLE 服务接收命令，再用 HID 报告控制同一台 iPhone。配对、加密、HID 订阅和控制通道分别有自己的就绪状态。

## 实时活动外观

锁屏卡片在 `Activity/TaskActivityWidget.swift` 的 `LockScreenTaskActivity` 中组织。背景通过系统的 `activityBackgroundTint` 设置为半透明浅灰或深灰，背景和文字都从同一 SwiftUI `colorScheme` 环境取色，避免 UIKit 动态颜色与锁屏环境分别解析。降低透明度时使用实色背景；息屏低亮度状态使用深色实底和浅色文字。灵动岛继续使用系统背景，任务控制权限与按钮行为不变。

## 数据和密钥

`SettingsStore` 将模型密钥保存到 Keychain。任务、记忆、录音和文件由各自 Store 在本机管理；发送到模型或其他服务前，由对应数据授权和工具确认流程控制。API 响应、捕获画面和用户数据不属于源码仓库内容。

更改模型动作需要同步 `Shared/AgentModels.swift`、执行器、固件协议及手机操控 Skill。
