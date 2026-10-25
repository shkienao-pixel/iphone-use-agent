# Sela iPhone 连接入口（独立评审版本）

目标产品是 iOS / iPhone。Catalyst 只用于在 Mac 上直接点击评审同一套 SwiftUI 页面，不是另一个桌面产品。正式项目与手机部署保持原样，等待 UI 评审后统一同步。

## 接入方式

- 飞书、钉钉、企业微信：原生页面展示官方品牌图标，支持真实授权、授权进度、状态检测、取消和断开。CLI 在连接服务运行，iPhone 使用 HTTPS 调用配对后的服务，不安装命令行程序或保存应用 App Secret。`connection-bridge/server.py` 是本机评审用的适配器，仅监听回环地址；上手机前还需要把适配器部署为可访问的 HTTPS 服务。
- 携程：获取授权码、iOS Keychain 保存、启用授权。支持当前问道接口和原有接口，切换或替换凭据会要求重新启用。
- 美团：官方 AI Hub 获取具体服务的 MCP 地址与凭据，iOS Keychain 保存，通过 Streamable HTTP 握手和 tools/list 检测开放能力。未将连接检测当作下单、支付或授权所有消费业务的证明。
- 联网检索：已从设置移到「模型与记忆」，保留原有配置功能。

## 手机授权返回流程

手机使用 `UIApplication.open(... universalLinksOnly: true)` 尝试打开当前官方授权链接；系统未能用对应 App 处理时，回退到 `ASWebAuthenticationSession`。不拼接未公开的第三方 URL Scheme，也不把跳到 App 首页当作授权。

授权由 App 级 `OfficeAuthorizationFlow` 持有，离开详情页仍保留进度。系统授权页显示期间继续检查服务端任务；任务完成后再次查询账号状态，确认 `connected` 才收起授权页并显示已连接。外部 App 授权后再次打开 Sela，会立即续查；关闭网页、取消、超时与失败不会伪造连接成功。

已注册 `sela-auth://callback` 回调入口，校验当前服务、任务 ID、随机 state 和有效期。回调仅触发重新验证，不接收 URL 中的“成功”结果或令牌。只有任务与 state 等非密钥元数据写入恢复记录；过期或更换连接服务后失效。

企业微信二维码优先在本机解码为官方 HTTPS 地址，再走相同的 App／网页流程；无有效官方链接时保留二维码供扫码。未验证企微“从相册识别”在单手机上的可用性。

当前三家移动应用均未注册，用户已明确选择先完善现有 CLI 授权。**Universal Link 尝试不等于三家原生 SDK 直跳已经接入**；现有 CLI 的设备授权页也不保证主动跳回 Sela。原生 SDK 登录还需要注册信息、平台允许的回调和服务端授权衔接。此版本实现的是官方链接优先、系统网页后备、网页内完成后自动收起，以及外部 App 返回时续查。

验证：`connection-tests/authorization.swift` 对真实流程类进行离线测试，包括 App 优先、网页后备、官方 QR 解码、回调防伪、服务端验证、网页关闭、取消、前后台和重新启动恢复。iOS 模拟器与 Catalyst 均独立编译。未将这些检查当作真实账户在 iPhone 完成授权的证明。

## 预览与手机的区别

本机配对信息通过仅当前用户可读的文件加载。由于临时签名的 Catalyst 包没有正式 iOS Keychain 权限，预览的本机配对码只放内存；这个分支在 iPhone 上不会编译。服务商密钥仍走系统 Keychain，没有改成普通文件存储。临时 Mac 包尚不能据此认定携程／美团的凭据保存已通过；iPhone 端需独立验证。

Mac 专用的窗口定位、配对引导、平台适配和调试启动代码不能合并进正式 iOS 改动。

## 官方依据

- 飞书 CLI：https://github.com/larksuite/cli
- 钉钉 CLI：https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli
- 企业微信 CLI：https://github.com/WecomTeam/wecom-cli
- 携程问道：https://github.com/trips-ai/tripai-skill
- 美团 AI Hub：https://developer.meituan.com/ai-hub/mcp-list
- MCP Streamable HTTP：https://modelcontextprotocol.io/specification/2025-11-25/basic/transports

授权状态和验证记录见 `external-connections-verification.json`。账户授权需要用户在官方页面完成，连接状态不使用模拟成功值。

## iPhone 原生服务

App 连接页新增日历、通讯录、健康、Apple Music、照片、提醒事项和位置。使用系统框架读取权限状态，在详情页主动申请，系统设置返回后刷新。未允许、受限制、部分授权、日历仅添加分别显示，不把它们统称为完整连接。

日历、通讯录、照片、提醒事项接入 SystemTools 的系统授权和任务确认。联系人使用系统名称查询并在后台读取，修复模拟器枚举查询返回数据库错误的问题。照片查询仍是指定时段的元数据，不包含图像识别。

新增可由 Agent 调用的 `health_query`、`music_search`、`music_play`、`music_pause`、`music_resume`、`music_status`、`location_current`。所有操作先经过 SystemTools 用户确认，再执行真实系统框架，结果回到任务执行器。授权完成后自动开启系统工具，Agent 按任务调用获准的数据。

健康查询包含指定时段步数、去除重叠的睡眠时长和最多 20 条运动记录。范围限制 31 天，空结果保持未知，不伪造零值。音乐搜索使用 MediaPlayer 资料库，播放必须携带实际搜索结果的完整编号和匹配标题，仅控制 Sela 的队列；返回实际播放状态而非把命令下发当成功。在线曲库、购买订阅、其他 App 的队列控制不在本次实现中。位置通过 CoreLocation 单次获取，最多等待 30 秒，返回约至百米的坐标、时间和系统误差；取消时停止定位，不提供后台追踪。

健康仅申请所选类型的读取权限，没有写入和后台投递；iOS 的 HealthKit 读取授权不能被直接判断为允许或拒绝，因此完成设置显示“已设置”，不显示绿色“已连接”。取消选择不会撤销系统已授予的权限。Mac 预览和无签名模拟器版本不弹健康授权。真机需要启用 HealthKit 的签名和描述文件，已准备 Sela.entitlements 和两种构建配置的 CODE_SIGN_ENTITLEMENTS 待审阅改动。

Apple 图标来自 App Store 官方记录，位置使用系统定位符号。WPS 图标来自官方 App Store 记录；WPS 入口通过原有文档工作区与系统文件选择器导入用户选定的文件，不将此方式标记为 WPS 账号授权或云盘全量访问。

`connection-tests/native_permissions.py` 只更改 com.sela.iospreview 的模拟器权限，检查原生框架对未允许、已授权和收回权限的返回。模拟器 contacts-limited 设置在此环境返回完整授权，未据此宣称验证了真实的联系人部分选择界面。它不验证系统授权弹窗，也不读取任何用户记录。测试后重置相关模拟器权限。

`connection-tests/native_tool_contracts.swift` 运行 29 项参数、范围、歌曲编号、睡眠重叠与坐标取整检查。`connection-tests/native_tools.py` 通过 DEBUG 专用的模拟器入口运行 13 项调用链检查，包括拒绝、取消、日历/提醒/联系人的临时记录查询、照片元数据、注入模拟坐标后的单次定位，以及健康/音乐在模拟器中明确报不可用；临时记录已清除，没有模型网络调用。iPhone 实机编译单独验证；健康授权和音乐播放尚未在已签名真机上验收。

用户要求已删除页面中的开发说明、Mac 预览提示、HealthKit 签名解释等冗长文字；这些边界仅保留在本文和验证记录中。实际权限与连接状态不使用虚构的成功值。

用户要求已移除全部面向用户的试用、试查表单（含原生服务和携程），保留后端接口与 DEBUG 开发验证。等待用户后续通知再连接手机验收。
