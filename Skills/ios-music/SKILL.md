---
name: ios-music
description: 在提供 Sela music_search 与 music_play/pause/resume/status 的 iPhone 宿主中查询已授权音乐资料库并控制 Sela 自己的播放队列。用于原生音乐查询和播放，不搜索 Apple Music 在线曲库或控制其他 App。
---

# iOS 音乐

## 原子动作

编号是步骤标识，不是新增工具。只控制Sela自己的播放队列，按用户请求组合。

| 编号 | 单一职责 | 输入与完成依据 | 失败或未知时 |
| --- | --- | --- | --- |
| M01 | 确认授权与目标 | 已授权本机音乐资料库、歌曲或艺术家条件 | 不自行购买、订阅、下载或扩大范围 |
| M02 | 搜索一次 | `music_search`，保留实际持久ID、标题、数量及截断 | 空结果不代表在线曲库没有该歌 |
| M03 | 播放一首 | `music_play`使用同一搜索结果的ID和标题 | 不猜ID；不匹配或移除先核对，不能盲目重播 |
| M04 | 控制一个状态 | `music_pause`或`music_resume`各一次 | 无队列不能称恢复成功，不能控制其他App |
| M05 | 查询并判断实际状态 | `music_status`及真实state/confirmed/queue_owner/track | 未确认、停止、中断或未知不能说已经播放 |
| M06 | 呈现结果 | 宿主按实际回执展示音乐卡片，报告真实状态 | 原生命令或播放状态不证明扬声器实际发声 |

搜索：M01→M02→M06。播放：M01→M02→M03→M05→M06。暂停或继续：M04→M05→M06；用户停止后不自动重播。

先核对宿主实际接口与音乐资料库权限，保持 Sela 前台。自动模式明确请求直接执行，沿用宿主可选的逐步审核；系统授权按真实窗口处理。

`music_search(query)` 按歌曲标题或艺术家匹配资料库，最多扫描 5000 首并返回 20 项，检查 `returned_count`、`truncated`、`catalog_search=false`。空结果只说明该可见资料库范围没有匹配，不能断言在线曲库无此歌曲，不能自行订阅、购买、下载或同步整个资料库。

播放前使用真实搜索返回的持久 `id` 和完整 `title` 调用 `music_play(query=id,title=title)`。不得猜编号或拼接标题。它会替换 Sela 自己的队列，仅在用户请求播放时执行。编号/标题不匹配或歌曲移除时重新搜索，不盲目重试。

`music_pause`、`music_resume`、`music_status` 只作用于 Sela 的 applicationMusicPlayer。没有队列时继续播放会返回错误，不能声称恢复了系统「音乐」或其他 App 的音频。

发出命令不是成功播放证据：核对真实 `state`、`confirmed`、`queue_owner`、`track` 与 `position_seconds`。`confirmed=false`、stopped/interrupted/unknown 均不能称已经播放。原生状态也不独立证明扬声器实际发声。状态查询失败不得伪造成暂停成功。

完成时在 `finish.text` 给出匹配对象、真实播放状态和未核验的限制；用户中断后不自动重新播放。设备测试设置、资料库准备与真实 Agent 播放分开记录。

实际验收范围见 [references/acceptance.json](references/acceptance.json)。
