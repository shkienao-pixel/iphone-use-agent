import SwiftUI
import UIKit

@MainActor
final class CalibrationModel: ObservableObject {
    @Published var text = "21 步自动测量，开始后请勿触碰屏幕并保持竖屏"
    @Published var busy = false
    @Published var finished = false
    @Published var error = ""
    @Published var markers: [CGPoint] = []
    @Published var target: CGPoint?
    @Published var latestPoint: CGPoint?
    @Published var completedSteps = 0
    @Published var summary = ""
    private var waiter: CheckedContinuation<CGPoint, Error>?
    private var waiterToken: UUID?
    private var waitTimeout: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var session = UUID()
    private var diagnosticLines: [String] = []
    let executor: MouseExecutor
    var size = CGSize.zero
    var onSaved: (() -> Void)?
    init(executor: MouseExecutor) { self.executor = executor }
    private func record(_ message: String) {
        diagnosticLines.append("\(Date().ISO8601Format()) \(message)")
        let file = URL.documentsDirectory.appendingPathComponent("calibration-diagnostics.log")
        try? diagnosticLines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    private func finishWait(_ token: UUID, result: Result<CGPoint, Error>) {
        guard waiterToken == token, let continuation = waiter else { return }
        waiter = nil; waiterToken = nil; waitTimeout?.cancel(); waitTimeout = nil
        continuation.resume(with: result)
    }
    func receive(_ point: CGPoint) {
        guard let token = waiterToken else { return }
        latestPoint = point; markers.append(point)
        finishWait(token, result: .success(point))
    }
    func cancel() {
        guard busy else { return }
        session = UUID(); task?.cancel()
        if let token = waiterToken { finishWait(token, result: .failure(CancellationError())) }
        text = "正在结束校准…"
        // The owned task releases input before clearing the shared busy flag.
    }
    private func waitPoint() async throws -> CGPoint {
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiter = continuation; waiterToken = token
                waitTimeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                    self?.finishWait(token, result: .failure(AgentError.message("未收到校准点击，请检查辅助触控左键映射是否为单点触控")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishWait(token, result: .failure(CancellationError()))
            }
        }
    }
    private func probe() async throws -> CGPoint {
        try await executor.sleep(0.18)
        async let point = waitPoint()
        try await executor.sleep(0.08)
        try await executor.click()
        return try await point
    }
    private func checkSession(_ token: UUID, screen: CGSize, connection: UUID, device: String) throws {
        try Task.checkCancellation()
        guard token == session else { throw CancellationError() }
        guard executor.ble.ready, executor.ble.selectedID == device,
              executor.ble.pointerConnectionGeneration == connection else {
            throw AgentError.message("鼠标连接已变化，请重新校准")
        }
        guard abs(size.width - screen.width) < 1, abs(size.height - screen.height) < 1 else {
            throw AgentError.message("校准时屏幕发生旋转，请恢复竖屏后重试")
        }
    }
    private func checkPoint(_ point: CGPoint, screen: CGSize) throws {
        guard point.x.isFinite, point.y.isFinite,
              point.x > 12, point.x < screen.width - 12,
              point.y > 12, point.y < screen.height - 12 else {
            throw AgentError.message("校准点到达屏幕边缘，无法测量。请降低辅助触控跟踪速度；若开启吸附到项目，可关闭后重试")
        }
    }
    func start() {
        guard !busy, !executor.calibrationInProgress else { return }
        guard executor.ble.bufferedMotionReady else {
            error = "请连接已升级的板端匀速移动固件，再开始校准"; return
        }
        guard executor.ble.ready, size.width > 0, size.height > size.width,
              let device = executor.ble.selectedID else {
            error = "请先连接辅助触控鼠标，并保持竖屏"; return
        }
        let screen = size, connection = executor.ble.pointerConnectionGeneration
        let token = UUID(); session = token
        executor.calibrationInProgress = true
        busy = true; finished = false; error = ""; markers = []; target = nil; latestPoint = nil
        completedSteps = 0; summary = ""; diagnosticLines = []
        record("Calibration version=\(CalibrationSolver.version) motionProfile=\(PointerMotion.profileVersion) screen=\(screen.width)x\(screen.height)")
        task = Task {
            do {
                var coarsePoints: [CGPoint] = []
                for (index, units) in [CalibrationSolver.sampleA, CalibrationSolver.sampleB, CalibrationSolver.sampleC].enumerated() {
                    text = "校准 \(index + 1)/\(CalibrationSolver.totalSteps)：基础位移测量"
                    try await executor.homePointer()
                    try await executor.movePositionUnits(x: Int(units.x), y: Int(units.y))
                    let actual = try await probe()
                    try checkSession(token, screen: screen, connection: connection, device: device)
                    try checkPoint(actual, screen: screen)
                    coarsePoints.append(actual); completedSteps += 1
                    record("Coarse sample units=(\(units.x),\(units.y)) actual=(\(actual.x),\(actual.y))")
                }
                guard let coarse = CalibrationSolver.coarse(a: coarsePoints[0], b: coarsePoints[1], c: coarsePoints[2]) else {
                    throw AgentError.message("基础位移不稳定，请固定指针速度、保持竖屏后重试；若开启吸附到项目，可关闭后校准")
                }
                record("Coarse fit gain=(\(coarse.gainX),\(coarse.gainY)) origin=(\(coarse.originX),\(coarse.originY))")
                // Work with local fits. Active/saved calibration is replaced only after validation.
                var measurements: [CalibrationSolver.Measurement] = []
                for (index, normalized) in CalibrationSolver.fitTargets.enumerated() {
                    text = "校准 \(index + 4)/\(CalibrationSolver.totalSteps)：九宫格采样 \(index + 1)/9"
                    let desired = CGPoint(x: screen.width * normalized.x, y: screen.height * normalized.y)
                    target = desired; latestPoint = nil
                    let requested = coarse.units(x: Double(desired.x), y: Double(desired.y))
                    let units = try await executor.moveToPositionUnits(x: requested.x, y: requested.y)
                    let actual = try await probe()
                    try checkSession(token, screen: screen, connection: connection, device: device)
                    try checkPoint(actual, screen: screen)
                    measurements.append(.init(units: units, actual: actual)); completedSteps += 1
                    record("Grid units=(\(units.x),\(units.y)) actual=(\(actual.x),\(actual.y))")
                }
                guard let grid = CalibrationSolver.gridRefit(measurements, fallback: coarse) else {
                    throw AgentError.message("九宫格测量不一致，无法建立可靠定位。请勿触碰屏幕；若开启吸附到项目，可关闭后重试")
                }
                let fit = grid.fit
                record("Grid fit samples=\(grid.sampleCount) rms=\(grid.rms) gain=(\(fit.gainX),\(fit.gainY)) cross=(\(fit.crossX),\(fit.crossY)) origin=(\(fit.originX),\(fit.originY))")
                var errors: [Double] = [], centers: [CGPoint] = []
                // Each validation target homes first, exactly as task positioning does.
                for (index, normalized) in CalibrationSolver.validationTargets.enumerated() {
                    text = "校准 \(index + 13)/\(CalibrationSolver.totalSteps)：独立验证 \(index + 1)/9"
                    let desired = CGPoint(x: screen.width * normalized.x, y: screen.height * normalized.y)
                    target = desired; latestPoint = nil
                    let units = fit.units(x: Double(desired.x), y: Double(desired.y))
                    try await executor.moveToPositionUnits(x: units.x, y: units.y)
                    let actual = try await probe()
                    try checkSession(token, screen: screen, connection: connection, device: device)
                    try checkPoint(actual, screen: screen)
                    let dx = Double(actual.x - desired.x), dy = Double(actual.y - desired.y)
                    let delta = hypot(dx, dy)
                    errors.append(delta); completedSteps += 1
                    if normalized == CGPoint(x: 0.5, y: 0.5) { centers.append(actual) }
                    record("Validation desired=(\(desired.x),\(desired.y)) actual=(\(actual.x),\(actual.y)) dx=\(dx) dy=\(dy) error=\(delta)")
                }
                let worst = errors.max() ?? .infinity
                let rms = sqrt(errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count))
                var drift = 0.0
                for a in centers { for b in centers { drift = max(drift, hypot(Double(a.x - b.x), Double(a.y - b.y))) } }
                summary = String(format: "最大误差 %.1f 点 · RMS %.1f 点\n往返漂移 %.1f 点", worst, rms, drift)
                record("Validation maximum=\(worst) rms=\(rms) centerDrift=\(drift)")
                guard worst <= CalibrationSolver.maxValidationError,
                      rms <= CalibrationSolver.maxValidationRMS, drift <= CalibrationSolver.maxReturnDrift else {
                    throw AgentError.message("验证未达标：最大误差需 ≤8 点、RMS ≤6 点、往返漂移 ≤8 点。若开启吸附到项目，建议关闭后重试；同时保持竖屏和固定跟踪速度。诊断数据已保存")
                }
                try checkSession(token, screen: screen, connection: connection, device: device)
                let final = PointerCalibration(screenWidth: Double(screen.width), screenHeight: Double(screen.height),
                    gainX: fit.gainX, gainY: fit.gainY, originX: fit.originX, originY: fit.originY,
                    validationError: worst, peripheralID: device, createdAt: Date(), movementVersion: PointerMotion.profileVersion,
                    crossX: fit.crossX, crossY: fit.crossY, calibrationVersion: CalibrationSolver.version,
                    fitSampleCount: grid.sampleCount, validationSampleCount: errors.count, validationRMS: rms, returnDrift: drift)
                guard final.usable else { throw AgentError.message("校准参数未通过完整性检查，请重试") }
                executor.calibration = final; SettingsStore.saveCalibration(final)
                record("Calibration saved")
                text = "21 步校准完成"; finished = true; onSaved?()
            } catch is CancellationError {
                if !finished { text = "校准已取消" }
            } catch {
                if token == session {
                    self.error = error.localizedDescription; record("Failed: \(self.error)"); text = "校准失败"
                }
            }
            if let pending = waiterToken { finishWait(pending, result: .failure(CancellationError())) }
            waitTimeout?.cancel(); target = nil
            // A cancelled task cannot send release through BLETransport. Use a new task.
            await Task { @MainActor in await executor.ble.release() }.value
            executor.invalidatePosition(); executor.calibrationInProgress = false
            busy = false; task = nil
        }
    }
}

struct CalibrationView: View {
    @StateObject var model: CalibrationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ZStack {
            CalibrationSurface(target: model.target, latestPoint: model.latestPoint, markers: model.markers,
                onPoint: { model.receive($0) }, onSize: { model.size = $0 }).ignoresSafeArea()
            if model.busy {
                VStack {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.text).font(.caption.weight(.medium))
                            ProgressView(value: Double(model.completedSteps), total: Double(CalibrationSolver.totalSteps))
                        }.padding(12).background(AgentPalette.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
                            .allowsHitTesting(false).accessibilityHidden(true)
                        Button("取消") { model.cancel(); dismiss() }
                            .font(.subheadline.weight(.medium)).padding(12)
                            .agentGlass(in: Capsule(), interactive: true).buttonStyle(.plain)
                    }
                    Spacer()
                }.padding(.horizontal, 16).padding(.top, 8)
            } else {
                VStack {
                    Spacer()
                    VStack(spacing: 13) {
                        HStack(spacing: 10) {
                            AgentOrb(size: 35)
                            Text("21 步精细校准").font(.title3.weight(.semibold))
                        }
                        Text(model.text).font(.subheadline).multilineTextAlignment(.center)
                        if !model.summary.isEmpty { Text(model.summary).font(.footnote.monospacedDigit()).multilineTextAlignment(.center) }
                        if !model.error.isEmpty { AgentNotice(text: model.error, error: true) }
                        Text("3 个基础测量 · 9 宫格采样 · 9 次独立验证\n每个点先回左上角，再斜向定位。\n吸附到项目可能改变实际页面的落点；需要精确坐标时建议关闭后校准。")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 10) {
                                Button(model.finished ? "重新校准" : "开始校准") { model.start() }.buttonStyle(AgentButtonStyle())
                                Button("完成") { model.cancel(); dismiss() }.buttonStyle(AgentButtonStyle(primary: false))
                            }
                        }
                    }.padding(20).frame(maxWidth: 390).agentGlass(in: RoundedRectangle(cornerRadius: 24))
                        .padding(.horizontal, 20).padding(.bottom, 16)
                }
            }
        }.tint(AgentPalette.accent).onDisappear { model.cancel() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.cancel() } }
    }
}

private struct CalibrationSurface: UIViewRepresentable {
    let target: CGPoint?
    let latestPoint: CGPoint?
    let markers: [CGPoint]
    let onPoint: (CGPoint) -> Void
    let onSize: (CGSize) -> Void
    func makeUIView(context: Context) -> Surface {
        let view = Surface(); view.backgroundColor = .systemBackground
        // Painted targets do not create individual controls for pointer snapping.
        view.isAccessibilityElement = false; view.accessibilityElementsHidden = true
        view.onPoint = onPoint; view.onSize = onSize; return view
    }
    func updateUIView(_ uiView: Surface, context: Context) {
        uiView.onPoint = onPoint; uiView.onSize = onSize
        uiView.target = target; uiView.latestPoint = latestPoint; uiView.markers = markers; uiView.setNeedsDisplay()
    }
    final class Surface: UIView {
        var target: CGPoint?
        var latestPoint: CGPoint?
        var markers: [CGPoint] = []
        var onPoint: ((CGPoint) -> Void)?
        var onSize: ((CGSize) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            if let size = window?.bounds.size {
                DispatchQueue.main.async { [weak self] in self?.onSize?(size) }
            }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let point = touches.first?.location(in: window) else { return }
            onPoint?(point)
        }
        override func draw(_ rect: CGRect) {
            UIColor.systemGray5.setStroke()
            let grid = UIBezierPath()
            for i in 1..<10 {
                let x = rect.width * CGFloat(i) / 10, y = rect.height * CGFloat(i) / 10
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: rect.height))
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: rect.width, y: y))
            }
            grid.lineWidth = 1; grid.stroke()
            UIColor.systemGray.withAlphaComponent(0.4).setFill()
            for point in markers {
                let p = convert(point, from: window)
                UIBezierPath(ovalIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)).fill()
            }
            if let target {
                let p = convert(target, from: window)
                UIColor.label.setStroke()
                let ring = UIBezierPath(ovalIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28))
                ring.lineWidth = 2; ring.stroke()
                let cross = UIBezierPath()
                cross.move(to: CGPoint(x: p.x - 20, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 20, y: p.y))
                cross.move(to: CGPoint(x: p.x, y: p.y - 20)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 20))
                cross.lineWidth = 1; cross.stroke()
                if let latestPoint {
                    let actual = convert(latestPoint, from: window)
                    UIColor.systemOrange.setStroke()
                    let line = UIBezierPath(); line.move(to: p); line.addLine(to: actual); line.lineWidth = 1; line.stroke()
                }
            }
            if let latestPoint {
                let p = convert(latestPoint, from: window)
                UIColor.systemOrange.setFill()
                UIBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill()
            }
        }
    }
}
