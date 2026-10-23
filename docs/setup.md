# 配置与运行

## 编译 iPhone App

1. 用 Xcode 27 打开仓库根目录的 `PhoneAgent.xcodeproj`，选择 `PhoneAgent` Scheme。
2. 真机运行时，在 App 和 `PhoneAgentActivity` 两个 Target 的 Signing & Capabilities 里选择自己的 Team。仓库未预填开发者 Team。
3. 默认 Bundle ID 为 `dev.agentmouse.controller` 和 `dev.agentmouse.controller.activity`。如需修改，保持扩展 ID 以 App ID 为前缀。
4. 选择 iOS 27 模拟器或解锁后的 iPhone，编译运行。模拟器不需要真机签名。

`PhoneAgent/Resources` 中的 Debug 与 Release 使用各自的 Info.plist；两者均保留项目所需的蓝牙、屏幕共享和音频后台声明。是否真的能后台运行仍由系统控制。

工程使用 Xcode 同步文件夹。新增 App 文件放入 `PhoneAgent/` 的对应子目录；跨 Target 数据类型放入 `Shared/`。详见 [源码结构](architecture.md)。

## 配置模型

从侧栏底部齿轮进入设置，再打开模型连接。填写服务商名称、完整 HTTPS 接口地址、模型 ID 和 API Key，保存后测试连接。自定义 OpenAI 兼容接口可直接使用，示例地址：`https://example.com/v1/chat/completions`。

操控手机、识屏和相机对话需要图像模型。语音、检索等功能使用自己的配置入口。首次使用及服务商变更后，App 会要求确认对应的数据接收方。

## 首次连接配件

1. 按 [固件说明](firmware.md) 编译并烧录 ESP32-S3 固件。
2. 在 iPhone 系统设置中开启辅助触控，通过辅助触控的设备页面配对 `AgentMouse-S3`。
3. 返回 App，打开侧栏“设备与校准”，连接配件，等待鼠标及控制通道就绪。
4. 运行 21 步精细校准，保持竖屏及固定指针跟踪速度。精确定位时建议关闭“吸附到项目”。
5. 开启屏幕共享并在系统选择器中选择整屏。受保护或禁止捕获的页面可能显示为空白。

仅显示 BLE 已连接不代表 HID 订阅、加密和控制通道已就绪。更换 HID 描述符或清理旧配对后，可能需要在手机上忘记设备并重新配对；具体诊断见设备页。

## 使用模式

顶部模式切换提供“操控手机”和“问助手”。当前冷启动默认进入操控手机。侧栏底部在两种模式均显示“新建”，创建当前模式的新任务或聊天。

执行任务前需要整屏共享、配件、校准、模型和数据授权就绪。倒计时期间切换到目标 App；执行过程中可暂停、停止、接管或补充。未完成实际动作时不应将模型生成的计划视为成功。

语音、Siri、后台捕获和动作画中画需要在真机验证。模拟器无法使用的功能会显示状态提示。新安装版本仍需要用户完成系统权限和配件准备。
