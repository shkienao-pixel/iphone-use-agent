import SwiftUI
import UIKit
import Charts
import UniformTypeIdentifiers

struct SpreadsheetSeed: Identifiable { let id = UUID(); let title: String; let text: String }
private enum SheetEditorAlert {
    case close, remove(row: Bool), restore(WorkbookReceipt), removeSheet(UUID)
    var title: String {
        switch self { case .close: return "表格修改还未保存"; case .remove(let row): return row ? "删除最后一行？" : "删除最后一列？"; case .restore: return "恢复草稿并替换整个工作簿？"; case .removeSheet: return "删除这张工作表？" }
    }
    var message: String {
        switch self {
        case .close: return "离开会清除本页草稿。请继续编辑，点顶部“导出草稿”保存 JSON，保留原始公式与图表设置。Excel 和 CSV 导出不会保存本页编辑状态。"
        case .remove: return "该行或列的内容会被移除；公式地址不会自动调整，请重新核对引用。"
        case .restore: return "整个工作簿的未保存修改会被替换。"
        case .removeSheet: return "移除此表的单元格和图表，至少保留一张工作表；公式不会自动重写。"
        }
    }
}

struct SpreadsheetView: View {
    let seed: SpreadsheetSeed
    @Environment(\.dismiss) private var dismiss
    private enum Field: Hashable { case title, sheetName, paste }
    @FocusState private var focusedField: Field?
    private enum EditorTab: String, CaseIterable { case cells = "单元格", chart = "图表" }
    @State private var editorTab: EditorTab = .cells
    @State private var title = "表格"
    @State private var draft: SpreadsheetDraft?
    @State private var paste = ""
    @State private var selected = SheetAddress(row: 0, column: 0)
    @State private var cellText = ""
    @State private var cellFocused = false
    @State private var values: [[SheetValue]]?
    @State private var chart = SheetChartSpec()
    @State private var chartEnabled = false
    @State private var points: [SheetChartPoint] = []
    @State private var error = ""
    @State private var message = ""
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    @State private var exportType = UTType.data
    @State private var exportName = "表格"
    @State private var importing = false
    @State private var replace = false
    @State private var activeAlert: SheetEditorAlert?
    @State private var sheets: [WorkbookSheet] = []
    @State private var activeID = UUID()
    @State private var sheetName = "Sheet1"
    @State private var savedReceipt: WorkbookReceipt?
    @State private var exportReceipt: WorkbookReceipt?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Text(title).font(.title3.weight(.semibold)); Spacer(); Text(sheetName).font(.caption).foregroundStyle(.secondary) }
                    DisclosureGroup("工作簿与导入") {
                        VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("工作簿标题").font(.caption).foregroundStyle(.secondary)
                        TextField("表格标题", text: $title).agentField().focused($focusedField, equals: .title).accessibilityLabel("工作簿标题")
                    }
                    workbookControls
                    AgentHelp(title: "工作簿说明", text: "本机编辑与计算，不调用模型。公式只在这个入口执行；原工作台 Excel 导出仍按文字处理。可编辑最多 12 张工作表，支持表内和工作簿内跨表计算，每张表保存各自图表；草稿离开前请导出 JSON。")
                    DisclosureGroup("粘贴表格或恢复草稿") {
                        TextField("制表符分列，换行分行", text: $paste, axis: .vertical).lineLimit(3...10).agentField().focused($focusedField, equals: .paste)
                        Button("用粘贴内容替换当前工作表") { focusedField = nil; replace = true }.disabled(pendingCell).frame(minHeight: 44)
                        Button("导入本入口 JSON 草稿") { focusedField = nil; importing = true }.frame(minHeight: 44)
                        Text("JSON 保存整个工作簿，兼容此前单表草稿；Excel 导出全部表。CSV / SVG 仅导出当前工作表。导入普通 Office 仍只提取文字和缓存值。") .font(.caption).foregroundStyle(.secondary)
                    }
                        }.padding(.top, 12)
                    }.font(.subheadline).agentPanel()
                    if let draft {
                        Picker("编辑区域", selection: $editorTab) {
                            ForEach(EditorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).disabled(pendingCell)
                            .onChange(of: editorTab) { _, _ in focusedField = nil; cellFocused = false }
                        if editorTab == .cells {
                        Text("\(draft.rows.count) 行 × \(draft.columns) 列 · \(draft.text.count)/12000 字").font(.caption).foregroundStyle(.secondary)
                        grid(draft)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("编辑 \(selected.name)").font(.headline)
                            if pendingCell { Text("单元格修改尚未应用，先点应用再切换单元格、计算或导出。").font(.caption).foregroundStyle(.orange) }
                            SheetCellInput(text: $cellText, isFocused: $cellFocused, onApply: { if editCell() { cellFocused = false } })
                                .frame(height: 130).agentField()
                            Button("应用此单元格") { if editCell() { focusedField = nil; cellFocused = false } }.buttonStyle(AgentButtonStyle(primary: false))
                            AgentHelp(title: "支持的公式", text: "输入以 ' 开头可强制作为文字。数字用小数点；公式支持 + − × ÷、括号、%、A1 / $A$1、矩形范围，以及 SUM、AVERAGE、MIN、MAX、COUNT、ROUND。函数名用英文、逗号分隔；ROUND 位数 −6 至 6。")
                            AgentHelp(title: "引用与计算规则", text: "范围和独立引用的空格 / 文字在聚合函数中忽略；算术中的空格按 0、文字报错。支持 Sheet1!B2、'表名'!$B$2，以及 SUM('表名'!B2:B4)。表名中的单引号写成两个单引号；不支持三维范围、外部工作簿、字符串 / 日期函数或宏。重命名 / 删除表后须自行修正原公式引用。")
                        }.agentPanel()
                        HStack {
                            Button("增加一行") { resize(row: true, add: true) }.disabled(pendingCell || draft.rows.count >= 200)
                            Spacer()
                            Button("增加一列") { resize(row: false, add: true) }.disabled(pendingCell || draft.columns >= 26)
                        }.frame(minHeight: 44)
                        HStack {
                            Button("删除末行", role: .destructive) { activeAlert = .remove(row: true) }.disabled(pendingCell || draft.rows.count <= 1)
                            Spacer()
                            Button("删除末列", role: .destructive) { activeAlert = .remove(row: false) }.disabled(pendingCell || draft.columns <= 1)
                        }.frame(minHeight: 44)
                        Button("重新计算与核对") { calculate() }.buttonStyle(AgentButtonStyle()).disabled(pendingCell)
                        if let values {
                            let errors = values.enumerated().flatMap { row, cells in cells.enumerated().compactMap { column, value -> String? in if case .error(let code) = value { return "\(SheetAddress(row: row, column: column).name)：\(code)" }; return nil } }
                            if !errors.isEmpty { Text(errors.joined(separator: "\n")).foregroundStyle(.red).textSelection(.enabled) }
                            else { Text("当前单元格已计算，导出前仍需核对数值和公式。") .font(.caption).foregroundStyle(.secondary) }
                        }
                        } else {
                        Toggle("加入图表", isOn: $chartEnabled).tint(AgentPalette.accent)
                        if chartEnabled {
                            Picker("图表类型", selection: $chart.kind) { ForEach(SheetChartSpec.Kind.allCases) { Text($0.rawValue).tag($0) } }
                            Picker("标签列", selection: $chart.labelColumn) { ForEach(0..<draft.columns, id: \.self) { Text(String(UnicodeScalar(65 + $0)!)).tag($0) } }
                            Text("数值列，最多 3 列").font(.headline)
                            ForEach(0..<draft.columns, id: \.self) { column in
                                if column != chart.labelColumn {
                                    Toggle(String(UnicodeScalar(65 + column)!), isOn: Binding(get: { chart.valueColumns.contains(column) }, set: { enabled in
                                        if enabled { if chart.valueColumns.count < 3 { chart.valueColumns.append(column); chart.valueColumns.sort() } else { error = "最多选择 3 列数值" } }
                                        else { chart.valueColumns.removeAll { $0 == column } }
                                    })).tint(AgentPalette.accent)
                                }
                            }
                            Stepper("起始行：\(chart.firstRow + 1)", value: $chart.firstRow, in: 1...max(1, draft.rows.count - 1))
                            Stepper("结束行：\(chart.lastRow + 1)", value: $chart.lastRow, in: 1...max(1, draft.rows.count - 1))
                            Text("首行为表头；图表连续选择 1–60 行。不跳过空值 / 文字 / 公式错误，数值列需全部是数字。编辑图表设置后，请重新计算。") .font(.caption).foregroundStyle(.secondary)
                            if !points.isEmpty {
                                chartPreview
                                DisclosureGroup("图表数据与完整标签") {
                                    ForEach(points) { point in Text("第 \(point.row + 1) 行 · \(point.label) · \(point.name)：\(point.value)").textSelection(.enabled) }
                                }
                            }
                        }
                            Button("更新图表") { calculate() }.buttonStyle(AgentButtonStyle()).disabled(pendingCell || !chartEnabled)
                        }
                        HStack {
                            Button("导出 Excel") { export("xlsx") }.buttonStyle(AgentButtonStyle())
                            Button("导出 CSV") { export("csv") }.buttonStyle(AgentButtonStyle(primary: false))
                        }.disabled(pendingCell)
                        HStack {
                            Button("保存 JSON 草稿") { export("json") }.frame(minHeight: 44)
                            Spacer()
                            if chartEnabled { Button("导出 SVG 图表") { export("svg") }.frame(minHeight: 44) }
                        }.disabled(pendingCell)
                        AgentHelp(title: "导出格式说明", text: "Excel 导出全部工作表、数字、受支持的表内 / 跨表公式和计算缓存；每张表可有独立图表。任一表的公式 / 图表错误会阻止整个 Excel 导出，JSON 可保存待修草稿。CSV 与 SVG 只导出当前表，CSV 保护公式字符开头的文字。")
                    }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    if !message.isEmpty { AgentNotice(text: message) }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle("表格与图表").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("导出草稿") { focusedField = nil; export("json") }.disabled(pendingCell).accessibilityLabel("保存 JSON 草稿") }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { if hasUnsavedChanges { activeAlert = .close } else { dismiss() } } }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("收起键盘") { focusedField = nil; cellFocused = false }
                    }
                }
                .interactiveDismissDisabled(hasUnsavedChanges)
                .onAppear { if draft == nil { title = seed.title; paste = seed.text; do { apply(try SpreadsheetDraft(text: seed.text.isEmpty ? "项目\t数值\n\t" : seed.text)); if let currentReceipt { sheets = currentReceipt.sheets }; savedReceipt = currentReceipt } catch { self.error = error.localizedDescription } } }
                .onChange(of: chart) { _, _ in points = []; values = nil; message = "" }
                .onChange(of: chartEnabled) { _, _ in points = []; message = "" }
                .onChange(of: chart.labelColumn) { _, column in chart.valueColumns.removeAll { $0 == column } }
                .confirmationDialog("替换当前表格？未保存的修改会被替换。", isPresented: $replace) {
                    Button("替换") { do { apply(try SpreadsheetDraft(text: paste)); error = "" } catch { self.error = error.localizedDescription } }
                }
                .alert(activeAlert?.title ?? "表格", isPresented: Binding(get: { activeAlert != nil }, set: { if !$0 { activeAlert = nil } }), presenting: activeAlert) { alert in
                    switch alert {
                    case .close:
                        Button("继续编辑", role: .cancel) {}
                        Button("放弃修改", role: .destructive) { dismiss() }
                    case .remove(let row):
                        Button("取消", role: .cancel) {}
                        Button("删除", role: .destructive) { resize(row: row, add: false) }
                    case .removeSheet(let id):
                        Button("取消", role: .cancel) {}
                        Button("删除工作表", role: .destructive) { removeSheet(id) }
                    case .restore(let value):
                        Button("取消", role: .cancel) {}
                        Button("恢复") {
                            do { try restore(value); savedReceipt = value; error = "" }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                } message: { alert in Text(alert.message) }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    do {
                        let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, let size = attributes.fileSize, size > 0, size <= WorkbookReceipt.maxBytes else { throw AgentError.message("工作簿 JSON 需为 2 MB 内的普通文件") }
                        let data = try Data(contentsOf: url); guard data.count <= WorkbookReceipt.maxBytes else { throw AgentError.message("工作簿 JSON 超过 2 MB") }
                        let value = try WorkbookReceipt.decode(data); activeAlert = .restore(value)
                    } catch { self.error = error.localizedDescription }
                }
        }
                .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportName) { result in
                    switch result {
                    case .success:
                        if let exportReceipt { savedReceipt = exportReceipt }
                        message = "已导出"
                    case .failure(let failure): error = failure.localizedDescription
                    }
                    document = nil; exportReceipt = nil
                }
    }
    private var currentReceipt: WorkbookReceipt? {
        guard let draft else { return nil }
        let receipt = SheetReceipt(version: 1, title: sheetName, rows: draft.rows, chart: chart, chartEnabled: chartEnabled)
        let active = WorkbookSheet(id: activeID, name: sheetName, receipt: receipt)
        var snapshot = sheets
        if let index = snapshot.firstIndex(where: { $0.id == activeID }) { snapshot[index] = active }
        else if snapshot.isEmpty { snapshot = [active] }
        else { return nil }
        return WorkbookReceipt(version: 2, title: title, sheets: snapshot, selectedID: activeID)
    }
    private var hasUnsavedChanges: Bool {
        pendingCell || currentReceipt?.title != savedReceipt?.title || currentReceipt?.sheets != savedReceipt?.sheets
    }
    private var workbookControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("当前工作表") {
                Picker("", selection: Binding(get: { activeID }, set: { switchSheet($0) })) {
                    ForEach(sheets) { sheet in Text(sheet.id == activeID ? sheetName : sheet.name).tag(sheet.id) }
                }.pickerStyle(.menu).disabled(pendingCell)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("工作表名称").font(.caption).foregroundStyle(.secondary)
                TextField("唯一名称，最多 31 字", text: $sheetName).agentField().focused($focusedField, equals: .sheetName).accessibilityLabel("工作表名称")
            }
            Text("\(sheets.count)/12 张工作表 · 名称区分各表；切换前先应用单元格修改。表名需唯一，不含 []:*?/\\，不能首尾带单引号或命名 History。") .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("新增工作表") { addSheet() }.disabled(pendingCell || sheets.count >= 12)
                Spacer()
                Button("删除当前工作表", role: .destructive) { focusedField = nil; activeAlert = .removeSheet(activeID) }.disabled(pendingCell || sheets.count <= 1)
            }.frame(minHeight: 44)
        }
    }
    private func commitSheet() throws {
        guard !pendingCell, let value = currentReceipt else { throw AgentError.message("请先应用当前单元格修改") }
        try value.checked(); sheets = value.sheets
    }
    private func selectSheet(_ sheet: WorkbookSheet) throws {
        let value = try sheet.receipt.checked()
        activeID = sheet.id; sheetName = sheet.name; apply(value)
        chart = sheet.receipt.chart; chartEnabled = sheet.receipt.chartEnabled
        error = ""; focusedField = nil
    }
    private func switchSheet(_ id: UUID) {
        guard id != activeID else { return }
        do { try commitSheet(); guard let target = sheets.first(where: { $0.id == id }) else { return }; try selectSheet(target) }
        catch { self.error = error.localizedDescription }
    }
    private func addSheet() {
        do {
            try commitSheet(); guard sheets.count < 12 else { throw AgentError.message("最多 12 张工作表") }
            let names = Set(sheets.map { $0.name.lowercased() }); var number = 1
            while names.contains("sheet\(number)") { number += 1 }
            let name = "Sheet\(number)"
            let value = try SpreadsheetDraft(text: "项目\t数值\n\t")
            let receipt = SheetReceipt(version: 1, title: name, rows: value.rows, chart: SheetChartSpec(valueColumns: [1], lastRow: 1), chartEnabled: false)
            let item = WorkbookSheet(id: UUID(), name: name, receipt: receipt)
            sheets.append(item); try selectSheet(item); message = "已新增工作表，尚未保存工作簿"
        } catch { self.error = error.localizedDescription }
    }
    private func removeSheet(_ id: UUID) {
        do {
            try commitSheet(); guard sheets.count > 1, let index = sheets.firstIndex(where: { $0.id == id }) else { return }
            sheets.remove(at: index)
            if activeID == id { try selectSheet(sheets[min(index, sheets.count - 1)]) }
            message = "工作表已移除，尚未保存工作簿"
        } catch { self.error = error.localizedDescription }
    }
    private func restore(_ value: WorkbookReceipt) throws {
        try value.checked()
        guard let active = value.sheets.first(where: { $0.id == value.selectedID }) else { throw AgentError.message("工作簿没有当前工作表") }
        sheets = value.sheets; title = value.title; try selectSheet(active)
    }
    private var pendingCell: Bool {
        guard let draft, draft.rows.indices.contains(selected.row), (0..<draft.columns).contains(selected.column) else { return false }
        return cellText != draft.rows[selected.row][selected.column]
    }
    private func grid(_ draft: SpreadsheetDraft) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) { Text("行").frame(width: 38); ForEach(0..<draft.columns, id: \.self) { Text(String(UnicodeScalar(65 + $0)!)).font(.headline).frame(width: 120) } }
                ForEach(draft.rows.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        Text("\(row + 1)").font(.caption).frame(width: 38)
                        ForEach(0..<draft.columns, id: \.self) { column in
                            let address = SheetAddress(row: row, column: column)
                            let value = values?[row][column].display ?? draft.rows[row][column]
                            Button { selected = address; cellText = draft.rows[row][column] } label: {
                                Text(value.isEmpty ? " " : value).lineLimit(2).frame(width: 104, height: 44, alignment: .leading).padding(.horizontal, 8)
                                    .background(selected == address ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).disabled(pendingCell).accessibilityLabel("\(address.name)，\(value.isEmpty ? "空白" : value)").accessibilityHint("编辑此单元格")
                        }
                    }
                }
            }
        }.frame(height: CGFloat(min(360, max(144, (draft.rows.count + 1) * 48))))
    }
    private var chartPreview: some View {
        let labels = Dictionary(points.map { (String($0.row), $0.label) }, uniquingKeysWith: { first, _ in first })
        return ScrollView(.horizontal) {
            Chart(points) { point in
                if chart.kind == .column {
                    BarMark(x: .value("行", String(point.row)), y: .value("数值", point.value)).foregroundStyle(by: .value("系列", point.name)).position(by: .value("系列", point.name))
                } else {
                    LineMark(x: .value("行", String(point.row)), y: .value("数值", point.value)).foregroundStyle(by: .value("系列", point.name)).symbol(by: .value("系列", point.name))
                }
            }.chartXAxis { AxisMarks { value in AxisGridLine(); AxisTick(); AxisValueLabel { if let key = value.as(String.self) { Text(labels[key] ?? key).font(.caption2).frame(width: 64) } } } }
                .frame(width: CGFloat(max(320, labels.count * 80)), height: 340).padding(.bottom, 12)
        }.accessibilityLabel("\(chart.kind.rawValue)，完整数值和标签在图表数据中")
    }
    private func apply(_ value: SpreadsheetDraft) {
        draft = value; selected = SheetAddress(row: 0, column: 0); cellText = value.rows[0][0]; values = nil; points = []; message = ""
        chart = SheetChartSpec(valueColumns: value.columns > 1 ? [1] : [], lastRow: max(1, min(4, value.rows.count - 1)))
    }
    private func editCell() -> Bool {
        guard var value = draft else { return false }
        value.rows[selected.row][selected.column] = cellText
        do { try value.validate(); draft = value; values = nil; points = []; message = "已应用，请重新计算"; error = ""; return true } catch { self.error = error.localizedDescription; return false }
    }
    private func resize(row: Bool, add: Bool) {
        guard var value = draft else { return }
        if row { if add { value.rows.append(Array(repeating: "", count: value.columns)) } else { value.rows.removeLast() } }
        else { value.rows = value.rows.map { var cells = $0; if add { cells.append("") } else { cells.removeLast() }; return cells } }
        do { try value.validate(); apply(value); message = "表格尺寸已更新，图表范围已重置，请核对公式地址"; error = "" } catch { self.error = error.localizedDescription }
    }
    private func currentValues() throws -> [[SheetValue]] {
        guard let workbook = currentReceipt, let index = workbook.sheets.firstIndex(where: { $0.id == activeID }) else { throw AgentError.message("没有可计算的工作表") }
        return try workbook.calculated()[index]
    }
    private func calculate() {
        guard let draft else { return }
        do { let result = try currentValues(); values = result; points = chartEnabled ? try draft.chart(chart, values: result) : []; error = ""; message = "已重新计算" } catch { points = []; self.error = error.localizedDescription; message = "" }
    }
    private func export(_ ext: String) {
        guard let draft else { return }
        do {
            let data: Data
            var snapshot: WorkbookReceipt?
            switch ext {
            case "xlsx":
                guard let workbook = currentReceipt else { throw AgentError.message("没有可导出的工作簿") }; data = try SpreadsheetFiles.excel(workbook)
            case "csv": data = try SpreadsheetFiles.csv(draft, values: currentValues())
            case "svg": data = try SpreadsheetFiles.svg(draft, title: title, chart: chart, values: currentValues())
            default:
                guard let receipt = currentReceipt else { throw AgentError.message("没有可保存的工作簿") }
                try receipt.checked(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; data = try encoder.encode(receipt)
                guard data.count <= WorkbookReceipt.maxBytes else { throw AgentError.message("工作簿 JSON 超过 2 MB") }; snapshot = receipt
            }
            exportReceipt = snapshot; document = ArtifactDocument(data: data); exportType = UTType(filenameExtension: ext) ?? .data; exportName = ArtifactFiles.filename(title) + "." + ext; exporting = true; error = ""; message = ""
        } catch { self.error = error.localizedDescription; message = "" }
    }
}

// Formula punctuation must remain literal even when system Smart Punctuation is enabled.
private struct SheetCellInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onApply: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear; view.textColor = .label
        view.font = .preferredFont(forTextStyle: .body); view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.smartQuotesType = .no; view.smartDashesType = .no
        view.keyboardType = .asciiCapable
        view.autocorrectionType = .no; view.spellCheckingType = .no; view.autocapitalizationType = .none
        view.accessibilityLabel = "单元格内容"
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        toolbar.items = [.init(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                         .init(title: "应用单元格", style: .plain, target: context.coordinator, action: #selector(Coordinator.applyCell)),
                         .init(title: "收起键盘", style: .plain, target: context.coordinator, action: #selector(Coordinator.hideKeyboard))]
        view.inputAccessoryView = toolbar; context.coordinator.view = view
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text, view.markedTextRange == nil { view.text = text }
        if !isFocused, view.isFirstResponder { view.resignFirstResponder() }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SheetCellInput
        weak var view: UITextView?
        init(_ parent: SheetCellInput) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) { parent.text = view.text }
        func textViewDidBeginEditing(_ view: UITextView) { if !parent.isFocused { parent.isFocused = true } }
        func textViewDidEndEditing(_ view: UITextView) { if parent.isFocused { parent.isFocused = false } }
        @objc func applyCell() { parent.onApply() }
        @objc func hideKeyboard() { parent.isFocused = false; view?.resignFirstResponder() }
    }
}
