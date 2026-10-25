# 独立微信 Agent Skill

2026-10-25。用于 iPhone 微信的已有联系人搜索、指定文字消息，以及从联系人资料/发现进入朋友圈，对指定动态点赞、评论。用户要求行为尽量原子化，因此导航、输入、核对、提交和结果核验均分开。

本目录是独立开发模块，没有修改主工程或安装进个人技能目录，也未加入 App 编译、资源、skill 加载器、模型路由、默认测试或设备执行链。根目录 Skills 会被 App 打包，因此本技能特意放在 Experiments 内。

## 内容

- `Skills/wechat-assistant/SKILL.md`：可独立阅读的操作技能；必要约束自包含，维护细节按需引用。
- `Skills/wechat-assistant/references/`：七张图的 UI 学习、原子流程、运行合同和后续真机验收。
- `Sources/WeChatSkillCore/`：目标匹配、原子动作校验、提交闸口与本地账本；没有网络或设备执行器。
- `Tests/WeChatSkillCoreTests/`：合成语义观察的行为测试，包括持久化失败与恢复反例。
- `verification/`：测试日志、来源清单与隔离检查；不包含私人截图。

隔离检查分别报告模块依赖边界与主工作区同期漂移。主工作区存在其他改动时不会回滚，也不把“模块无接入引用”误报成“整个工作区未变”。

## 运行离线验证

需要 Swift 6 工具链；不需要 Xcode 项目、API Key、网络、ESP32 或 iPhone。

```sh
swift test --package-path '/Users/sh/Documents/ChatGPT/Gui Agent/Experiments/wechat-skill-20261025'
python3 '/Users/sh/Documents/ChatGPT/Gui Agent/Experiments/wechat-skill-20261025/scripts/check_isolation.py'
```

`Package.swift` 没有包依赖，平台声明为 macOS 13 / iOS 16；本轮只验证 macOS 上的独立包。未编译/安装 iOS App，也未证明手机支持。

## 设计决策

1. 一个原子动作只做一个手势、一个字段输入或一次内容准备；核对是只读决策。没有 send-and-like 或循环点击宏。
2. 主工程能力由未来适配器提供，本模块只定义语义合同。不要复制截图、蓝牙、输入法、队列、上下文压缩或原生内容工具。
3. 资料账号与动态本地绑定分开；动态线索不是平台 ID。一个完整匹配不能盖过另一条未读候选。
4. 输入不隐藏回车提交，旧草稿不覆盖，消息/评论原文按 UTF-8 精确核对。
5. 点赞、消息、评论各有独立提交状态。提交前写账本，一次性票据只产生一个 tap；待核验不自动重发。
6. 归档不恢复执行权限，规则测试不冒充像素识别或真机验收。

Skill 正文与规则核心可以分别使用。若以后接 Sela，必须显式实施并验证运行合同中的适配；现在没有假适配器或后台服务。

当前支持的是规则合同和离线原子提交链。UI 识别、真实输入桥接、模型是否正确遵守 skill、完整 iPhone 流程仍需后续完成；用户已将真机测试安排到后面。
