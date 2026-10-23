# 离线产品状态检查

在装有 Xcode 的 Mac 上按需运行：

```sh
bash Tests/ProductState/run.sh
```

脚本编译生产 `AgentEngine`、`TaskHistoryStore`、`PrivacyConsent` 和共享模型；仅将引擎的 UIKit 导入替换为 CoreGraphics，并使用离线 UIImage、捕获、模型和配件执行器。所有临时数据放在临时目录及独立测试偏好域。它不连接手机、蓝牙或模型接口，不安装 App，不消耗模型额度。

74 项现有检查覆盖授权及接收方变更、旧设置解码、历史保存/重命名/删除/数量上限/损坏恢复、重启后不恢复执行、暂停取消、释放期间禁止继续、继续时重新观察、人工接手和停止后旧回复不能产生动作，以及语音指令匹配、补充校验、旧计划取消、补充持久化和模型接收有效新目标。

这不检查新增系统工具的真实 OS 权限/提交、ActivityKit、相机、语音、记忆索引、文件生成兼容，也不检查 PhoneAgentViewModel、SwiftUI 弹层、Keychain、真实 VisionClient、真实截图变化、BLE/HID、后台执行或真机 UI。仓库整理时已通过 74 项检查；完整硬件链路仍需单独验证。
