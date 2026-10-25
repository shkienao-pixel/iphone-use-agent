# ChatGPT 计划额度连接

离线稳定性补测：账户就绪与在途结果归属使用不含临时访问令牌的授权绑定；同账户正常令牌轮换不会使已成功的记忆学习结果丢失。主体、客户端注册、账户、权限或授权代次改变仍使旧结果失效，实际 HTTP 请求继续由令牌管理器注入访问令牌。新登录创建新代次，正常续期保留代次；迟到续期不能覆盖重新登录后的授权，旧档案可兼容读取。复现与修复后记录见 `output/simulator-plan-20261025/`，入口为 `Tests/PlanMemoryIntegration/run.sh`；这不代表专用模拟器已经完成用户登录或真实模型验收。

Sela 的 API Key 连接与 ChatGPT 计划连接分别计费。Work / Codex 中有可用点数，不代表 API Key 所属组织的 API 余额也有余额。

2026-10-25 的账户读取确认 Work / Codex 剩余约 62,164.82 点，允许正常使用；先前失败的 API Key 请求返回 `credit_balance_exhausted`，对应 Personal API 组织的余额为 -US$0.04。用户选择使用现有 Work / Codex 额度，不进行 API 充值。

## 使用方式

在 Sela 的「App 连接」点击 ChatGPT 卡片，或从「模型与记忆」进入模型连接，选择「ChatGPT 计划」，点击「Continue with ChatGPT」。在官方页面选择账户和工作区，并完成使用计划用量的授权。身份登录与使用计划用量是两项不同的授权；实际可用性、模型和应用限额以授权账户返回的结果为准。卡片沿用相关 App 的图标、现有连接卡样式、真实状态及设置入口；后续相关能力更新也遵循此展示要求。

登录后从该账户实际返回的模型列表中选择模型。退出连接会撤销续期授权并清除本机令牌；本机保留客户端注册标识，重新连接时复用。原 API Key 不会自动删除，也不会在计划连接失败时自动启用 API 计费。

## 实现边界

- 使用官方 OAuth 动态客户端注册、PKCE、独立 state / nonce，以及仅绑定 `127.0.0.1` 的回调监听。
- 校验 ID Token 的实际 RSA/JWKS 签名、issuer、audience、有效期、nonce 和已保存账户；核对明确授予的计划权限。
- 令牌仅保存在此 iPhone 的钥匙串。续期串行合并，替换旋转的刷新令牌；更换账户后丢弃旧账户请求结果。
- 模型请求仅发往公开的 `https://api.openai.com/v1/responses`，使用 `store:false`、`stream:true`。仅收到完整的 `response.completed` 后，回复才进入既有动作解析和执行检查。
- 不读取其他应用的登录令牌，不调用非公开 ChatGPT 后端接口，不自动重试未知提交结果。
- 此连接支持当前 Sela 的文字和图片请求。原生 iOS 工具在手机执行；ESP32 不参与本轮验收。

## 验证状态

`Tests/ChatGPTPlan/run.sh` 验证 OAuth 绑定、实际 RSA/JWKS 签名、请求转换和 SSE 终止条件。离线检查不代表账户已经授权，也不代表实际额度请求成功。真机安装、官方账户授权、真实模型调用和原任务恢复应分别记录在 `output/ios-native-longrun-20261025/`。

Build 119 已在 iPhone 13 Pro 完成真实计划模型调用、原生 HealthKit 正样本查询与完整报告，完整回归和打包 skill 检查通过。原长测任务 `480210AB-4123-4279-9917-86FAAD66A181` 从第 5 步同 ID 继续，复用已有 3 份健康读取回执，在第 124 步完成；恢复段有效执行 1066.69 秒，全部 29 份产物与 63 份真实健康回执独立核对通过。运行期间令牌自动续期且任务未中断。这是受控恢复，不是全新一次发送验收。卡片和点入入口已在真机核对。证据分别见 `candidate-chatgpt-completed-items/verification.json`、`HEALTH-HISTORICAL-H08/verification.json`、`L3-NATIVE-H21-R2/continuation-verification.json`、`CHATGPT-CARDS-C01/verification.json` 和 `chatgpt-plan-integration/automatic-refresh-verification.json`。

官方文档：[ChatGPT plan usage](https://developers.openai.com/siwc/token-sharing-open-source)、[注册与登录](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)、[请求与模型](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)。

## iPhone 17 Pro Max（Build 130）

2026-10-25 已在这台手机完成官方 ChatGPT 计划登录与计划用量授权，将当前连接从 API Key 切为 ChatGPT 计划，并重新确认对应接收方的数据使用授权。实际返回 7 个可用模型；真实最小推理的固定文本匹配，原“明天早上 9:10 的铃”原话经真实路由返回 `task`。这两项验证均未执行原生闹钟创建。

冷启动后连接、计划授权及数据授权仍有效。对话、任务、队列、订单记录与草稿逐字节保留；设置只改变接收方、端点和认证模式，另更新对应的数据授权。API Key 保留在原钥匙串中，当前请求不使用它；没有复制其他设备的登录令牌，也没有操作 iPhone 13 Pro。证据：`output/iphone17-chatgpt-plan-20261025/verification.json`。
