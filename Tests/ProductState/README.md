# 离线产品状态检查

在装有 Xcode 的 Mac 上运行：

```sh
bash Tests/ProductState/run.sh
```

脚本编译生产 `AgentEngine`、`TaskHistoryStore`、`PrivacyConsent`、`FrameReadinessGate` 和共享模型；引擎仅将 UIKit 导入替换为 CoreGraphics，并使用离线 UIImage、捕获、模型和配件执行器。所有临时数据放在临时目录及独立测试偏好域，不连接手机、蓝牙或模型接口。

检查覆盖授权、接收方变更、旧设置解码、历史持久化、重启不恢复执行、暂停/继续/停止、停止后的旧回复、语音补充目标，以及长任务默认设置、113 次连续观察、2,000 步历史压缩与检查点恢复。实际检查数量由运行日志输出。

取屏唤醒检查复用 `WakeTimingChecks.swift`。每次等待根据生产 `.capture` span UUID 单独归属，验证至多一对 `+3/-3` 零按键移动；初始取屏和模型返回后校验不再靠累计移动次数区分。离线来源显式交付 complete/idle 证据，使用真实 `FrameReadinessGate`，读取画面不会刷新时间。覆盖初始零唤醒、换源/换像素/停止/静默、过期证据、模型返回门控和取消；保留生产 1.5 秒新鲜度、6 秒等待与停止保护。

每个场景在断言抛错前保存 JSON：实际移动、capture span、来源回调与像素/确认时间、模型调用、最终 phase/error、断言结果。通过环境变量指定产品检查的报告目录：

```sh
PHONE_AGENT_TIMING_REPORT_DIR=/tmp/phone-agent-timing bash Tests/ProductState/run.sh
```

只检查取屏时序：

```sh
bash Tests/WakeTiming/run.sh --report-dir /tmp/phone-agent-timing
bash Tests/WakeTiming/run.sh --stress --rounds 3 --report-dir /tmp/phone-agent-timing-stress
```

`--stress` 保留成功、早到证据、身份/像素变化、停止、慢模型和 1.7 秒消费延迟后有新 idle 恢复的场景，省略三个必须等待真实 6 秒超时的反例。完整入口仍运行全部场景。明确的 1.7 秒同步延迟仅存在于离线测试夹具，验证旧确认确实会过期；生产源码没有测试延迟或放宽阈值。

不检查真实系统权限/提交、ActivityKit、相机、语音、文件兼容、SwiftUI、Keychain、真实 VisionClient、BLE/HID、后台执行或真机 UI。离线检查和无签名编译不能替代真实手机验收。本轮缺陷及证据见 [时序检查修复](../../docs/timing-check-fix.md)。
