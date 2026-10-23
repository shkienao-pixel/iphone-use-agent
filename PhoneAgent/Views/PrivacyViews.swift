import SwiftUI

struct DataConsentView: View {
    let onDecision: () -> Void
    @State private var showPolicy = false
    @EnvironmentObject private var model: PhoneAgentViewModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AgentPageIntro(title: "允许助手使用这些数据？", subtitle: "同意后才会发送。屏幕共享仍需你在系统窗口中另行开启。", icon: "hand.raised")
                    AgentCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("接收方").font(.caption).foregroundStyle(AgentPalette.secondaryText)
                            Text(PrivacyConsent.recipient(model.settings)).font(.headline)
                            Text(model.settings.endpoint).font(.footnote).foregroundStyle(AgentPalette.secondaryText).textSelection(.enabled)
                        }
                    }
                    consentSection("屏幕与任务", icon: "rectangle.on.rectangle", text: "当前截图、任务、补充要求及最近行动摘要。对话会发送问题、最近的对话文字和你选中的画面。截图中可能包含其他 App 的聊天、照片、姓名或通知。")
                    consentSection("记忆与系统工具", icon: "bookmark", text: "开启使用本机记忆后，最多发送 3 条允许引用的相关记忆文字，记忆图片不会自动发送。系统工具每次单独确认；匹配的日历、提醒、联系人、照片元数据及本 App 闹钟结果可用于继续任务。")
                    consentSection("文件与翻译", icon: "doc.text", text: "发送你确认的文字、整理要求和文件格式。开启实时翻译后，会定期发送转写片段。")
                    consentSection("相机与语音", icon: "camera", text: "普通相机提问发送一张画面。连续观察提问发送最近 12 秒内最多 8 张抽样画面；另行开始连续观察后，定期发送画面、关注要求和上轮观察文字，直到停止或达到上限。本次授权不含视频流或麦克风音频；独立实时语音与说话人分段另行逐次确认。")
                    Text("所选服务的数据保存与后续使用由其隐私政策决定。自定义接口可能转发数据，请先核实。")
                        .font(.footnote).foregroundStyle(AgentPalette.secondaryText)
                    AgentHelp(title: "本机保存与访问密钥", text: "任务和行动记录保存在本机，可在设置中清除。队列任务、配置与进度也保存在本机，可在队列中导出、移除或清除。截图不写入任务历史。API Key 保存在本机钥匙串，并随请求发送给你配置的接口认证。")
                    Button("查看完整数据使用说明") { showPolicy = true }.frame(minHeight: 44)
                    Text("可在设置中撤回授权。更换接口或接收方后需重新确认。") .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                }.padding(20)
            }.navigationTitle("AI 数据使用").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 12) {
                        Button("暂不同意") { model.declineConsent(); onDecision() }.buttonStyle(AgentButtonStyle(primary: false))
                        Button("同意并继续") { model.acceptConsent(); onDecision() }.buttonStyle(AgentButtonStyle()).disabled(!model.modelReady)
                    }.padding(20).background(AgentPalette.background)
                }
        }.tint(AgentPalette.accent).agentSheetStyle().interactiveDismissDisabled()
            .sheet(isPresented: $showPolicy) { DataPolicyView() }
    }
    private func consentSection(_ title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            Text(text).font(.footnote).foregroundStyle(AgentPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

}

struct DataPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: PhoneAgentViewModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("数据使用说明").font(.title2.weight(.semibold))
                    policy("屏幕与任务", "你主动共享的屏幕用于判断下一步动作。执行任务时，截图、任务文字和最近行动摘要会发送到你选择的模型接口。停止任务后不再发起新的观察请求；已发出的请求可能已被接收。")
                    policy("服务商", "当前接收方：\(PrivacyConsent.recipient(model.settings))。接口：\(model.settings.endpoint.isEmpty ? "尚未填写" : model.settings.endpoint)。数据的保存、处理和删除方式取决于该服务的政策。请只连接你信任并已了解政策的服务。")
                    policy("本机保存", "App 保存配置、当前任务、校准数据、最多 50 个任务的行动记录及连接/校准诊断。任务历史不包含截图；实时画面仍会在共享期间保留于内存。任务历史与最多 20 项队列任务存放在受系统文件保护的本机目录，并排除 iCloud 备份。队列保存任务文字、配置、进度与已确认子任务，不含密钥、截图或待执行动作。重启后需手动核对并确认继续；清除队列不会撤销已执行操作。")
                    policy("语音与对话", "普通语音入口使用麦克风并在本机识别，不向文字模型发送麦克风音频。识别后的文字可修改；提交任务或问题时，文字会发送给所选服务。当前对话和选中的识屏画面只保留在内存中，可清空；退出进程后不恢复。连续语音对话在离开页面或进入后台时停止。")
                    policy("独立实时语音", "每次会话单独核对接收方、WSS 接口、模型、声音与独立 Key 后确认；随后持续发送原始麦克风音频，最长 5 分钟。若本次另外允许相机，仍需手动开启预览并逐张分享，最多 20 张新画面及其时间；不发送原生视频流。没有任务、屏幕共享、历史、记忆或工具动作。进入后台、离开页面、配置变化、错误或系统音频打断时结束，不自动重连。音频与图片不落盘；回复文字只在本页内存，可主动导出，其中可能包含尚未完整播放的文字，不能作为逐字录音证明。服务可能计费、保存或转发音频和图片，请核对其政策；结束无法撤回已发送的数据。")
                    policy("联网检索", "联网检索需每次单独核对并确认。可先另行确认向当前已授权模型发送本次问题、默认时间条件和当前时间，生成最多 3 项可修改的检索计划；不发送画面、语音、历史、记忆或搜索 Key，也不自动搜索。核对全部关键词与条件后可逐项执行，每项分别消耗额度；中途取消 / 失败保留已返回的来源，不自动补查。检索词、时间筛选与独立搜索 Key 发给所选 Tavily / Brave Search 服务，不附带截图、音频、对话历史或记忆。来源返回后，你另行确认基于来源回答，问题、已确认检索计划（含未完成项）、完成数量及展示的来源依据（搜索摘录或你另外选中的正文片段）才发给当前已授权模型；搜索 Key 不传给模型。来源链接由你点击打开，App 不自动下载完整网页。结果只留在该页面内存，可主动导出；页面离开或后台取消处理，已发送的数据无法撤回。服务的保留 / 删除方式按其政策核对；检索时间不代表发布时间，引用匹配不保证事实正确。搜索配置可清空 Key 后保存停用。")
                    policy("多轮研究", "与逐项核对计划的检索入口分开。你另行确认一个问题及 1–3 轮上限后，授权助手自动提出下一轮关键词、顺序检索并生成一次引用回答；最多 9 次搜索与 4 次模型请求。模型接收本次问题、轮次 / 时间条件、已尝试关键词与累计来源摘录；模型提出的关键词和各项时间条件发给搜索服务，关键词可能包含来源里的事实用语。独立搜索 Key 只发给搜索服务，模型 Key 只发给模型；不发送截图、语音、聊天历史、记忆或原文件。不自动读取正文、跟随链接或执行手机动作。每次请求可能计费，研究收束不保证事实正确或证据完整；最多使用 20 条来源，引用在本机逐字核对，语义仍需人工核对。错误 / 取消 / 后台 / 离开停止追加请求，不自动重试；保留已返回来源，不能撤回服务已收到的数据。记录只存本页内存，需主动导出；重启不自动恢复。")
                    policy("网页正文", "搜索结果可逐条确认由 Tavily 提取正文。仅发送完整来源链接（含路径和查询参数）与 Tavily Key 到固定正文接口，不使用 Brave 或模型 Key，不附带问题、画面、语音、历史或记忆。服务可能收费并保存请求；不会自动跟随页面中的其他链接，App 不直接访问该网页，也不绕过登录或访问限制。收到的提取正文只留在该页面内存，最多 120000 字、可查看 / TXT 导出，不保证网页全部内容。你另行选择连续片段（最多 12000 字）加入来源后，才可再次确认向模型发送该片段和其他展示材料；未选部分不发送。原搜索摘录保留，可恢复。正文和网页上的指令不作为操作授权；离开 / 后台取消，无法撤回服务已收到的数据。")
                    policy("文件与记录", "导入的文字、Office 基础文字、PDF/OCR 与音频文件转写先在本机处理，可编辑后再点击 AI 整理；开启实时翻译后会定期发送片段。模型收到文字和整理要求，不收到原始文件或原始音频。结构化纪要与鱼骨图也只在你点击生成时发送相同的原文和要求；每项引文在本机核对出处，内容与假设仍需人工核对。待办只是文字，不自动创建提醒。文件导出由本机生成并由你选择保存位置；JSON 与纪要文件含引用的原文片段，SVG 的说明也含这些片段。页面草稿只在内存中，需主动保存记忆或导出。OCR、语音和表格缓存值可能有误差，需核对。")
                    policy("本机录音库", "与只转写入口分开。每段录音须明确确认保存原始音频，再申请系统麦克风权限。音频与核对后的文字保存在受系统文件保护且排除 iCloud 备份的本机目录；可回听、重命名、删除、导出，或在本机转写后把文字放入工作台。最长约 10 分钟，最多 100 项 / 300 MB。录音与本机转写不自动上传音频，不在后台持续录音；页面离开 / 后台 / 系统打断会停止并尽量保存已录部分，未完成文件保留供核对恢复。只有你另行点击工作台生成或翻译，文字才发给模型。删除不撤回已导出副本、另存记忆或服务已收到的文字；说话人身份与转写内容仍需人工核对。")
                    policy("说话人分段", "可选择一段已完成的本机录音，每次单独确认接收方、独立音频接口 / 模型和录音大小后，才上传整段原音频和独立 Key；不额外附带任务、屏幕、其他录音、已有转写、姓名字段或说话人参考样本；所选录音本身的声音与信息都会发送。不超过 25 MB / 10 分钟；不自动拆分或重试，后台 / 页面离开 / 配置变化停止接收。说话人 A/B 只是该录音的服务分组，不证明身份；归属、时间和转写需回听核对，人工改名是用户注释。返回草稿只留内存；核对后主动保存的分段与服务原文字、接收方 / 模型 / 时间及本机音频校验值保存在录音目录，受文件保护且排除备份，可单独删除或随录音删除。原录音 / 本机转写不被替换；可另行导出 TXT / JSON 或把分段文字放入纪要工作台；另行生成时，选中的文字及人工标签会发给获授权文字模型，不含原音频。服务可能计费、保存或转发音频，停止及删除本机结果不撤回已发送数据。")
                    policy("系统工具", "工具默认关闭。确认读取请求并通过系统授权后，限定范围内的匹配结果会发送给所选模型服务。创建日程、提醒与本 App 闹钟需要逐项确认，工具结果会进入本机任务历史，提交回执另外保存在本机以避免同一任务重复创建。你可导出或清理回执；清理不删除系统里已创建的内容，仍有可恢复任务时不能清理。没有删除、自动发送消息或付款工具；不能访问短信、其他 App 私有数据库或时钟 App 的闹钟。")
                    policy("相机对话", "开启并授权相机后在前台预览，普通提问发送一张画面。连续视频观察模式在内存保留最近 12 秒内最多 24 张压缩样本，提问或自动观察每次发送其中按时间分布的 2–8 张画面。自动观察需另行点开始，间隔至少 15 秒，在每轮完整回复后等待，不并发追赶；自动观察本次最多 10 分钟或 40 次。错误、设置 / 授权变化、离开页面或后台时停止；停止不能撤回服务已接收的数据。关闭相机 / 模式清除样本，观察文字仅在内存保留最多 20 条，需主动保存记忆才落盘。相机不写录像、不上传视频流或音频；回答基于抽样，可能遗漏快速变化，不能视为连续逐帧视频理解。")
                    policy("本机记忆", "你主动确认保存的文字、偏好及可选画面存放在受文件保护且排除 iCloud 备份的本机目录。索引与检索在设备上完成。开启使用记忆后，相关文字会发送给已授权的 AI 服务；可单条禁用引用、删除，或清空全部。保存的图片仅用于本机查看，不自动发送。")
                    policy("访问密钥", "API Key 保存在这台设备的钥匙串中，用于向配置的接口认证。App 不把 Key 写入任务记录。你可以在模型设置中清空 Key 并保存；独立实时语音、音频分段和搜索 Key 在各自配置入口清空并保存。")
                    policy("你的选择", "你可以停止任务、结束屏幕共享、撤回 AI 数据授权，或删除任务历史及队列记录。删除本机记录不会自动删除服务商已接收的数据；需要按其政策联系接收方。需要解锁、验证码和系统权限时由你处理。")
                }.padding(20)
            }.navigationTitle("隐私与数据").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(AgentPalette.accent).agentSheetStyle()
    }
    private func policy(_ title: String, _ text: String) -> some View {
        DisclosureGroup(title) { Text(text).font(.footnote).foregroundStyle(AgentPalette.secondaryText).fixedSize(horizontal: false, vertical: true).padding(.top, 10) }.font(.subheadline.weight(.medium)).agentPanel()
    }
}
