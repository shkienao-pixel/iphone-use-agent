# 原件文件发送（WP8）

本轮提供手机本地资料库、生产发送协调器、持久化防重放记录、可信 GUI 驱动接口，以及可由原生按钮发起的系统分享链路。当前没有实机验收记录；离线测试不会计入微信发送成功率。朋友圈互动不在这一文件发送实现中。

## 原件 manifest

`FileTransferStore.importFileAsync(at:sourceID:mediaType:)` 接收原生文件选择器取得的文件 URL，读取真实文件内容，保存手机应用内的独立原件副本。manifest 保存 artifact UUID、来源 ID、完整文件名、类型、真实字节数、SHA256 和导入时间。每次发送计划另外保存原始顺序，所有项要求 `original_bytes`；代码不压缩或重编码图片、视频，不改文件内容。

- 只接受普通文件；目录、符号链接、非法名称、冲突的来源 ID、不一致内容及单件超过 2 GiB 均拒绝。同一 sourceID 的名称、类型和真实内容完全一致时幂等返回旧原件，不改导入时间。
- 大文件的拷贝、hash 与提交前内容核查放在后台 worker，按 1 MiB 块检查取消；UI actor 仅验证元数据及持久化检查点。
- 导入前后的原件副本摘要不一致会删除副本，不生成可发送 artifact。
- 文件选择顺序由传入 artifact ID 数组确定；不能由排序后的文件名替代。
- `mediaType` 来自原生导入器的文件类型元数据；SHA256 证明字节一致，不将文件扩展名包装成内容解析/视频解码验收。

## 两个实际执行入口

### 原生系统分享

原生用户按钮调用：

```swift
try await coordinator.beginNativeShare(
    operationID: stableID,
    taskID: taskID,
    artifactIDs: selectedIDs,
    requestedRecipientDescription: userRequestedTarget,
    environment: environment
) { originalURLs in
    // Present UIActivityViewController with these exact originalURLs.
    // This callback has already crossed the durable submissionPending boundary.
    return .extensionCompleted(activityType: activityType)
}
```

协调器核查原件字节后，**先落盘 `submissionPending`，才调用 present**。分享扩展一旦打开，用户可能已经发送；不能把 present 算作无副作用选择阶段。

系统分享扩展的 completed 只说明扩展回调，不能证明具体收件人、文件上传完成、消息已发送、对方收到或已读。记录中的目标是 `nativeShareRequestedUnverified`，明确保留用户要求的目标说明。`.extensionCompleted` 和 `.dismissedOrUnknown` 均保存 `unknown`，并阻止自动重开分享或通过新任务、新 operation ID、更换配件绕过。

`UIActivityViewController` 的 `completed == false` 应映射 `.dismissedOrUnknown`。只有宿主独立证明扩展未启动/未提交，才可以返回 `.confirmedNotSubmitted(evidenceID:)`，普通关闭回调不是这种证明。

### 可信 GUI 驱动

`FileTransferDriving` 供真正的本地页面适配器接入，不接收模型生成的“发送成功”JSON：

1. `locate` 根据原件内容身份找资料，返回唯一选择 handle。
2. `select` 仅选择，不允许发送或打开可提交的分享扩展。
3. `observeSelection` 用新帧逐项确认选择数量、source ID、原件 hash/受管 payload、原顺序、原质量，以及当前稳定收件人。
4. 协调器持久化 `submissionPending`，才调用唯一的 `submit`。
5. `inspect` 只读核查上传/原对象消息，分别保存每项结果。每个成功结果必须有独立、唯一、绑定原会话和原件的消息锚点。

目前没有可信驱动时，`start` 明确返回 `unsupported`，不会模拟成功。真实第三方 App 若只显示文件名、大小、缩略图或 OCR 文本，适配器必须返回 `metadataOnly`/`unknown` 或抛出 unsupported；不能伪造不可见的 hash。只有以下内容身份允许提交：

| 身份等级 | 所需依据 | 可自动提交 |
|---|---|---|
| `exactBytes` | 实际来源 ID、类型、大小、内容 SHA256 及顺序均一致 | 是 |
| `managedOriginalBytes` | 实际控制器使用协调器发出的原始 URL payload，且 binding UUID、hash、来源、顺序均一致 | 是 |
| `metadataOnly` | 文件名/大小等可见元数据 | 否 |
| `unknown` | 无可靠关联 | 否 |

受管 payload 只能证明选入控制器的本地原件，不能凭它宣称第三方 App 内的消息一定对应该原件。发送结果仍要有独立原对象证据。原生分享完成回调不能充当这份证据。

当前 UI 快照必须匹配手机、配件、capture session、前台状态，采集时间在动作要求之后且距核查不超过 1.5 秒。选完资料后先异步核对原件，再取得新帧，避免大文件 hash 导致旧画面继续提交。

内置文件传输助手要求独立的内置互传说明及当前会话身份，不能只有标题。普通联系人还要求原生用户明确选择的稳定账号、选择证据及准确文件范围；显示名、同名搜索行或模型推断均不足。

## 状态、取消和恢复

逐项状态区分 `notSubmitted`、`submissionPending`、`uploading`、`observedSent`、`confirmedFailed`、`unknown` 及单列的 `userReportedSubmitted`。没有 `delivered`/`read` 属性。

- 提交边界之后任意异常、中断、取消或进程重启均保留待核验；未知不算失败或成功。
- `resume` 遇到待核验项只调用一次只读 `inspect`，不会定位、批选、输入或重发。仍未知则硬停。
- 即便这次核查确认未提交，也先返回结果；后续显式 resume 才能重新准备明确失败/未提交项。
- 任一未知项阻止整批自动补发；已提交项不会被补发。
- 只允许补明确未提交/确认失败的后缀。较早文件失败、较后文件已提交时，补发会改变原顺序，协调器停止并说明。
- `cancel` 停止后续输入，但不会抹掉已跨提交边界的未知结果。原生晚到的 completed 回调不会恢复执行权限。
- 人工核验需显式调用 `resolveReviewed`，可传 `artifactIDs` 仅解决已逐项检查的文件，不影响其余未知项。用户说已发只记录 `userReportedSubmitted`，不升级为自动 hash/收件人核验或送达证明；说仍未知继续阻断。
- 存储损坏、写入失败、记录超出容量均 fail closed，不删除未决记录换取继续发送。
- 同一 Store 的活动 lease 阻止多协调器重入。宿主通用 GUI/Engine 应在 `hasPendingReview || hasActiveOperation` 时停止其他 GUI 输入；不允许用新任务绕过。

## 离线验证

运行：

```sh
Tests/FileTransfer/run.sh
```

测试使用实际临时文件、真实 SHA256/字节数、本地原件副本、原子 JSON 检查点和生产协调器；只有 GUI/原生分享宿主由 fixture 代替，不运行模型、不读取实际联系人、不发送任何消息。

覆盖：同名同大小不同内容、错收件人、错 hash、仅元数据、质量变化、错顺序、过期新帧、提交前持久化、提交中断、取消前后、重启、跨任务/ID/配件阻断、上传与发送分离、缺失结果、唯一消息锚点、明确失败补发、未知禁重发、顺序不能恢复、原生 completed/关闭仍未知、人工结果单列、写盘失败和原件被修改。二进制 video fixture 只验证字节不变，不是实机视频分享/播放验收。

还需要真机核验系统分享扩展行为、真实微信来源和收件人身份、上传状态、文件消息证据、后台/锁屏中断，以及视频实际播放/原质量。没有这些证据前，不把文件原件导出或扩展 completed 写成微信发送验收通过。

## Build 74：真实页面驱动与可支持条件

新增 `WeChatFileTransferDriver`（生产驱动）和 `WeChatFileTransferPages`（当前真实 OCR 页面解析）。它们接收低层 `read/tap/scroll`，由宿主提供真正的 `UIActivityViewController` 呈现事实；既不是仅声明协议，也不接收模型构造的成功结果。

### 可执行的自动原生分享

`FileTransferCoordinator.beginAutomaticNativeShare` 保存用户明确选择的账号和原件范围；先持久化可能提交状态，再调用真实宿主呈现。呈现前没有声称收件人已核验。Phone Agent 必须在前台，不能从后台假装打开原生控制器。

原生宿主只能在实际控制器以这批 `payload.fileURLs` 创建且完成呈现之后，返回 `WeChatNativeShareBinding(presentationID:payload:presentedAt:)`。这个 binding 证明交给原生控制器的本机原件来源与顺序；不证明微信内部或接收方文件内容。

生产驱动可执行：真实分享面板中独立定位“微信”→具备精确账号证据的选择行（若存在）→下一步→当前确认页逐项核对→唯一发送控件。所有定位来自刚读取的画面，不使用固定坐标或旧行位置。

**当前自动发送的支持条件非常严格：**

- 当前扩展独立显示精确 `微信号：<已授权账号>`，或内置文件传输助手的独立互传说明。昵称/显示名匹配的快速发送行不会点击。
- 当前确认页可读取唯一、准确的文件数量，每个完整文件名、每项精确 B/字节数及原顺序；同名文件无法逐项核验顺序会停止，KB/MB 缩写不充当精确值。
- 当前界面必须有明确的“已选择原文件/原文件模式已开启”状态。单独出现“原文件”选项、未识别的开关图形，或可压缩媒体模式均不足。
- 原生 presentation 仍是同一个实例，手机、共享、配件和真实新鲜确认都未改变。

在实际 Send tap 之前，协调器再次持久化当前扩展的完整 OCR 快照、账号证据、原件清单和顺序。Send 仅派发一次；派发中断不会重试。

标准微信分享扩展若只显示昵称、文件摘要或缩略图，不满足这些条件，驱动会停止。**本轮没有证据证明用户当前安装的微信扩展具备上述确认页，所以这是一条受限条件下的可执行路径，不是已通过真机验收的通用微信自动发送。**

### 聊天文件选择器的实际导航

直接微信文件入口可复用 `WeChatConversationDriver`：从用户已打开的普通联系人资料页真实微信号→“发消息”的受控导航；或文件传输助手独立身份。再通过保留完整消息锚点的当前会话，点击真实附件入口、文件、手机文件，识别真实系统 Files 浏览器。

它不会点击 Files 里的文件行：跨 App 文件名、目录名、同名同大小、甚至文件名中放入 SHA256，都不能证明第三方实际选中内容。单文件 picker 选行还可能立即返回微信并提交。`observeSelection` 因此保留 `metadataOnly`，协调器在提交前停止；不能用本机可控目录作为伪造远端 hash 的捷径。原生原件 URL 分享提供的是另一条真实来源桥接，不能把它的本地 binding 偷换给外部 picker。

### 真实结果与时间

发送后的页面按当前账号再次核对。可见文件名、上传中、发送中或扩展 completed 均不会复制本机 SHA256 作为“观察到的远端 hash”。实际页面 JSON 保存在每项 `.unknown` 证据中，可导出供人工核验；未知项继续全局阻断重发。

`capturedAt` 保留真实像素时间；可另外传真实系统 idle `confirmedAt` 判断当前静止画面的新鲜度。不修改旧像素时间，也不因新的 idle 确认捏造新气泡/新消息。

`Tests/AutomaticFileTransfer/run.sh` 直接运行生产协调器、真实页面驱动和解析器，替换的只有低层 GUI 截图/点击以及原生宿主。覆盖实际动作序列、准确 ID 选行、下一步、Send 前落盘、错账号/清单/质量/大小/顺序、不完整确认、原生 binding 改变、取消、重启只读核查及 Files 导航后停止。fixture 使用明确列出的支持页面形态，不能证明已安装微信具备这些页面；没有真实联系人消息被发送。

### 原生宿主二次就绪检查

`beginAutomaticNativeShare` 可传 `validatePresentationEligibility`（MainActor 同步 throws，默认空闭包兼容原调用）。宿主在此核对真实前台状态、可呈现工作区宿主仍挂载、当前无其他分享面板。该检查发生在原件异步 hash 完成之后，首个操作检查点及 `submissionPending` 之前；拒绝不会创建操作 ledger 或 pending 状态，同一已授权计划 ID 可待前台恢复后重新显式启动。

通过该检查后才落盘并呈现。呈现或实际派发开始之后的任何失败仍为 unknown；不会依据前一次就绪检查把未知发送降级为未提交。

## Build 75：原件资料库与独立来源

同步和异步导入都按真实内容 SHA256 与真实字节数查找复用候选，并重新读取已存文件确认当前字节一致。每个新的 sourceID 仍保留独立 artifact ID、原始文件名、类型、导入时间与 `ID/原始文件名` 路径；同内容的不同文件名不会合并成一个业务文件，也不改已保存回执中的 manifest。相同 sourceID 若全身份相同，返回旧 artifact；名称、类型或字节冲突则拒绝，不覆盖旧来源。

可用时，新路径以容器内的实际 hard link 复用已验证字节。系统不支持 hard link 时执行普通文件复制，合法导入仍可完成；不会根据 metadata 声称节省空间。候选已丢失或实际内容损坏时不复用它，也不改写那份旧原件；新有效来源独立保存。导入与已存 payload 的全文字节校验继续有效。

应用不编辑受管原件，当前也未给它们设置只读或 immutable 文件标志。硬链别名共享可写 inode；第三方分享扩展若改写一个 URL，其他别名也会受影响，后续 payload 的真实 hash 核验会拒绝发送。已交出 URL 后的第三方写入窗口仍需真机验证，不能把本地核验当作扩展全程防篡改；只读标志与实际 iOS 分享扩展的兼容性也尚未验收。

### 归档、恢复与删除

- `archive(id:now:)` 和 `restore(id:)` 仅更新可选 library 元数据，原 artifact 和旧 manifest 不变。归档 ID 不能进入**新**的 `manifest(artifactIDs:)`；旧回执读取、现有 payload 核验仍保留。
- `managementItems(referencedBySavedPlans:)` 返回每项原件、归档时间、匹配内容的来源数、回执引用、保存计划引用及不能删除的具体原因。匹配内容来源数来自导入 manifest 分组，不等于物理去重率。
- `deleteUnreferenced(id:referencedBySavedPlans:)` 没有省略计划引用的重载。宿主必须传入**全部**已保存自动发送范围的 artifact IDs；任一回执 manifest 引用、计划引用、文件操作 active/pending，或当前导入/空间核算进行中，均拒绝删除。
- 只删除应用内的托管副本，从不删除原生文件选择器最初给出的用户源文件。共享 inode 的其他来源路径继续保留。

删除先原子保存独立 deletion intent，再将准确 artifact 目录移到同容器 trash，接着原子提交移除该元数据，最后清理 trash 和 intent。若写入抛错，恢复逻辑重新读取**实际磁盘元数据**，不假定写入一定未发生：元数据仍保留原件则回滚目录移动；元数据已提交删除则完成清理。进程重启按相同规则恢复。无法判定的损坏记录或未完成清理保留恢复 intent 并停止继续操作，不破坏旧证据。

Build 74 的 version 1 JSON 可直接读取：缺少 library 字段时默认为未归档，缺少 humanReviews 时保留 nil。迁移不重写原 artifact 或旧回执 manifest。

### 空间核算口径

`storageStatisticsAsync()` 在后台读取真实字节、核对内容，并用文件系统的 device+inode 计算硬链复用。由用户明确点击核算，避免展开资料库时自动重读大视频；结果是一次核算快照，不是整个 App 容器的空间总量。

| 字段 | UI 建议标签与含义 |
|---|---|
| `manifestBytes` | 各独立来源原件声明字节合计，重复内容仍逐来源计入 |
| `actualPathBytes` | 实际可读取路径的文件字节合计，硬链路径重复计入；若有缺失，这是已测部分 |
| `uniqueStoredFileBytes` | 实际文件按 device+inode 去重后的文件长度；不能完整核对时为 nil |
| `allocatedStoredBytes` | 文件系统报告的已分配字节，按 inode 去重；不支持或核算不完整时为 nil |
| `hardLinkSavingsBytes` | 已测路径字节减去实证唯一 inode 文件长度；普通复制回退是 0，无法完整核对是 nil |
| `unavailableArtifactIDs` / `corruptArtifactIDs` | 明确列出不可读或内容不一致的原件，未知不当 0 |

### 人工核验历史

`FileTransferOperation.humanReviews` 是兼容旧记录的可选数组，保存每次真实人工结果的 ID、逐项 artifact IDs、结果、说明和时间。每项必须属于原 manifest，记录 ID 与项内 artifact IDs 不能重复；最多 500 条，说明 1–1000 字，日期须为有效值并位于该操作创建和最新检查点之间。用户说已提交仍是单列的人工作证，不升级为自动 hash 核验、送达或已读。

`Tests/FileLibrary/run.sh` 使用真实临时文件和真实文件系统 inode，覆盖同步/异步复用、sourceID 幂等与冲突、同名异 hash、损坏候选、hard link 失败复制回退、并发导入、归档/恢复、旧 payload 不变、回执和保存计划引用保护、删除写入前后失败、移动已发生后报错、重启回滚/完成、不可清理状态、旧 JSON 迁移及人工历史字段校验。没有操作用户已有原件。
