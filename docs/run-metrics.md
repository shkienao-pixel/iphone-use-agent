# 可追溯运行计时与基准报告

`AgentEngine` 每次启动或恢复创建独立 `AgentRunMetrics`，同一任务恢复保留 task ID，但 attempt ID 不同。任务准备检查失败、取消、部分执行和未知结果均保留。原来的文本日志最多 150 条；本 JSON 是完整计时来源，不依靠日志相加推算总耗时。

## 生产接入

- 在 App 容器的 `Library/Application Support/PhoneAgent/RunMetrics/<attempt UUID>.json` 保存，至少启动、每 0.5 秒有事件时及终止时原子写入。异常退出留下未结束记录，其 outcome 保持 unknown；基准工具拒绝把它当完成样本。持久化失败时 snapshot 的 `persistenceError` 明示失败。
- App 版本/构建号、源码与 Harness 身份来自安装包 Info.plist。`PhoneAgentSourceRevision`、`PhoneAgentHarnessVersion`、`PhoneAgentFirmwareVersion` 缺失就为 unknown，不用工作区版本推断安装版。固件协议没有提供可核对版本时仍为 unknown。
- 保存已配置模型名称、接口 host、设备和系统标识，以及实际共享流 capture ID/尺寸变化，不保存 API Key、任务全文、剪贴板正文、会话全文或模型响应原文。
- 开始准备、模型请求（失败/格式重试也计次）、OCR、输入、等待、取屏、布局/宏、系统工具和核验在真实执行边界计时。主循环经 Harness 注入 recorder，宏内 OCR/输入/核验可继续细分。
- 模型时间包含准备、网络及服务端推理。上传时间来自 URLSession 的 requestStart/requestEnd 事务时间戳，包括 HTTP 请求头和请求体；缺失时间戳就保留未知，不能把整个网络往返当上传，也不能将未知写成 0。
- 正常结束计时覆盖释放输入；取消也等待输入释放后关闭 attempt。恢复创建新 attempt，不抹掉取消或失败样本。

持续时间用单调时钟，与墙上日期分开。`exclusiveSeconds` 为互斥归因，和 `unattributedSeconds` 相加等于总时间。`inclusiveSeconds` 为各类区间并集，保留宏包含输入/等待的事实，**不能再相加**。重叠时显式子 span 优先，否则后开始的操作视为当前叶节点。未归因时间包括主线程调度、记录写入、局部计算和未接入的操作，并在 JSON 附解释。

模型返回 finish 仅记录 completed，独立正确性仍为 unknown。`isVerifiedSuccess` 还要求 correctness=verified 和明确 sideEffectErrors=0。预览、片段核验、未知副作用均不能算准确性通过。当前生产主循环尚没有自动独立全文或发送次数验收，不应据此字段声称真机任务准确率已通过。

## 预先固定起点

在「设置 → 运行与基准记录」可填固定任务标识/对照组、初始页、搜索/剪贴板状态、正文准备、Mac 连接及人工介入数，核对后用于下一次启动或恢复。同页可查看最近 20 份记录，并通过系统分享面板导出单份或显示的记录；应用不会自动外发。

默认初始页面、搜索状态、剪贴板状态、正文准备、Mac 连接情况均未知，`confirmed=false`。基准调用方通过 `engine.initialRunConditions` 预先注入任务 key、比较 key 和已核对的起点；普通交互任务不会自动获得“同条件基准”资格。不要在得到成绩后挑选样本或补造起点。

每个 before/after 目录应包含该版本该场景的全部 attempt JSON。若同一任务中恢复，恢复后的 attempt 也必须保留。人工操作次数及 Mac 连接在 conditions 明列。要比较完整用户任务，需另外按 task ID 汇总跨 attempt 时间；单 attempt 报告不等于中断恢复后完整任务的端到端成绩。

## 复算

```sh
bash scripts/run-benchmark.sh /path/to/before /path/to/after /path/to/report.json
```

读取每个目录全部 JSON，任何 JSON 无法解析会失败，不会悄悄忽略失败样本。输出保留全部原始 attempt、样本量、中位数、最小/最大值、模型调用中位数、每种 outcome、正确性未知数、人工介入及副作用错误数。每组至少 3 次；样本不足不输出提速比例，不计算 P95。

比较会拒绝未结束/无效计时、未确认起点、任务或读取范围 key 不同、初始页面/搜索/剪贴板/正文准备/Mac 连接不同、模型/接口/设备/系统不同、组内混合安装版本、缺少 App/源码/Harness 身份，以及真机固件身份未知。offlineReplay、simulator 与 deviceGUI 不能混在同一比较。`comparable` 只表示时间统计具备相同比较范围，正确性另看 `correctnessAccepted`；`eligibleForDeviceAcceptance` 还要求全部为 deviceGUI 且所有样本完成独立正确性核验和零副作用错误。具体 ≤60 秒、≤5 轮、50%/40% 等目标需对照本轮预先写定的验收文件。

## 离线覆盖与限制

```sh
bash Tests/RunMetrics/run.sh
```

第一段用可控单调时钟测试生产区间计算/持久化/全部样本归因，第二段运行生产 `AgentEngine` 与假的取屏、模型、输入来检查 preflight 失败记录、取消/恢复身份、实际阶段接入和完成不等于正确性通过。可给脚本一个 JSON 路径导出三组 before/after **合成时钟样本**。这些数值仅验证报告可复算，不是旧版/新版 Agent 的速度测试，更不是真机成绩。

本轮没有据此生成真机提速比例；176.7 秒历史参考也不能替代同条件旧版三次基线。当前固件版本、手机起始状态、真实落点、实际发送与全文正文正确性，需要真实设备证据。
