import Foundation

@main struct SemanticDispatchChecks {
 @MainActor static func main() async throws {
  let out = URL(fileURLWithPath: CommandLine.arguments[1])
  var rows: [[String: Any]] = []
  func calibrate(_ executor: MouseExecutor) {
   executor.calibration = .init(screenWidth:390,screenHeight:844,gainX:1,gainY:1,originX:0,originY:0,validationError:0,
       peripheralID:"synthetic-accessory",createdAt:Date(),movementVersion:PointerMotion.profileVersion,
       crossX:0,crossY:0,calibrationVersion:CalibrationSolver.version,fitSampleCount:9,
       validationSampleCount:CalibrationSolver.validationTargets.count,validationRMS:0,returnDrift:0)
  }
  func inputWrites(_ ble: BLETransport) -> [Data] {
   ble.writes.filter { bytes in
    guard bytes.count == 10, bytes[0] == 1 else { return false }
    return bytes[1] == MouseProtocol.Operation.click.rawValue ||
      (bytes[1] == MouseProtocol.Operation.keyboard.rawValue && bytes[5] != 0) ||
      (bytes[1] == MouseProtocol.Operation.report.rawValue && (bytes[4] != 0 || bytes[7] != 0))
   }
  }
  // Exercise the full production Runtime -> MouseExecutor -> BLE command path.
  // Synthetic writes acknowledge immediately; a real await is retained in
  // homing. The capture slot changes either while homing or at destination.
  for stage in [1, 2] { for fault in ["unchangedIdle", "pixels", "captureStopped", "connection", "runtime", "missingFrame"] {
   let capture = CaptureService(), ble = BLETransport(), executor = MouseExecutor(ble: ble), captureID = UUID()
   calibrate(executor)
   let origin = ScreenFrame(image:UIImage(shade:1),jpeg:Data([1]),capturedAt:Date(),sourceWidth:390,sourceHeight:844,fullDisplay:true,captureID:captureID)
   capture.frozenFrame = origin
   var mutated = false, reads = 0, readsAtMovement = 0, movements = 0
   var runtime: PhoneHarnessRuntime!
   ble.beforeAcknowledge = { bytes in
    guard bytes[0] == 2 else { return }; movements += 1
    guard movements == stage else { return }
    mutated = true; readsAtMovement = reads
    switch fault {
    case "pixels": capture.frozenFrame = ScreenFrame(image:UIImage(shade:0),jpeg:Data([2]),capturedAt:Date(),sourceWidth:390,sourceHeight:844,fullDisplay:true,captureID:captureID)
    case "captureStopped": capture.running = false
    case "connection": ble.connectionGeneration = UUID()
    case "runtime": runtime.reset()
    case "missingFrame": capture.frozenFrame = nil
    default:
      capture.frozenFrame = ScreenFrame(image:origin.image,jpeg:origin.jpeg,capturedAt:origin.capturedAt,sourceWidth:390,sourceHeight:844,fullDisplay:true,confirmedAt:Date(),captureID:captureID)
    }
   }
   runtime = PhoneHarnessRuntime(executor:executor,memoryURL:out.appendingPathComponent("memory-\(stage)-\(fault).json"),recognize:{ _ in
     [.init(id:"continue",label:"Continue",rect:.init(x:0.4,y:0.4,width:0.2,height:0.05),source:"ocr")]
   },contextCurrent:{
     reads += 1
     return .init(frame:capture.frame,running:capture.running,selectedDeviceID:ble.selectedID,accessoryReady:ble.ready,connectionGeneration:ble.pointerConnectionGeneration)
   })
   var observedAfterInput = false
   do {
    _ = try await runtime.execute(.init(operation:.tap,target:"Continue"),frame:origin,mappedHome:false,nextFrame:{ _ in
     observedAfterInput = true
     throw AgentError.message("offline probe stops at post-input observation")
    })
   } catch { }
   let allowed = fault == "unchangedIdle"
   precondition(mutated && inputWrites(ble).count == (allowed ? 1 : 0), "unsafe physical input: \(stage)-\(fault)")
   precondition(observedAfterInput == allowed, "failed dispatch must not report completed input")
   if allowed || ["pixels","captureStopped","missingFrame"].contains(fault) {
    precondition(reads > readsAtMovement, "live capture must be consulted after positioning")
   }
   rows.append(["case":"runtime-\(stage)-\(fault)","inputCount":inputWrites(ble).count,"liveReads":reads,"liveReadsAtMovement":readsAtMovement,"postInputObservation":observedAfterInput])
  }}
  // Directly check every physical input family. Rejection may send a neutral
  // cleanup release, but never a press/wheel. Old callers still have a nil
  // callback default; the ordinary InputRelease suite verifies those paths.
  let actions: [(String,AgentAction)] = [
   ("tap",.init(kind:.tap,x:0.4,y:0.5,reason:"offline gate")),
   ("longPress",.init(kind:.long_press,x:0.4,y:0.5,seconds:0.3,reason:"offline gate")),
   ("drag",.init(kind:.drag,x:0.4,y:0.5,x2:0.5,y2:0.6,seconds:0.3,reason:"offline gate")),
   ("targetedScroll",.init(kind:.scroll,x:0.4,y:0.5,amount:-2,reason:"offline gate")),
   ("currentScroll",.init(kind:.scroll,amount:-2,reason:"offline gate")),
   ("type",.init(kind:.type,text:"ab",reason:"offline gate")),
   ("key",.init(kind:.press_key,text:"enter",reason:"offline gate")),
   ("home",.init(kind:.press_key,text:"home",reason:"offline gate"))]
  for (name,action) in actions { for reject in [false,true] {
   let ble = BLETransport(), executor = MouseExecutor(ble:ble)
   calibrate(executor)
   var checks = 0, rejected = false
   let frame = ScreenFrame(image:UIImage(),jpeg:Data([1]),capturedAt:Date(),sourceWidth:390,sourceHeight:844,fullDisplay:true,captureID:UUID())
   do {
    try await executor.execute(action,frame:frame,mappedHomeAvailable:true,validateInput:{
     checks += 1
     if [.tap,.long_press,.drag].contains(action.kind) || name == "targetedScroll" {
       precondition(ble.writes.filter { $0[0] == 2 }.count == 2, "validate after both positioning awaits")
     }
     if reject { throw AgentError.message("offline invalid observation") }
    })
   } catch { rejected = true }
   precondition(checks == 1 && rejected == reject && (reject ? inputWrites(ble).isEmpty : !inputWrites(ble).isEmpty), "physical gate \(name)-\(reject)")
   precondition(ble.pointerMotionTokens.isEmpty, "no pointer ownership leak")
   rows.append(["case":"gate-\(name)-reject-\(reject)","inputCount":inputWrites(ble).count,"checks":checks,"rejected":rejected])
  }}
  // Typing normally changes UI pixels after its first character. Keep one
  // focus admission for the text operation, and always emit both key releases.
  let ble = BLETransport(), executor = MouseExecutor(ble:ble)
  var changedWhileTyping = false, checks = 0
  ble.beforeAcknowledge = { data in if data[1] == MouseProtocol.Operation.keyboard.rawValue && data[5] != 0 { changedWhileTyping = true } }
  let frame = ScreenFrame(image:UIImage(),jpeg:Data([1]),capturedAt:Date(),sourceWidth:390,sourceHeight:844,fullDisplay:true,captureID:UUID())
  try await executor.execute(.init(kind:.type,text:"ab",reason:"offline normal typing"),frame:frame,validateInput:{
   checks += 1; precondition(!changedWhileTyping, "do not reuse an initial pixel lease between text characters")
  })
  precondition(changedWhileTyping && checks == 1 && inputWrites(ble).count == 2 && ble.writes.count == 4)
  rows.append(["case":"typing-changes-pixels-normally","checks":checks,"keyDowns":2,"keyReleases":2])
  // A reconnect between characters must not rebind the remainder of one text
  // operation to another accessory. Change after the first key release ACK,
  // during the executor's ordinary inter-key pause.
  let reconnectBLE = BLETransport(), reconnectExecutor = MouseExecutor(ble:reconnectBLE)
  var switchTask: Task<Void,Never>?, switched = false, typingRejected = false
  reconnectBLE.beforeAcknowledge = { data in
   if data[1] == MouseProtocol.Operation.keyboard.rawValue && data[5] == 0 && switchTask == nil {
    switchTask = Task { @MainActor in
     try? await Task.sleep(nanoseconds:1_000_000)
     reconnectBLE.switchConnection(); switched = true
    }
   }
  }
  do { try await reconnectExecutor.execute(.init(kind:.type,text:"ab",reason:"offline reconnect"),frame:frame) }
  catch { typingRejected = true }
  await switchTask?.value
  precondition(switched && typingRejected && inputWrites(reconnectBLE).count == 1, "remaining text must not target a reconnected accessory")
  rows.append(["case":"typing-reconnect-between-characters","rejected":typingRejected,"keyDowns":inputWrites(reconnectBLE).count])
  try JSONSerialization.data(withJSONObject:["cases":rows,"actualRuntimeMouseAndBLEMethods":true,"syntheticTransportOnly":true],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("results.json"))
  print("SemanticDispatch: \(rows.count) cases passed; actual Runtime/MouseExecutor/BLE methods, no device or network")
 }
}
