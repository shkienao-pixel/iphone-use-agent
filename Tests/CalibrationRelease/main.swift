import Foundation
import CoreGraphics

private enum CalibrationSyntheticError: Error {case failure}
@MainActor private final class Checks{
 var checks=0,failures:[String]=[],rows:[[String:Any]]=[]
 func expect(_ ok:Bool,_ text:String){checks+=1;if !ok{failures.append(text)}}
}
@MainActor private func waitUntil(_ label:String,_ predicate:()->Bool)async throws{
 let deadline=ProcessInfo.processInfo.systemUptime+6
 while !predicate(){
  guard ProcessInfo.processInfo.systemUptime<deadline else{throw AgentError.message("synthetic deadline: "+label)}
  try await Task.sleep(nanoseconds:1_000_000)
 }
}
@MainActor private func releaseCount(_ ble:BLETransport)->Int{
 ble.writes.filter{$0.count==10 && $0[1]==MouseProtocol.Operation.release.rawValue}.count
}
@MainActor private func model(_ ble:BLETransport)->(CalibrationModel,MouseExecutor){
 let executor=MouseExecutor(ble:ble),model=CalibrationModel(executor:executor);model.size=CGSize(width:390,height:844);return(model,executor)
}
@main private struct CalibrationReleaseChecks{
 @MainActor static func main()async throws{
  let out=URL(fileURLWithPath:CommandLine.arguments[1]),before=CommandLine.arguments[2]=="before",checks=Checks()
  let temp=FileManager.default.temporaryDirectory.appendingPathComponent("CalibrationReleaseIO-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:temp)}
  CalibrationReleaseFixture.recordURL=temp.appendingPathComponent("calibration-diagnostics.log")
  // First reproduce the actual production route: start captured old connection,
  // home suspended/failed, then cleanup runs after a new connection exists.
  for cancellation in [false,true]{
   let ble=BLETransport(),old=ble.peer!,originalGeneration=ble.pointerConnectionGeneration,(owner,executor)=model(ble)
   var gate:CheckedContinuation<Void,Error>?,newReleaseWrites=0,oldReleaseWrites=0
   ble.onWrite={bytes,peer in
    if bytes[1]==MouseProtocol.Operation.release.rawValue{if peer===old{oldReleaseWrites+=1}else{newReleaseWrites+=1}}
    Task{@MainActor in await Task.yield();ble.acknowledge(bytes,from:peer)}
   }
   if cancellation{executor.onHome={try await withCheckedThrowingContinuation{gate=$0}}}
   else{executor.onHome={ble.switchConnection();throw CalibrationSyntheticError.failure}}
   owner.start()
   if cancellation{
    try await waitUntil("home suspension"){gate != nil};ble.switchConnection();owner.cancel()
    gate!.resume(throwing:CancellationError());gate=nil
   }
   try await waitUntil("calibration cleanup"){!owner.busy}
   checks.expect(ble.pointerConnectionGeneration != originalGeneration,"counterexample really changes connection generation")
   checks.expect(newReleaseWrites==(before ? 1:0) && oldReleaseWrites==0,
    before ? "before: actual model cleanup incorrectly submits release to new session":"after: cleanup never submits a neutral release to a replacement connection")
   checks.expect(executor.homeCalls==1 && executor.moveCalls==0 && executor.clickCalls==0 && owner.completedSteps==0,"counterexample uses actual model first-home failure without simulating 21 measurements")
   checks.expect(!executor.calibrationInProgress && !owner.finished && SettingsStore.saveCount==0,"cleanup completes flags and never saves calibration")
   checks.expect(ble.writeWasCancelled.allSatisfy{!$0},"fresh cleanup task remains uncancelled")
   checks.rows.append(["case":cancellation ? "reconnect-before-cancel-cleanup":"reconnect-before-error-cleanup",
    "oldReleaseWrites":oldReleaseWrites,"newReleaseWrites":newReleaseWrites,"homeCalls":executor.homeCalls,
    "writeContextsCancelled":ble.writeWasCancelled,"calibrationInProgress":executor.calibrationInProgress,"busy":owner.busy])
  }
  if !before{try await after(checks)}
  try FileManager.default.removeItem(at:temp)
  let result:[String:Any]=["schemaVersion":1,"mode":before ? "before-counterexample":"after-fix","checks":checks.checks,
   "failures":checks.failures,"cases":checks.rows,"actualEntireCalibrationModel":true,"actualReleaseControllerAndNativeMethods":true,
   "syntheticMouseAndTransportOnly":true,"noPhoneBLEAPIModelOrDocumentsWrites":true,
   "acknowledgementIsNotHIDReceipt":true,"temporaryIOCleaned":!FileManager.default.fileExists(atPath:temp.path)]
  try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out,options:.atomic)
  print("CalibrationRelease \(before ? "before":"after"): \(checks.checks) checks; failures=\(checks.failures)")
  guard checks.failures.isEmpty else{throw AgentError.message("calibration cleanup assertion failed")}
 }
 @MainActor private static func after(_ checks:Checks)async throws{
  for cancellation in [false,true]{
   let ble=BLETransport(),(owner,executor)=model(ble)
   var gate:CheckedContinuation<Void,Error>?
   if cancellation{executor.onHome={try await withCheckedThrowingContinuation{gate=$0}}}
   owner.start()
   if cancellation{try await waitUntil("same-session cancellation"){gate != nil};owner.cancel();gate!.resume(throwing:CancellationError());gate=nil}
   try await waitUntil("same-session cleanup ACK"){!owner.busy}
   checks.expect(releaseCount(ble)==1 && ble.writer==nil && ble.writeWasCancelled==[false],"same-session error/cancel performs one uncancelled ACKed transport write")
   checks.expect(ble.ready && ble.latestStatus?.sequence==ble.sequence && ble.central.disconnectRequests==0,
    "same-session cleanup finishes through actual ACK path, not transport timeout")
   checks.expect(!executor.calibrationInProgress && !owner.finished && executor.invalidations==1,"busy ownership ends only after cleanup")
   checks.rows.append(["case":cancellation ? "same-connection-cancel":"same-connection-error","releaseWrites":releaseCount(ble),"writerPresent":ble.writer != nil])
  }
  // The existing writer lives beyond the former 1s wait. No ownership or ATT
  // continuation can be cleared merely to make the calibration cleanup run.
  do{
   let ble=BLETransport(),(owner,executor)=model(ble)
   var oldWrite:(Data,CBPeripheral)?,releaseWrite:(Data,CBPeripheral)?
   ble.onWrite={data,peer in if data[1]==MouseProtocol.Operation.release.rawValue{releaseWrite=(data,peer)}else{oldWrite=(data,peer)}}
   let pending=Task{@MainActor in try await ble.send(.click)}
   try await waitUntil("existing writer"){oldWrite != nil}
   owner.start();try await waitUntil("model reaches cleanup"){!owner.error.isEmpty}
   try await Task.sleep(nanoseconds:1_150_000_000)
   checks.expect(owner.busy && executor.calibrationInProgress && executor.invalidations==0 && ble.writer != nil && releaseCount(ble)==0,"busy is held while original writer remains pending beyond 1s")
   owner.cancel();owner.cancel();owner.start()
   checks.expect(executor.homeCalls==1 && owner.busy,"repeat cancel/start cannot create another calibration owner or bypass pending cleanup")
   ble.acknowledge(oldWrite!.0,from:oldWrite!.1);_ = try await pending.value
   try await waitUntil("neutral release submitted after original ACK"){releaseWrite != nil}
   checks.expect(owner.busy && executor.calibrationInProgress && ble.writer != nil && releaseCount(ble)==1,"busy remains through the release's own pending ATT write")
   ble.acknowledge(releaseWrite!.0,from:releaseWrite!.1)
   try await waitUntil("owned cleanup ACK"){!owner.busy}
   checks.expect(!executor.calibrationInProgress && executor.invalidations==1 && ble.writer==nil,"actual release ACK completes owner exactly once")
   checks.expect(ble.writeWasCancelled.allSatisfy{!$0},"caller cancellation never marks cleanup write context cancelled")
   checks.rows.append(["case":"old-writer-ACK-after-1.15s","releaseWrites":releaseCount(ble),"homeCalls":executor.homeCalls,"writerPresent":ble.writer != nil])
  }
  // Reconnect while the controller is already waiting for the original writer.
  do{
   let ble=BLETransport(),(owner,executor)=model(ble);var oldWrite:(Data,CBPeripheral)?
   ble.onWrite={data,peer in oldWrite=(data,peer)}
   let pending=Task{@MainActor in try await ble.send(.click)}
   try await waitUntil("pending old writer before reconnect"){oldWrite != nil}
   owner.start();try await waitUntil("cleanup waiting before reconnect"){!owner.error.isEmpty}
   try await Task.sleep(nanoseconds:5_000_000)
   checks.expect(owner.busy && ble.writer != nil,"cleanup wait does not clear existing writer")
   ble.switchConnection();owner.cancel()
   _ = try? await pending.value
   try await waitUntil("old-generation cleanup declines replacement"){!owner.busy}
   checks.expect(releaseCount(ble)==0 && !executor.calibrationInProgress,"connection change during writer wait submits no new-session release")
   var newWrite:(Data,CBPeripheral)?;ble.onWrite={data,peer in newWrite=(data,peer)}
   let next=Task{@MainActor in try await ble.send(.click)};try await waitUntil("new explicit writer"){newWrite != nil}
   ble.acknowledge(oldWrite!.0,from:oldWrite!.1)
   checks.expect(ble.writer != nil,"late old-peer ACK cannot clear the new connection writer")
   ble.acknowledge(newWrite!.0,from:newWrite!.1);_ = try await next.value
   checks.rows.append(["case":"reconnect-during-old-writer-wait","releaseWrites":releaseCount(ble),"oldACKClearedNewWriter":false])
  }
  // Actual transport timeout, never a virtual clock or premature writer clear.
  do{
   let ble=BLETransport(),(owner,executor)=model(ble);var oldWrite:(Data,CBPeripheral)?
   ble.onWrite={data,peer in oldWrite=(data,peer)}
   let pending=Task{@MainActor in try await ble.send(.click)}
   try await waitUntil("timeout writer"){oldWrite != nil}
   owner.start();try await waitUntil("timeout cleanup entered"){!owner.error.isEmpty}
   try await Task.sleep(nanoseconds:20_000_000)
   checks.expect(owner.busy && ble.writer != nil && releaseCount(ble)==0,"unacknowledged writer retains calibration ownership before real timeout")
   var timedOut=false;do{_ = try await pending.value}catch{timedOut=true}
   try await waitUntil("cleanup sees transport timeout"){!owner.busy}
   checks.expect(timedOut && ble.command==nil && ble.central.disconnectRequests==1 && releaseCount(ble)==0,"ordinary 3s ATT timeout quarantines command before cleanup can submit")
   checks.expect(!executor.calibrationInProgress && executor.invalidations==1,"timeout does not leave calibration permanently busy")
   ble.switchConnection();var newWrite:(Data,CBPeripheral)?;ble.onWrite={data,peer in newWrite=(data,peer)}
   let next=Task{@MainActor in try await ble.send(.click)};try await waitUntil("post-timeout new writer"){newWrite != nil}
   ble.acknowledge(oldWrite!.0,from:oldWrite!.1)
   checks.expect(ble.writer != nil,"late timed-out peer ACK never acknowledges another session")
   ble.acknowledge(newWrite!.0,from:newWrite!.1);_ = try await next.value
   checks.rows.append(["case":"actual-old-writer-3s-timeout","releaseWrites":releaseCount(ble),"disconnectRequests":ble.central.disconnectRequests])
  }
  for invalid in ["not-ready","no-device","landscape","zero-size","other-calibration"]{
   let ble=BLETransport(),(owner,executor)=model(ble)
   switch invalid{
   case "not-ready":ble.connected=false
   case "no-device":ble.selectedID=nil
   case "landscape":owner.size=CGSize(width:844,height:390)
   case "zero-size":owner.size = .zero
   default:executor.calibrationInProgress=true
   }
   owner.start();await Task.yield()
   checks.expect(!owner.busy && executor.homeCalls==0 && ble.writes.isEmpty,"invalid start \(invalid) creates no owned task or cleanup release")
  }
  checks.expect(SettingsStore.saveCount==0,"all failure/cancel controls preserve saved calibration")
 }
}
