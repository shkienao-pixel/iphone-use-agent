# 输入附件离线回归

运行 `bash Tests/ComposerAttachments/run.sh`。可分别使用 `--import-only`、`--lifecycle-only`、`--wire-only` 检查本机导入、任务生命周期或请求编码。

`Fixtures.py` 生成无个人资料的 UTF-8、UTF-16、GB18030、CSV 和基础 Office 文件；测试运行时生成 PDF 与图片。`ImportChecks.swift` 编译当前实际导入服务、附件 Store、Office 解析器、ImageIO、Vision 与 PDFKit，检查提取内容、编码、无文字图片、输出尺寸/字节数、文件/页数/文字边界、部分成功和取消隔离。未调用模型。

`LifecycleChecks.swift` 编译当前实际任务 Engine、history 与 queue Store 和附件策略；仅替换 UIKit 导入，使用现有 ProductState 的离线屏幕/模型/输入边界。检查旧记录兼容、附件编码回读、队列恢复、任务提交/补充/继续/新任务隔离，以及资料不能升级为指令或当前手机屏幕的约束。该部分的 JPEG 头哨兵只检查策略和序列化，不代表可解码图片；真实图片由前一部分验证。

`WireChecks.swift` 编译当前完整 VisionClient，只把 HTTP `load` 方法体替换为本机请求收集器。检查实际编码的图片/文字是否进入请求、参考图与手机截图是否分开、超长材料是否与问题分别校验，以及无效附件是否在请求前被拒绝。没有 HTTP 请求或实际模型推理。

本套件未检查 iOS 照片/文件选择器交互、真机授权、实际模型理解、后台生命周期或真实手机操作，不代表端到端真机验收。
