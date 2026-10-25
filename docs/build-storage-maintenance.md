# 构建文件和缓存回收

`scripts/cleanup-build-artifacts.py` 只处理本项目 `output/` 内由 Xcode 的 `info.plist` 确认的 DerivedData 子目录。不会删除整个任务目录、源码快照、源码压缩包、截图、JSON 记录、`.xcresult`、手机数据备份或手工保存的回退安装包。

## 保留规则

- 每个应用标识和平台保留最近两份可识别的构建，用于当前开发和回退。NativePanelRunner 的临时会话标识合并为同一测试程序，避免每次随机标识都永久保留两份。
- 两小时以内的构建暂不回收。正在运行的进程、打开的文件，以及同一任务目录内的测试会话，都会保护该任务的构建。
- `.keep-build`、`.build-verified.lock`、`.build-retention.lock` 会阻止回收其所在目录及子目录。保留重要构建时，可在其任务目录执行 `touch .keep-build`。
- 对其余构建，以 8 GiB 为可回收构建缓存的预算；从最旧的开始删除。超过 48 小时的非保留构建即使预算尚有余量也会回收。
- 删除对象限于 `Build`、模块缓存、索引缓存、SDK 预编译模块等明确列出的生成目录。受保护版本可能使总量超过预算，报告会注明；不会为追求预算而删除活动版本。
- 默认是预览模式，必须传入 `--apply` 才会删除。活动检查失败、遇到符号链接或项目边界无法核实时停止或跳过。

## 自动执行

`scripts/build-verified.sh` 在构建退出时回收其他旧构建，并明确保护本次输出。原生 XCTest 控制器在完整会话期间持有 `.build-retention.lock`，会话退出后执行相同维护。

另由本聊天的 Codex 定时任务每小时执行同一清理脚本，覆盖直接运行 `xcodebuild`、未经过上述脚本的构建。Mac 必须开机且桌面应用保持运行；休眠或退出时无法执行本地定时任务。构建退出钩子本身是普通 Python 脚本，无需模型、网络或 API。

定时任务还会在没有包管理器活动时，回收各自超过 1 GiB 的 npm 下载缓存 `_cacache` 和 pip 下载缓存。对于 macOS 用户临时目录的 Chrome 签名副本，仅处理已核对应用标识的 `Google Chrome.app.bundle`，保留最新两份，并跳过两小时以内或仍被进程打开的副本。不会删除 Chrome 正式应用、浏览器资料、node_modules、npx 运行环境、Python 环境、模型权重、登录信息或聊天数据库。

对明确列出的本项目离线测试临时目录，只回收两小时以上且未被活动任务使用的 `module-cache`；保留失败日志、JSON、提取后的源码和测试结果。PDFPreflight 和 ContextLease 的退出钩子也会在失败时清掉编译模块缓存。

自动维护最新和上一次报告位于 `~/Library/Logs/SelaBuildMaintenance/latest.json` 和 `previous.json`，失败原因记录在 `latest-error.json`，报告数量固定。停用定时执行可在 Codex 的本聊天定时任务中操作。曾实测原生 LaunchAgent，但 macOS 阻止其读取文稿目录；该不可用的任务已移除，未要求放宽系统隐私权限。

## 检查和手动操作

```bash
python3 scripts/cleanup-build-artifacts.py
python3 scripts/cleanup-build-artifacts.py --apply
python3 Tests/BuildRetention/main.py
```

如果构建进程被强制终止，锁会保留以保护未检查的输出。应确认对应进程已退出、记录已保存后再手动移除锁；定时任务不会自行抢占锁。
