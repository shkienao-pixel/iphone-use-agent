# 本机工作流诊断归档（Build 75）

诊断保存捕获驱动传入的原始 JPEG 字节，不缩放、不重编码。每条记录包含原图 SHA-256、原字节数、captureID、像素采集时间 `capturedAt`、系统确认时间 `confirmedAt`、OCR 元素、scene、blocking 状态，以及工作流/操作 ID、动作、停因和结果。静止页面的像素时间与后续系统确认时间分别保留，不把旧像素时间改成当前时间。

## 接口

`WorkflowDiagnosticsStore` 在主线程使用，可注入临时目录和 `WorkflowDiagnosticsPolicy`；生产使用 `.shared`。捕获驱动可传 `diagnostics: nil` 禁用写盘，离线测试不触及用户默认目录。

```swift
let context = WorkflowDiagnosticContext(
    workflowID: workflowID, operationID: operationID,
    boundary: .beforeInput, captureID: frame.captureID,
    capturedAt: frame.capturedAt, confirmedAt: frame.confirmedAt,
    snapshot: snapshot, action: action,
    protectPendingSubmission: pending
)
let entry = try store.record(jpeg: frame.jpeg, context: context)
let originalJPEG = try store.preview(id: entry.id)
let package = try store.export() // package.url：可分享的单个 JSON 文件
let cleanup = try store.clearResolved()
```

`records` 和 `error: String?` 为可观察状态。上下文无效、受保护记录占满容量或持久化失败会抛错，并发布“本次诊断未记录”。原图未保存时仍可记录元数据，但 `imageStatus` 明确说明无图、无效 JPEG、单图超限、空间不足或写入失败，`imageStored` 为 false，预览不会返回假图片。原 SHA 和字节数用于说明实际输入，不代表图片已经落盘。

## 有限容量与待核验证据

默认最多 250 条元数据、120 张原图、80 MiB 原图、单图 4 MiB、索引 8 MiB。导出单包最多 128 MiB，派生导出副本最多 3 个且合计最多 256 MiB。测试和调用者可显式注入更小的上限。

记录按观察、完成、操作前后边界、暂停/失败、待提交的优先级保留；仅自动淘汰未受保护且优先级不高于新记录的旧证据。元数据也受数量和实际编码字节限制。容量无法腾出时明确拒绝新记录；图片预算不足时可仅保留带明确状态的元数据。所有实际图片文件均计入图片预算，包括崩溃后未进入索引的孤立图片，不凭索引数量假称磁盘仍有空间。

`protectPendingSubmission` 或 `.pendingSubmission` 需要稳定 operationID。受保护记录及其原图不会被自动淘汰，清理也会保留。`releaseProtection(operationID:reviewNote:)` 只提供按操作释放并留下时间与核验说明的底层接口；生产由 `FileTransferReviewDiagnostics.reconcile` 在对应 FileStore 所有待核验项均已被用户明确核验后调用。`stillUnknown` 不能释放保护，UI 不提供任意解除保护入口。诊断失败、导出失败和清理均不会修改发送日志或未知结果防重发状态。

## 持久化与校验

索引使用校验和封装，图片和索引均通过同目录临时文件、fsync、原子替换提交；先持久化新索引，后删除已淘汰的未保护图片。加载校验索引版本/校验和、字段与 ID 唯一性、文件名、时间、保护释放审计，以及每张已存图的原字节数、SHA-256、JPEG 解码状态和尺寸。损坏索引、缺失原图或校验不符会禁用写入，保留原有文件，不用空索引覆盖。未进入索引的孤立图片不会被当作已核验数据自动删除。

归档根目录和子目录使用持有的目录描述符检查身份；文件名仅由内部 UUID 生成，文件访问采用 `openat`/`O_NOFOLLOW`，拒绝路径穿越、软链、硬链及运行中被替换的目录。调用者指定的可信父目录在初始化时规范化，以支持 macOS 的 `/var` 等系统别名。JPEG 通过 ImageIO 实际解码和尺寸上限校验，任意字节、PNG 或截断图片不能作为已存 JPEG。

## 预览、导出与清理

预览每次重新校验后返回原始 JPEG。导出是真正包含原 JPEG 字节（JSON base64）的单个本机文件，同时带每条记录的元数据和缺图状态，可通过系统分享。导出逐条写入且预先计算包大小；超限不会生成不完整文件。旧导出副本按容量和数量清理，新包写入前先预留空间。

此导出器不自动上传，不把图片发送到模型或 metrics。截图可能含私人内容，由用户决定是否分享。`clearResolved()` 删除未受保护记录及其图片，并清理派生导出包；受保护的原始记录与图片继续保留，之后仍可重新导出。

## 离线验证及边界

运行 `bash Tests/WorkflowDiagnostics/run.sh`：83 项生产 Store 检查通过。测试在临时目录生成可解码的 16×12 JPEG，覆盖原字节与时间链、重启校验、坏索引保留、路径/软链替换、容量与重复遍历、孤立图片预算、导出原图、缺图状态、受保护记录耗尽、按操作释放及清理。没有读取真实截图、设备、剪贴板、网络、模型或 metrics。

`output/reliability-20261023-v4/diagnostic-replay/` 提供由真实 `Store.export()` 生成的合成诊断包、对应合成原图和说明，供离线检查导出结构；它不构成真机截图采集或真机分享验收。实际捕获驱动、Runtime 及 UI 接入由主流程集成套件验证；物理设备行为仍需单独验收。
