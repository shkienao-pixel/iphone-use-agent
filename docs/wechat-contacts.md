# 普通联系人：资料账号到聊天的生产适配

普通联系人的稳定范围使用 `wechat.account:<微信号>`，账号保留屏幕原样，不做昵称搜索、拼音匹配、大小写替换或 OCR 猜字。用户必须明确授权账号、准确会话标题、消息条数或日期范围。打开工作区不读取联系人；本轮测试也未读取任何真实资料或私聊。

## 接入

`WeChatConversationDriver(read:tap:scroll:)` 直接接现有 `PhoneWorkflowCaptureDriver` 的三个操作：

```swift
let contacts = WeChatConversationDriver(read: {
    let (frame, snapshot) = try await gui.read()
    return WeChatConversationObservation(snapshot: snapshot,
        captureSessionID: frame.captureID!,
        frameID: "\(frame.captureID!.uuidString)-\(frame.capturedAt.timeIntervalSinceReferenceDate.bitPattern)",
        confirmedAt: frame.confirmedAt)
}, tap: { try await gui.tap($0) }, scroll: {
    try await gui.scroll(older: $0 == .older)
})
let evidence = try await contacts.read(request: request, store: store, direction: .older)
```

文件流程可使用 `bootstrap(target:)` 或别名 `open(target:)`，取得同样的真实资料到会话证明。返回值是 `ChatEvidenceFrame`，不表示任何消息已发送。后续业务输入必须继续核对自己的实际对象与当前收件人，不能把历史会话标题当作发送证明。

## 证明链

1. 用户先在微信打开指定联系人的个人资料。适配器不自行搜索或选同名人。
2. 当前真实 OCR 必须同时提供准确姓名、唯一微信号字段、专属返回标签、朋友圈、“发消息”和“音视频通话”，且位置关系一致。支持微信号整行 OCR 和同一行拆开的字段/值。
3. 当前账号、姓名、设备与明确范围完全一致后，只点一次实际观察到的“发消息”控件。点击失败或取消就停止；不能重试这次导航输入。
4. 后续真实新画面必须同 capture UUID、同设备，准确会话标题及会话结构一致，像素采集晚于点击开始，且真实系统确认晚于点击完成。点击等待 BLE 空闲期间已经出现的真实新聊天像素可以使用；旧像素不能因 idle 确认而变新。过渡时只允许重观察同一个已核验资料页，最多三次，不再点击。
5. `contactProfileNavigation` 记录原资料完整 OCR、按钮锚点、点击起止时间和 capture。后续仅受控滚动、唯一连续消息重叠才能延续身份。
6. 首次独立证明会在进程内登记一次 live bootstrap。保存的 JSON 只保留审计证据，不保留该运行许可；暂停恢复或新运行必须重新从真实资料证明账号。

初始资料页的像素可能已静止一分钟。生产 `gui.read()` 根据真实系统 `confirmedAt` 确认它仍是当前画面；适配器保存原始 `capturedAt` 和可选 `confirmedAt`，不修改时间来制造新帧。资料到会话发生实际页面变化后，聊天像素时间必须自然更新，旧聊天像素不会因 idle 确认而继承资料身份。归档的 `chatConfirmedAt` 与像素时间独立保存并重新校验；旧 JSON 如没有该可选字段，只在聊天像素本身晚于点击完成时才保守接受。

## 已有历史的内置文件传输助手

助手聊天中仍可见独立“手机/电脑互传文件”说明时，原有无输入首帧证明继续有效。已有历史把说明滚出视口时，用户先打开助手个人资料页：聊天右上更多 → Details → 左上助手头像。通用 Details 页的标题、查找、置顶或清空设置不能证明内置身份。

新分支只接受 `wechat.builtin.file-transfer` 范围，实际资料页需同时有准确名称、唯一 `Weixin ID: filehelper`（也支持现有微信号字段别名）、完整的“Transfer text, images, audio and video files between your device and your PC”专属说明、独立 Messages 控件，以及本地真实像素检测的顶部返回和更多图形。账号严格逐字，不纠正 OCR 错字或大小写；说明可由相邻、对齐的最多四行真实 OCR 组成。“About”标签被浮钮遮住时，完整说明、账号与其他结构仍全部必需。带当前聊天顶栏或添加图形的正文复制页拒绝。

只点击一次当前 Messages，再复用原有 `contactProfileNavigation`、真实像素/确认时间、设备/capture、一次 live bootstrap 和后续滚动连续链。资料截图及其文字进入审计档案，不成为可恢复的运行权限；暂停续读、新运行仍须重新证明。没有向截图注入 `platform_identity`，也没有放宽普通联系人的资料结构。普通账号字段另外支持准确英文标签 `Weixin ID`。

此次真机原图的本地静态 OCR 回放发现：与生产相同的 590×1280、英文优先 Vision 识别可读出账号、说明和 Messages，但漏掉中文名称，原始全屏结果会被严格身份规则拒绝。`workflowSnapshot` 因此仅在完整资料候选已由原始 OCR 证实、且没有名称时，对同一真实帧的标题区域做中文优先、准确模式、无语言纠错的本地识别。返回名称取真实 OCR 输出，区域坐标映回原帧；不纠正账号，不向通用 OCR 缓存或长任务上下文补字。重复/无名称、缺少任一候选字段、账号有误或聊天正文均不补充。

两张真实资料原图（About 遮挡及无阻挡）在本机静态回放中，经生产图形检测、生产 ROI helper 和生产资料解析器验证通过；这只是离线识别证据，不能当作已经通过手机导航或聊天读取验收，更不能将保存截图送进 live 读取路径。截图缩放后的 320×694 图形栅格包含六像素宽返回箭头和两像素高更多点阵，相应几何容差仅对真实 `local_visual` 检测结果适用，不改变账号、授权范围或导航证明。

## 空输入框

微信常见空 composer 不显示“发送消息”文字。在已具备独立账号证明的导航或滚动链中，可以使用真实本地像素检测得到的三个元素：

| source / label | 位置与尺寸 |
| --- | --- |
| `local_visual` / `视觉:返回` | 中心 x < 0.18，y < 0.16 |
| `local_visual` / `视觉:更多` | 中心 x > 0.80，y < 0.16 |
| `local_visual` / `视觉:添加` | 中心 x > 0.80，y 为 0.55～0.96 |

三元素必须来自三个实际图形，框合法，宽为 0.02～0.14、高为 0.008～0.10；真实返回箭头单独允许宽 0.015～0.14，更多省略号点阵单独允许高 0.0025～0.10，以保留缩小栅格的六像素箭头和两像素圆点。添加图形门槛不变。另需顶部唯一且准确的真实 OCR 标题、无阻挡浮层。`WeChatContactIdentity.chatPage(snapshot:title:)` 返回的只是页面结构，不能单独证明账号。用 `ocr`、`model`、`platform_identity` 来源写同样标签均不接受。实际像素检测器由统一 GUI 驱动提供。

## 验证与限制

`bash Tests/Contacts/run.sh`：125 项通过，运行生产代码，UI 来源为隔离的 OCR/本地图形 fixture，模型闭包返回严格 JSON。其中实际绘制亮/暗模式 RGBA 像素，通过生产 `PhoneVisualControls.detect` 生成图形元素再进入联系人 driver、reader 和 store；验证缺少一个实际 glyph、错页和同名错号均停止。这些是绘制像素 fixture，不是用户手机截图或真机验收。另覆盖点击期间新像素与点击后系统确认的组合、旧像素/旧确认拒绝及旧归档字段兼容。新增内置助手资料 → Messages → reader/store → 严格引用总结闭环，以及错保留号、OCR 误字、同名联系人复制说明、通用 Details、正文伪造资料、重复字段/按钮、换流、取消、旧时间和恢复权限反例；保留原 81 项普通联系人检查。`Tests/HarnessRuntime` 的 95 项包含资料候选、ROI 坐标映射、状态栏录屏点、重复/缺字段和错误来源保护。

本版覆盖的是可审计、可运行的离线适配与生产驱动，不代表已通过实际微信版本、主题、字体、动画和整屏捕获真机验收。账号看不全、分组资料、备注/昵称布局不在支持结构、图形证据缺失、页面不连续或存在身份冲突时会停止，不会猜人。
