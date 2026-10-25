# 携程官方查询连接器

这是携程官方旅行信息查询接口的独立 Mac 连接验证工具。连接验证通过后，再接入 iPhone App 的配置界面与工具路由。当前只执行查询；没有下单或支付功能。

## 本机配置

需要 Python 3，以及本目录 `.build/keychain-helper` 可执行文件。辅助程序使用 macOS 系统钥匙串保存授权码，不把授权码写入项目文件。

首次使用时，在项目根目录编译辅助程序（需要 Xcode 命令行工具）：

```sh
mkdir -p Tools/Ctrip/.build
chmod 700 Tools/Ctrip/.build
xcrun swiftc Tools/Ctrip/KeychainHelper.swift -o Tools/Ctrip/.build/keychain-helper
chmod 700 Tools/Ctrip/.build/keychain-helper
```

```sh
python3 Tools/Ctrip/connector.py setup-ui --port 0
```

命令只输出随机的 `http://127.0.0.1:端口/` 页面地址和进程号。打开这个地址，在密码输入框中填写已申请的携程授权码，再点击“保存到钥匙串并查询”。点击按钮才会保存授权码并向携程发起真实查询。页面会清空密码框，显示本次结果。已有授权码时可以直接点击“使用已保存授权码查询”。关闭页面不会停止服务；终端按 Control-C 停止服务。

不要把授权码放在命令参数、环境变量、聊天消息、截图或项目文件里。若系统弹出钥匙串权限框，由本人确认。本连接器只通过辅助程序标准输入保存授权码，读取时只捕获其标准输出；不会转发辅助程序原始输出或错误。

## 查询与状态

```sh
python3 Tools/Ctrip/connector.py status
python3 Tools/Ctrip/connector.py query '上海一日游有哪些值得去的景点？'
python3 Tools/Ctrip/connector.py status --ui-port 运行页面端口
```

输出为 JSON。普通 `status` 只包含钥匙串配置状态和当前进程状态，测试状态不会跨进程保存。使用 `status --ui-port` 读取运行中的配置页，或访问其 `/api/status`，可以确认用户验证结果：`configured` 为是否已配置；`test_state` 为 `idle`、`running`、`ok` 或 `error`。状态接口不包含授权码、查询文字或响应正文。查询结果只在原请求响应中出现。

辅助程序路径可以通过全局参数 `--keychain-helper /绝对路径` 或环境变量 `PHONEAGENT_CTRIP_KEYCHAIN_HELPER` 指定；这里配置的仅是程序路径，不能放授权码。

## 接口与限制

固定请求 `POST https://externalcallback.ctrip.com/skills/api/crew/skillhub/searchInfo`，请求 JSON 为 `inputs.token` 和 `inputs.query`。使用系统默认 TLS 证书验证、不继承代理、不跟随重定向。查询最多 4096 字符；响应最多 1 MiB；单次 API 调用最长等待 45 秒。仅接受顶层 `result` 的非空字符串，或 `result.content` 的非空字符串；不会把 `state`、`messages`、`events` 等原始响应作为结果输出。HTTP、业务、解析及系统错误只显示固定的安全提示。

配置页只监听 `127.0.0.1`，验证 Host、Origin 和 CSRF，使用 CSP 和禁止缓存的响应头，无外部脚本或资源，不记录访问日志。返回内容作为纯文本展示；不执行结果 HTML，不加载结果中的外部图片。授权码的精确匹配会被替换；检测到 URL/HTML/JSON 转义后的授权信息时，整段结果会隐藏。没有本地旅行查询或响应正文存储。

## 离线验证入口

```sh
cd Tools/Ctrip
python3 -m unittest -v test_connector.py
```

这些检查仅使用虚构授权码、内存存储与本机测试服务，不访问真实钥匙串或携程。

`connector.py` 可导入，不会在导入时读取凭据或调用网络。可注入假的 `KeychainStore` 或 `ConnectorService(store, query_fn=...)`，`call_ctrip(..., opener=...)` 也接受离线 HTTP fake。可测试的函数包括 `sanitize_text`、`extract_result`、`validate_query`、`validate_token`、`create_server` 及 `read_ui_status`。请只用虚构授权码运行离线测试。
