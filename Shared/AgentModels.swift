import Foundation
import CoreGraphics

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

struct AgentSettings: Codable {
    var endpoint = "https://api.openai.com/v1/chat/completions"
    var model = "gpt-4.1-mini"
    var jsonMode = true
    var legacyTokenLimit = false
    var maxSteps = 25
    var startDelay = 5.0
    var stepInterval = 1.0
    var previewOnly = false
    var confirmEachStep = false
    var imageMaxSide = 1280
    // Optional for backward-compatible settings decoding; confirmation is per accessory.
    var homeMappedPeripheralID: String? = nil
    var providerName: String? = nil
    // Optional so existing saved settings keep their endpoint/key association.
    var maxResponseTokens: Int? = nil
    var autoPiPOnExit: Bool? = nil
    var spokenFeedback: Bool? = nil
    var useMemories: Bool? = nil
    var systemToolsEnabled: Bool? = nil
    var toolsOnly: Bool? = nil
    var liveTaskStatus: Bool? = nil
    var responseTokenLimit: Int { max(1024, min(16384, maxResponseTokens ?? 4096)) }
    func homeButtonIsMapped(to device: String?) -> Bool {
        guard let device else { return false }
        return homeMappedPeripheralID == device
    }
}

// Only response-format failures are eligible for bounded re-observation.
// Never include raw model text, provider errors or screenshot data here.
struct ModelResponseIssue: LocalizedError {
    enum Kind { case length, invalidAction, emptyAction, incompleteEnvelope }
    var kind: Kind
    var tokenLimit: Int
    var responseBytes: Int
    var completionTokens: Int?
    var reasoningTokens: Int?
    var actionProblem: String? = nil
    var diagnostic: String {
        let code: String
        switch kind {
        case .length: code = "output_length"
        case .invalidAction: code = "invalid_action_json"
        case .emptyAction: code = "empty_action"
        case .incompleteEnvelope: code = "invalid_response_json"
        }
        return "\(code) · 上限 \(tokenLimit) · 响应 \(responseBytes) 字节" +
            (completionTokens.map { " · 输出 Token \($0)" } ?? "") +
            (reasoningTokens.map { " · 推理 Token \($0)" } ?? "") +
            (actionProblem.map { " · " + $0 } ?? "")
    }
    var errorDescription: String? {
        switch kind {
        case .length: return "模型回复达到输出长度上限，动作已丢弃。可在设置中提高回复 Token 上限，或更换模型"
        case .invalidAction: return actionProblem.map { "\($0)。动作已丢弃，请检查模型与 JSON 模式设置" } ?? "模型动作 JSON 格式或参数无效，动作已丢弃。请检查模型与 JSON 模式设置"
        case .emptyAction: return "模型未返回动作内容。请检查模型是否支持图像输入和当前接口格式"
        case .incompleteEnvelope: return "接口响应不是完整有效的 JSON，动作已丢弃。请检查所配置服务商的回复格式"
        }
    }
}

struct PointerCalibration: Codable {
    var screenWidth: Double
    var screenHeight: Double
    var gainX: Double
    var gainY: Double
    var originX: Double
    var originY: Double
    var validationError: Double
    var peripheralID: String
    var createdAt: Date
    // Movement profiles have different pointer acceleration and need their own fit.
    var movementVersion: Int? = nil
    var crossX: Double? = nil
    var crossY: Double? = nil
    var calibrationVersion: Int? = nil
    var fitSampleCount: Int? = nil
    var validationSampleCount: Int? = nil
    var validationRMS: Double? = nil
    var returnDrift: Double? = nil
    var fit: PointerFit {
        PointerFit(gainX: gainX, gainY: gainY, originX: originX, originY: originY,
                   crossX: crossX ?? 0, crossY: crossY ?? 0)
    }
    var usable: Bool {
        movementVersion == PointerMotion.profileVersion &&
        calibrationVersion == CalibrationSolver.version &&
        (fitSampleCount ?? 0) >= 7 && (validationSampleCount ?? 0) >= CalibrationSolver.validationTargets.count &&
        validationRMS.map { $0.isFinite && (0...CalibrationSolver.maxValidationRMS).contains($0) } == true &&
        returnDrift.map { $0.isFinite && (0...CalibrationSolver.maxReturnDrift).contains($0) } == true &&
        fit.isInvertible &&
        [screenWidth, screenHeight, gainX, gainY, originX, originY, validationError].allSatisfy(\.isFinite) &&
        screenWidth > 0 && screenHeight > 0 && gainX > 0.1 && gainY > 0.1 &&
        (0...CalibrationSolver.maxValidationError).contains(validationError)
    }
}

enum PointerMotion {
    static let profileVersion = 6
    static let reportDistance = 8.0
    static let reportInterval = 0.040
    struct Step {
        var x: Int
        var y: Int
        var interval: Double
    }
    static func reportCount(x: Int, y: Int, minimumDuration: Double? = nil) -> Int {
        let distance = Int(ceil(hypot(Double(x), Double(y)) / reportDistance))
        let duration: Int
        if let minimumDuration, minimumDuration.isFinite, minimumDuration > 0 {
            duration = Int(ceil(min(10, minimumDuration) / reportInterval))
        } else { duration = 0 }
        return max(distance, duration)
    }
    /// A straight segment with cumulative rounding, so both axes arrive together
    /// and the integer reports sum exactly to the requested displacement.
    static func steps(x: Int, y: Int, minimumDuration: Double? = nil) -> [Step] {
        let count = reportCount(x: x, y: y, minimumDuration: minimumDuration)
        guard count > 0 else { return [] }
        var result: [Step] = []
        var sentX = 0, sentY = 0
        for index in 1...count {
            let progress = Double(index) / Double(count)
            let nextX = Int((Double(x) * progress).rounded())
            let nextY = Int((Double(y) * progress).rounded())
            // Equal progress at a fixed cadence: both axes travel together without
            // the previous fast-ends/slow-middle speed curve.
            result.append(Step(x: nextX - sentX, y: nextY - sentY,
                               interval: reportInterval))
            sentX = nextX; sentY = nextY
        }
        return result
    }
}

/// The relative-pointer model: screen point = origin + units * gain, measured from
/// the homed corner. `PointerFit` and `CalibrationSolver` hold the pure math so the
/// offline tests can exercise it without a phone or an accessory.
struct PointerFit: Equatable {
    var gainX: Double
    var gainY: Double
    var originX: Double
    var originY: Double
    var crossX = 0.0
    var crossY = 0.0
    var isInvertible: Bool {
        [gainX, gainY, originX, originY, crossX, crossY].allSatisfy(\.isFinite) &&
        gainX > 0 && gainY > 0 && gainX * gainY - crossX * crossY > gainX * gainY * 0.75
    }

    func units(x: Double, y: Double) -> (x: Int, y: Int) {
        let dx = x - originX, dy = y - originY
        let determinant = gainX * gainY - crossX * crossY
        return (Int(((gainY * dx - crossX * dy) / determinant).rounded()),
                Int(((gainX * dy - crossY * dx) / determinant).rounded()))
    }
    func point(units u: CGPoint) -> CGPoint {
        CGPoint(x: originX + Double(u.x) * gainX + Double(u.y) * crossX,
                y: originY + Double(u.y) * gainY + Double(u.x) * crossY)
    }
    func applying(to c: PointerCalibration) -> PointerCalibration {
        var copy = c
        copy.gainX = gainX; copy.gainY = gainY; copy.originX = originX; copy.originY = originY
        copy.crossX = crossX; copy.crossY = crossY
        return copy
    }
}

enum CalibrationSolver {
    /// Acceptance threshold for the validation taps, shared by the model and `usable`.
    static let version = 2
    static let maxValidationError = 8.0
    static let maxValidationRMS = 6.0
    static let maxReturnDrift = 8.0
    // Interleaved grid order exercises all quadrants; each target homes first.
    static let fitTargets: [CGPoint] = [
        CGPoint(x: 0.18, y: 0.20), CGPoint(x: 0.82, y: 0.80), CGPoint(x: 0.82, y: 0.20),
        CGPoint(x: 0.18, y: 0.80), CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.18, y: 0.50),
        CGPoint(x: 0.82, y: 0.50), CGPoint(x: 0.50, y: 0.20), CGPoint(x: 0.50, y: 0.80)
    ]
    // Held-out positions, plus repeated center returns after independent homing.
    static let validationTargets: [CGPoint] = [
        CGPoint(x: 0.25, y: 0.28), CGPoint(x: 0.75, y: 0.72), CGPoint(x: 0.25, y: 0.72),
        CGPoint(x: 0.75, y: 0.28), CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.50, y: 0.82),
        CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.18, y: 0.50), CGPoint(x: 0.50, y: 0.50)
    ]
    static var totalSteps: Int { 3 + fitTargets.count + validationTargets.count }
    static let gainRange = 0.15...8.0
    /// The three coarse samples, in units from the homed corner.
    static let sampleA = CGPoint(x: 40, y: 80)
    static let sampleB = CGPoint(x: 80, y: 80)
    static let sampleC = CGPoint(x: 40, y: 120)
    /// Shortest baseline a refit will trust, in units.
    static let minimumRefitSpan = 40.0

    /// Origin and gain from the three coarse taps. Nil when the movement was not
    /// clean enough to measure (pointer pinned to an edge, or one axis did not move).
    static func coarse(a: CGPoint, b: CGPoint, c: CGPoint) -> PointerFit? {
        let gainX = Double(b.x - a.x) / Double(sampleB.x - sampleA.x)
        let gainY = Double(c.y - a.y) / Double(sampleC.y - sampleA.y)
        guard gainRange.contains(gainX), gainRange.contains(gainY),
              abs(Double(b.y - a.y)) < 8, abs(Double(c.x - a.x)) < 8 else { return nil }
        return PointerFit(gainX: gainX, gainY: gainY,
                          originX: Double(a.x) - Double(sampleA.x) * gainX,
                          originY: Double(a.y) - Double(sampleA.y) * gainY)
    }

    /// One measurement: the units that were requested from the homed corner, and
    /// the screen point the pointer actually reached.
    struct Measurement {
        var units: CGPoint
        var actual: CGPoint
    }

    struct GridFit {
        var fit: PointerFit
        var sampleCount: Int
        var rms: Double
    }

    /// Six-parameter affine fit, with robust weights for at most two stray taps.
    /// Validation taps are held out and never used to improve this fit.
    static func gridRefit(_ measurements: [Measurement], fallback: PointerFit) -> GridFit? {
        guard measurements.count >= 7, measurements.allSatisfy({
            [$0.units.x, $0.units.y, $0.actual.x, $0.actual.y].allSatisfy { $0.isFinite }
        }) else { return nil }
        func solve(_ values: [Measurement], weights: [Double]) -> PointerFit? {
            let xs = values.map { Double($0.units.x) }, ys = values.map { Double($0.units.y) }
            let meanX = xs.reduce(0, +) / Double(xs.count), meanY = ys.reduce(0, +) / Double(ys.count)
            let spanX = xs.max()! - xs.min()!, spanY = ys.max()! - ys.min()!
            guard spanX >= minimumRefitSpan, spanY >= minimumRefitSpan else { return nil }
            var normal = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
            var bx = [0.0, 0.0, 0.0], by = bx
            for (i, value) in values.enumerated() {
                let row = [1.0, (xs[i] - meanX) / spanX, (ys[i] - meanY) / spanY]
                for a in 0..<3 {
                    bx[a] += weights[i] * row[a] * Double(value.actual.x)
                    by[a] += weights[i] * row[a] * Double(value.actual.y)
                    for b in 0..<3 { normal[a][b] += weights[i] * row[a] * row[b] }
                }
            }
            func coefficients(_ rhs: [Double]) -> [Double]? {
                var a = normal.enumerated().map { $0.element + [rhs[$0.offset]] }
                for column in 0..<3 {
                    let pivot = (column..<3).max { abs(a[$0][column]) < abs(a[$1][column]) }!
                    guard abs(a[pivot][column]) > 1e-8 else { return nil }
                    if pivot != column { a.swapAt(pivot, column) }
                    let scale = a[column][column]
                    for j in column...3 { a[column][j] /= scale }
                    for row in 0..<3 where row != column {
                        let factor = a[row][column]
                        for j in column...3 { a[row][j] -= factor * a[column][j] }
                    }
                }
                let result = a.map { $0[3] }
                return result.allSatisfy(\.isFinite) ? result : nil
            }
            guard let x = coefficients(bx), let y = coefficients(by) else { return nil }
            return PointerFit(gainX: x[1] / spanX, gainY: y[2] / spanY,
                originX: x[0] - x[1] * meanX / spanX - x[2] * meanY / spanY,
                originY: y[0] - y[1] * meanX / spanX - y[2] * meanY / spanY,
                crossX: x[2] / spanY, crossY: y[1] / spanX)
        }
        func errors(_ fit: PointerFit, _ values: [Measurement]) -> [Double] {
            values.map { let p = fit.point(units: $0.units)
                return hypot(Double(p.x - $0.actual.x), Double(p.y - $0.actual.y)) }
        }
        var weights = Array(repeating: 1.0, count: measurements.count)
        var fitted: PointerFit?
        for _ in 0..<4 {
            guard let fit = solve(measurements, weights: weights) else { return nil }
            fitted = fit
            let residuals = errors(fit, measurements)
            let median = residuals.sorted()[residuals.count / 2]
            let cutoff = max(3, median * 1.5)
            weights = residuals.map { $0 <= cutoff ? 1 : cutoff / $0 }
        }
        guard let robust = fitted else { return nil }
        let residuals = errors(robust, measurements)
        let cutoff = max(8, min(20, residuals.sorted()[residuals.count / 2] * 3))
        let inliers = zip(measurements, residuals).filter { $0.1 <= cutoff }.map { $0.0 }
        guard inliers.count >= 7, measurements.count - inliers.count <= 2,
              let fit = solve(inliers, weights: Array(repeating: 1, count: inliers.count)),
              fit.isInvertible, gainRange.contains(fit.gainX), gainRange.contains(fit.gainY),
              (fallback.gainX / 2...fallback.gainX * 2).contains(fit.gainX),
              (fallback.gainY / 2...fallback.gainY * 2).contains(fit.gainY),
              abs(fit.crossX) <= fit.gainX * 0.35, abs(fit.crossY) <= fit.gainY * 0.35 else { return nil }
        let remaining = errors(fit, inliers)
        let rms = sqrt(remaining.reduce(0) { $0 + $1 * $1 } / Double(remaining.count))
        guard rms.isFinite, rms <= 12 else { return nil }
        return GridFit(fit: fit, sampleCount: inliers.count, rms: rms)
    }

    /// Least-squares refit of gain and origin over the measured working range.
    ///
    /// The coarse fit extrapolates the origin from a 40-unit move, so any curvature
    /// in the phone's pointer response (acceleration, report batching) shows up as a
    /// growing error at the far end of the screen. Fitting a line through real
    /// measurements taken across that range removes the systematic part.
    static func refit(_ measurements: [Measurement], fallback: PointerFit) -> PointerFit? {
        guard measurements.count >= 2 else { return nil }
        func line(_ pairs: [(u: Double, p: Double)], previousGain: Double) -> (gain: Double, origin: Double)? {
            let us = pairs.map(\.u), ps = pairs.map(\.p)
            guard let minU = us.min(), let maxU = us.max(), maxU - minU >= minimumRefitSpan else { return nil }
            let meanU = us.reduce(0, +) / Double(us.count), meanP = ps.reduce(0, +) / Double(ps.count)
            let variance = zip(us, ps).reduce(0.0) { $0 + ($1.0 - meanU) * ($1.0 - meanU) }
            guard variance > 0 else { return nil }
            let covariance = zip(us, ps).reduce(0.0) { $0 + ($1.0 - meanU) * ($1.1 - meanP) }
            let gain = covariance / variance
            guard gain.isFinite, gainRange.contains(gain) else { return nil }
            // Reject a refit that disagrees wildly with the coarse measurement it replaces.
            guard (previousGain / 2...previousGain * 2).contains(gain) else { return nil }
            return (gain, meanP - gain * meanU)
        }
        let xs = measurements.map { (u: Double($0.units.x), p: Double($0.actual.x)) }
        let ys = measurements.map { (u: Double($0.units.y), p: Double($0.actual.y)) }
        guard let x = line(xs, previousGain: fallback.gainX),
              let y = line(ys, previousGain: fallback.gainY) else {
            return nil
        }
        return PointerFit(gainX: x.gain, gainY: y.gain, originX: x.origin, originY: y.origin)
    }
}


struct AgentAction: Codable, Equatable {
    enum Kind: String, Codable { case tap, long_press, drag, scroll, type, press_key, wait, finish, ask_user, system_tool, complete_subtask, phone_tool }
    var kind: Kind
    var x: Double?
    var y: Double?
    var x2: Double?
    var y2: Double?
    var text: String?
    var amount: Int?
    var seconds: Double?
    var reason: String

    // JSON mode alone does not constrain field names or types.
    static var responseFormat: [String: Any] {
        let properties: [String: Any] = [
            "kind": ["type": "string", "enum": ["tap", "long_press", "drag", "scroll", "type", "press_key", "wait", "finish", "ask_user", "system_tool", "complete_subtask", "phone_tool"]],
            "x": ["type": ["number", "null"]], "y": ["type": ["number", "null"]],
            "x2": ["type": ["number", "null"]], "y2": ["type": ["number", "null"]],
            "text": ["type": ["string", "null"]], "amount": ["type": ["integer", "null"]],
            "seconds": ["type": ["number", "null"]], "reason": ["type": "string"]
        ]
        return ["type": "json_schema", "json_schema": ["name": "phone_agent_action", "strict": true,
            "schema": ["type": "object", "additionalProperties": false, "properties": properties,
                       "required": ["kind", "x", "y", "x2", "y2", "text", "amount", "seconds", "reason"]]]]
    }

    func validate() throws {
        guard reason.count <= 1600, (text?.count ?? 0) <= ([Kind.system_tool, .phone_tool].contains(kind) ? 4000 : 500) else { throw AgentError.message("模型动作过长") }
        func point(_ a: Double?, _ b: Double?) -> Bool {
            guard let a, let b else { return false }
            return a.isFinite && b.isFinite && (0...1).contains(a) && (0...1).contains(b)
        }
        if [.tap, .long_press, .drag].contains(kind), !point(x, y) { throw AgentError.message("模型返回无效坐标") }
        if kind == .drag && !point(x2, y2) { throw AgentError.message("拖动终点无效") }
        if let seconds, !seconds.isFinite || !(0...10).contains(seconds) { throw AgentError.message("动作等待时间超出范围") }
        if kind == .scroll, let amount, !(-20...20).contains(amount) { throw AgentError.message("滚动量超出范围") }
        if kind == .complete_subtask { guard UUID(uuidString: text ?? "") != nil else { throw AgentError.message("子任务缺少有效 ID") } }
        if kind == .system_tool { _ = try SystemToolRequest.decode(text) }
        if kind == .phone_tool { _ = try PhoneHarnessRequest.decode(text) }
        if kind == .scroll && amount == nil { throw AgentError.message("滚动动作缺少 amount") }
        if [.type, .press_key].contains(kind), text?.isEmpty != false { throw AgentError.message("输入动作缺少 text") }
    }
    var label: String {
        switch kind {
        case .tap: return "点击"
        case .long_press: return "长按"
        case .drag: return "拖动"
        case .scroll: return "滚动 \(amount ?? 0)"
        case .type: return "输入文字"
        case .press_key: return "按键 \(text ?? "")"
        case .wait: return "等待"
        case .finish: return "完成"
        case .ask_user: return "需要你的操作"
        case .complete_subtask: return "确认子任务结果"
        case .phone_tool: return (try? PhoneHarnessRequest.decode(text).label) ?? "手机工具"
        case .system_tool: return (try? SystemToolRequest.decode(text).operation.label) ?? "系统工具"
        }
    }
    static func decodeResponse(_ value: String) throws -> AgentAction {
        var s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            var lines = s.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            s = lines.joined(separator: "\n")
        }
        guard let data = s.data(using: .utf8) else { throw AgentError.message("模型没有返回 JSON") }
        // Some compatible providers quote numeric values. Accept only finite,
        // exact numbers; never repair coordinates or invent an action.
        var normalized = data
        if var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["x", "y", "x2", "y2", "amount", "seconds"] {
                if let value = object[key] as? String, let number = Double(value), number.isFinite {
                    if key == "amount" {
                        guard let integer = Int(exactly: number) else { throw AgentError.message("模型动作 amount 必须是整数") }
                        object[key] = integer
                    } else { object[key] = number }
                }
            }
            normalized = try JSONSerialization.data(withJSONObject: object)
        }
        let action: AgentAction
        do { action = try JSONDecoder().decode(AgentAction.self, from: normalized) }
        catch let error as DecodingError { throw ModelDecodingIssue.message(error, stage: "模型动作") }
        try action.validate()
        return action
    }
}

enum ModelDecodingIssue {
    static func message(_ error: DecodingError, stage: String) -> AgentError {
        let known = Set(["kind", "x", "y", "x2", "y2", "text", "amount", "seconds", "reason", "choices", "message", "content", "refusal", "finish_reason"])
        func field(_ path: [CodingKey]) -> String {
            path.map(\.stringValue).filter { known.contains($0) }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            let name = field(context.codingPath + [key])
            return .message("\(stage)缺少必要字段\(name.isEmpty ? "" : "：" + name)。请检查接口格式和模型配置")
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let name = field(context.codingPath)
            return .message("\(stage)字段类型错误\(name.isEmpty ? "" : "：" + name)。坐标和时间需为数字，amount 需为整数")
        case .dataCorrupted(let context):
            let name = field(context.codingPath)
            return .message("\(stage)不是完整有效的 JSON\(name.isEmpty ? "" : "，请检查 " + name)。已停止执行")
        @unknown default: return .message("\(stage)格式无法解析，已停止执行")
        }
    }
}

struct AgentLogEntry: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var step: Int
    var title: String
    var detail: String
}
