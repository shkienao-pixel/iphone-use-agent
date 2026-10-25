# 独立微信 Agent Skill

2026-10-25。用于 iPhone 微信的已有联系人搜索、指定文字消息，以及从联系人资料/发现进入朋友圈，对指定动态点赞、评论。用户要求行为尽量原子化，因此导航、输入、核对、提交和结果核验均分开。

本目录保留独立 Swift 规则核心和离线验证。用户于本版要求收尾并与现有代码合并：微信技能指南已同步到根目录 Skills，通过既有 PhoneAppSkillCatalog / VisionClient 加载；独立规则核心和参考图分析器尚未接入 App 执行链。本模块没有安装进个人技能目录。

## 内容

- `Skills/wechat-assistant/SKILL.md`：可独立阅读的操作技能；必要约束自包含，维护细节按需引用。
- `Skills/wechat-assistant/references/`：七张图的 UI 学习、原子流程、运行合同和后续真机验收。
- `Sources/WeChatSkillCore/`：目标匹配、原子动作校验、提交闸口与本地账本；没有网络或设备执行器。
- `DraftPreparation`：仅准备搜索词、消息和顶层评论；单次票据、后缀续填、完整回读，和实际提交分别处理。
- `DraftCheckpointStorage`：可选磁盘检查点，保存原任务、回读与未知意图；新进程需用新证据恢复，不能复用旧输入权限。
- `RecoveredResultReader`：重新核对对象后只读核验已提交结果，新证据追加保存，不恢复发送权限。
- `Sources/DraftRecoveryProbe/`：固定 offline/fixture 的独立进程回放，用于验证磁盘恢复；没有真实输入实现。
- `Sources/ReferenceUIProbe/`：macOS 上用本机 Vision 只读处理原始参考图；报告页面锚点与未识别项，不保存私人 OCR 原文或产生设备动作。
- `Tests/WeChatSkillCoreTests/`：合成语义观察的行为测试，包括持久化失败与恢复反例。
- `verification/`：测试日志、来源清单与隔离检查；不包含私人截图。

边界检查区分独立包依赖、用户授权的技能指南合并与主工作区同期漂移。授权合并文件按哈希核对；其他工作区改动保留，不回滚。

## 运行离线验证

需要 Swift 6 工具链；不需要 Xcode 项目、API Key、网络、ESP32 或 iPhone。

```sh
python3 '/Users/sh/Documents/ChatGPT/Gui Agent/Experiments/wechat-skill-20261025/scripts/verify.py' --label review-001
```

每次使用新的 label，已有运行证据不会覆盖。入口运行完整 Swift 测试、独立进程磁盘恢复、技能格式和隔离检查，核对源码在验证期间没有变化；报告包含逐项真实测试结果。最新通过记录由 `verification/latest.json` 指向，v1 根目录记录只保留历史。

技能格式使用本机 skill-creator 的官方 `quick_validate.py`；缺少 PyYAML 时会报告失败，不自动安装。首版已将该验证依赖安装在模块自己的 `.build/skill-validation-python`，不属于 Swift 包依赖，也没有修改系统 Python。其他环境可用 `--skill-validator` 指定同一官方工具的位置。

单独调试可运行 `swift test --package-path <本目录>` 或 `python3 scripts/check_isolation.py`。长期范围和迭代方式见 [ROADMAP.md](ROADMAP.md)。

`Package.swift` 没有包依赖，平台声明为 macOS 13 / iOS 16；独立包验证在 macOS 上运行。主工程合并的无签名模拟器构建与资源加载检查记录在根目录 `output/wechat-skill-merge-20261025-v6/`；没有安装手机或证明真机支持。

参考图处理可在验证命令追加 `--reference-images <七张原始JPG所在目录>`。处理成功、页面识别覆盖率、模型遵循与真机验收分别记录；不将“七张均已处理”表述为“七页均已识别”。原始图不复制到工程内。

## 设计决策

1. 一个原子动作只做一个手势、一个字段输入或一次内容准备；核对是只读决策。没有 send-and-like 或循环点击宏。
2. 主工程能力由未来适配器提供，本模块只定义语义合同。不要复制截图、蓝牙、输入法、队列、上下文压缩或原生内容工具。
3. 资料账号与动态本地绑定分开；动态线索不是平台 ID。一个完整匹配不能盖过另一条未读候选。
4. 输入不隐藏回车提交，旧草稿不覆盖，消息/评论原文按 UTF-8 精确核对。
5. 点赞、消息、评论各有独立提交状态。提交前写账本，一次性票据只产生一个 tap；待核验不自动重发。
6. 归档不恢复执行权限，规则测试不冒充像素识别或真机验收。

Skill 正文已接入 Sela 的既有指南加载链路；规则核心仍独立。若以后将规则核心接到实时帧与输入，须显式实施并验证运行合同中的适配；现在没有假适配器或后台服务。

当前支持规则合同、离线原子提交链、草稿的显式检查点恢复、有充分语义证据时的提交结果只读恢复，以及部分参考页面的外观识别。旧记录缺少时间/起始标记会保留未知，图片型动态跨进程等价识别、实时 UI 适配、真实输入桥接、模型是否正确遵守 skill、完整 iPhone 流程仍需后续完成；用户已将真机测试安排到后面。本版收尾合并后，按用户指令暂停持续迭代。
