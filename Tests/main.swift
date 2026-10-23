// Run on macOS: compile with AgentModels.swift, MouseProtocol.swift and HIDKeyboard.swift.
import Foundation

var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { fatalError(label) }; checks += 1
}
func rejects(_ raw: String, _ label: String) {
    do { _ = try AgentAction.decodeResponse(raw); fatalError(label) }
    catch { checks += 1 }
}

try check(Array(MouseProtocol.packet(.report, sequence: 1, x: 20, y: 10)) == [1,1,1,0,0,20,10,0,0,0], "mouse vector")
try check(Array(MouseProtocol.packet(.click, sequence: 3, buttons: 1, delay: 3000)) == [1,2,3,0,1,0,0,0,184,11], "delay endian")
try check(Array(MouseProtocol.packet(.report, sequence: 65535, x: -127, y: 127))[2...6] == [255,255,0,129,127], "signed and sequence")
try check(MouseProtocol.packet(.report, sequence: 0, x: -900)[5] == 129, "clamp signed minimum")
try check(MouseProtocol.Status(Data([1,7,0,0,1,0,0,0]))?.ready == true, "old firmware ready")
try check(MouseProtocol.Status(Data([1,7,0,0,1,0,0,0]))?.keyboardAvailable == false, "old keyboard unavailable")
try check(MouseProtocol.Status(Data([1,7,0,0,1,0,3,1]))?.keyboardAvailable == true, "new keyboard ready")
try check(MouseProtocol.Status(Data([1,23,0,0,1,0,0,0]))?.ready == false, "suspended")
try check(MouseProtocol.Status(Data([1,15,1,0,1,0,0,0]))?.busy == true, "busy click")
try check(MouseProtocol.Status(Data([1,7])) == nil, "truncated status")
try check(MouseProtocol.Status(Data([2,7,0,0,1,0,0,0])) == nil, "unknown version")
let tap = try AgentAction.decodeResponse("{\"kind\":\"tap\",\"x\":0.5,\"y\":0.7,\"reason\":\"点击\"}")
try check(tap.kind == .tap && tap.x == 0.5, "valid tap")
try check(try AgentAction.decodeResponse("```json\n{\"kind\":\"finish\",\"reason\":\"完成\"}\n```").kind == .finish, "markdown envelope")
rejects("{\"kind\":\"tap\",\"x\":-0.1,\"y\":0.5,\"reason\":\"bad\"}", "negative target")
rejects("{\"kind\":\"tap\",\"x\":1.01,\"y\":0.5,\"reason\":\"bad\"}", "outside image")
rejects("{\"kind\":\"tap\",\"reason\":\"bad\"}", "missing target")
rejects("{\"kind\":\"drag\",\"x\":0.1,\"y\":0.1,\"reason\":\"bad\"}", "missing endpoint")
rejects("{\"kind\":\"scroll\",\"amount\":50,\"reason\":\"bad\"}", "excessive wheel")
rejects("{\"kind\":\"type\",\"text\":\"\",\"reason\":\"bad\"}", "empty text")
rejects("{\"kind\":\"erase_all\",\"reason\":\"bad\"}", "unknown action")
rejects("{\"kind\":\"wait\",\"seconds\":999,\"reason\":\"bad\"}", "excessive delay")
try check(try HIDKeyboard.ascii("a").0 == 0 && HIDKeyboard.ascii("a").1 == 4, "lowercase")
try check(try HIDKeyboard.ascii("A").0 == 2 && HIDKeyboard.ascii("A").1 == 4, "uppercase shift")
try check(try HIDKeyboard.ascii("0").1 == 39, "zero usage")
try check(try HIDKeyboard.ascii("@").0 == 2 && HIDKeyboard.ascii("@").1 == 31, "shift two")
try check(try HIDKeyboard.ascii("\\").1 == 49, "backslash")
try check(try HIDKeyboard.key("select_all").0 == 8 && HIDKeyboard.key("select_all").1 == 4, "Command A")
do { _ = try HIDKeyboard.ascii("中"); fatalError("unsupported Unicode must fail") } catch { checks += 1 }
let calibration = PointerCalibration(screenWidth: 390, screenHeight: 844, gainX: 1, gainY: 1,
    originX: 0, originY: 0, validationError: 5, peripheralID: "device", createdAt: Date(),
    movementVersion: PointerMotion.profileVersion, calibrationVersion: CalibrationSolver.version,
    fitSampleCount: 9, validationSampleCount: 9, validationRMS: 5, returnDrift: 0)
try check(calibration.usable, "valid calibration")
var invalid = calibration; invalid.gainX = 0
try check(!invalid.usable, "zero gain invalid")
invalid = calibration; invalid.validationError = CalibrationSolver.maxValidationError + 1
try check(!invalid.usable, "bad accuracy invalid")
invalid = calibration; invalid.originX = .nan
try check(!invalid.usable, "NaN calibration invalid")
invalid = calibration; invalid.movementVersion = nil
try check(!invalid.usable, "legacy movement profile invalid")

// --- Calibration solver -------------------------------------------------------
// The shipped build measured the gain with 40-unit reports but positioned with
// 8-unit reports. iOS pointer acceleration maps report speed to pointer speed, so
// those two regimes had slightly different gains and the model was a pure scale
// factor off: a target about a third of the way across the screen landed ~24 pt away.
let screen = CGSize(width: 390, height: 844)
let calibrationGain = 1.0    // points per unit seen by the coarse taps
let positioningGain = 1.045  // points per unit the pointer actually moves when locating
func landing(_ units: CGPoint) -> CGPoint {
    CGPoint(x: positioningGain * Double(units.x), y: positioningGain * Double(units.y))
}
func validationError(_ fit: PointerFit, targets: [CGPoint]) -> Double {
    var worst = 0.0
    for target in targets {
        let desired = CGPoint(x: screen.width * target.x, y: screen.height * target.y)
        let units = fit.units(x: Double(desired.x), y: Double(desired.y))
        let actual = landing(CGPoint(x: max(0, units.x), y: max(0, units.y)))
        worst = max(worst, Double(hypot(actual.x - desired.x, actual.y - desired.y)))
    }
    return worst
}
// The taps that measure the gain happen in the calibration regime.
let sampleA = CGPoint(x: calibrationGain * 40, y: calibrationGain * 80)
let sampleB = CGPoint(x: calibrationGain * 80, y: calibrationGain * 80)
let sampleC = CGPoint(x: calibrationGain * 40, y: calibrationGain * 120)
guard let coarse = CalibrationSolver.coarse(a: sampleA, b: sampleB, c: sampleC) else { fatalError("coarse fit") }
let validationTargets = [CGPoint(x: 0.35, y: 0.60), CGPoint(x: 0.65, y: 0.40)]
let coarseError = validationError(coarse, targets: validationTargets)
try check(coarseError > CalibrationSolver.maxValidationError,
          "scale error must fail a coarse-only fit, got \(coarseError)")

// Two taps across the working range, then validate on two fresh targets.
var measurements: [CalibrationSolver.Measurement] = []
for target in [CGPoint(x: 0.30, y: 0.35), CGPoint(x: 0.70, y: 0.70)] {
    let desired = CGPoint(x: screen.width * target.x, y: screen.height * target.y)
    let units = coarse.units(x: Double(desired.x), y: Double(desired.y))
    let moved = CGPoint(x: max(0, units.x), y: max(0, units.y))
    measurements.append(.init(units: moved, actual: landing(moved)))
}
guard let refit = CalibrationSolver.refit(measurements, fallback: coarse) else { fatalError("refit") }
let refitError = validationError(refit, targets: validationTargets)
try check(refitError <= CalibrationSolver.maxValidationError, "refit must pass validation, got \(refitError)")
try check(refitError < coarseError / 3, "refit must be far better than coarse: \(refitError) vs \(coarseError)")
try check(abs(refit.gainX - positioningGain) < 0.02 && abs(refit.gainY - positioningGain) < 0.02,
          "refit must recover the true gain")
print(String(format: "calibration solver: coarse-only %.1f pt fails, refit %.1f pt passes", coarseError, refitError))

// A refit built from two taps that barely move must be rejected rather than guessed.
let tiny: [CalibrationSolver.Measurement] = [
    .init(units: CGPoint(x: 100, y: 100), actual: CGPoint(x: 120, y: 140)),
    .init(units: CGPoint(x: 110, y: 108), actual: CGPoint(x: 132, y: 151)),
]
try check(CalibrationSolver.refit(tiny, fallback: coarse) == nil, "narrow refit rejected")
// An implausible slope must be rejected too.
let wild: [CalibrationSolver.Measurement] = [
    .init(units: CGPoint(x: 60, y: 60), actual: CGPoint(x: 60, y: 60)),
    .init(units: CGPoint(x: 160, y: 160), actual: CGPoint(x: 1000, y: 1000)),
]
try check(CalibrationSolver.refit(wild, fallback: coarse) == nil, "wild refit rejected")

print("PASS: \(checks) protocol, action, keyboard and calibration checks")
