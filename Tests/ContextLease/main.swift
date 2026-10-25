import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor final class ContextScenario {
 let capture = CaptureService(), executor = MouseExecutor()
 var runtime: PhoneHarnessRuntime!
 let origin: ScreenFrame
 let boundary: Date
 var fullCalls = 0, roiCalls = 0, providerCalls = 0
 var fault: String?, stage = "ocr", armed = true, didMutate = false
 init(origin: ScreenFrame, boundary: Date) { self.origin = origin; self.boundary = boundary; capture.frozenFrame = origin }
 func current() -> WorkflowObservationState {
  providerCalls += 1
  if stage == "initial", armed, !didMutate { mutate() }
  return .init(frame: capture.frame, running: capture.running, selectedDeviceID: executor.ble.selectedID,
   accessoryReady: executor.ble.ready, connectionGeneration: executor.ble.pointerConnectionGeneration)
 }
 func copy(image: UIImage? = nil, jpeg: Data? = nil, pixel: Date? = nil, confirmed: Date? = nil,
           captureID: UUID? = nil, sourceWidth: Int? = nil, sourceHeight: Int? = nil, full: Bool? = nil) -> ScreenFrame {
  .init(image: image ?? origin.image, jpeg: jpeg ?? origin.jpeg, capturedAt: pixel ?? origin.capturedAt,
   sourceWidth: sourceWidth ?? origin.sourceWidth, sourceHeight: sourceHeight ?? origin.sourceHeight,
   fullDisplay: full ?? origin.fullDisplay, confirmedAt: confirmed ?? origin.confirmedAt, captureID: captureID ?? origin.captureID)
 }
 func mutate() {
  guard armed, !didMutate, let fault else { return }; didMutate = true
  switch fault {
  case "captureRunning": capture.running = false
  case "currentFramePresent": capture.frozenFrame = nil
  case "currentCaptureMatches": capture.frozenFrame = copy(captureID: UUID())
  case "currentPixelsMatch": capture.frozenFrame = copy(pixel: origin.capturedAt.addingTimeInterval(-1))
  case "currentFullDisplay": capture.frozenFrame = copy(full: false)
  case "currentDimensionsMatch": capture.frozenFrame = copy(image: Self.image(3,2))
  case "currentSourceWidthMatches": capture.frozenFrame = copy(sourceWidth: origin.sourceWidth+1)
  case "currentSourceHeightMatches": capture.frozenFrame = copy(sourceHeight: origin.sourceHeight+1)
  case "currentImageObjectMatches": capture.frozenFrame = copy(image: UIImage(cgImage: origin.image.cgImage!))
  case "currentCGImageObjectMatches": capture.frozenFrame = copy(image: Self.image(2,2))
  case "currentJPEGMatches": var bytes=origin.jpeg; bytes.append(0); capture.frozenFrame = copy(jpeg: bytes)
  case "confirmationTimestampFinite": capture.frozenFrame = copy(confirmed: Date(timeIntervalSinceReferenceDate: .nan))
  case "pixelBeforeConfirmation", "confirmationNotRegressed": capture.frozenFrame = copy(confirmed: origin.capturedAt.addingTimeInterval(-0.01))
  case "expectedAccessoryMatches": executor.ble.selectedID = "changed-synthetic-device"
  case "accessoryReady": executor.ble.ready = false
  case "connectionGenerationMatches": executor.ble.pointerConnectionGeneration = UUID()
  case "runtimeGenerationMatches": runtime.reset()
  case "cancel": withUnsafeCurrentTask { $0?.cancel() }
  default: preconditionFailure("Unknown synthetic mutation")
  }
 }
 static func image(_ width: Int, _ height: Int) -> UIImage {
  let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
   space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
  return UIImage(cgImage:context.makeImage()!)
 }
}

@main struct ContextLeaseChecks {
 @MainActor static func main() async throws {
  let out=URL(fileURLWithPath:CommandLine.arguments[1]), work=URL(fileURLWithPath:CommandLine.arguments[2])
  var checks=0,failures:[String]=[],rows:[[String:Any]]=[]
  func expect(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append(label) } }
  func publish(_ complete: Bool = false) throws {
   try JSONSerialization.data(withJSONObject:["checks":checks,"failures":failures,"rows":rows,"complete":complete,
    "productionSourceTarget":true,"actualObserveActionAndRuntime":true,"realAPIPhoneBLEOrModel":false],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("results.json"),options:.atomic)
  }
  func fixture() async throws -> ContextScenario {
   let image=ContextScenario.image(2,2),data=NSMutableData()
   let destination=CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil)!
   CGImageDestinationAddImage(destination,image.cgImage!,nil);precondition(CGImageDestinationFinalize(destination))
   let after=Date(),until=ProcessInfo.processInfo.systemUptime+1;var pixel=Date()
   while pixel<=after && ProcessInfo.processInfo.systemUptime<until { await Task.yield();pixel=Date() }
   guard pixel>after else { throw AgentError.message("Synthetic source clock did not advance") }
   let frame=ScreenFrame(image:image,jpeg:data as Data,capturedAt:pixel,sourceWidth:2,sourceHeight:2,fullDisplay:true,captureID:UUID())
   return ContextScenario(origin:frame,boundary:after)
  }
  func install(_ value:ContextScenario,_ name:String,provider:Bool=true,delay:UInt64=0,uniqueLabels:Bool=false) {
   let recognize: (ScreenFrame) async throws -> [PhoneUIElement] = { [unowned value] _ in
    value.fullCalls += 1
    if delay>0 { try await Task.sleep(nanoseconds:delay) }
    if value.stage=="ocr" {value.mutate()}
    return [.init(id:"marker",label:uniqueLabels ? "Synthetic marker \(value.fullCalls)":"Synthetic marker",
     rect:.init(x:0.2,y:0.3,width:0.5,height:0.1),source:"ocr")]
   }
   let current: WorkflowObservationLease.Current?
   if provider { current = { [unowned value] in value.current() } } else { current = nil }
   value.runtime=PhoneHarnessRuntime(executor:value.executor,memoryURL:work.appendingPathComponent(name+".json"),recognize:recognize,
    recognizeWorkflowTitle:{[unowned value] _ in value.roiCalls += 1;return []},contextCurrent:current)
   value.runtime.savedWorkflowContext = { [unowned value] in
    if value.stage=="final" {value.mutate()};return "{}"
   }
  }
  func invoke(_ value:ContextScenario,_ name:String) async -> (String?,[String],ScreenFrame?) {
   ModelProbe.calls=0;ModelProbe.onRequest=nil;ModelProbe.delay=0
   let settings:AgentSettings={var result=AgentSettings();result.previewOnly = !value.executor.ble.ready || value.executor.ble.selectedID==nil;result.useMemories=false;return result}()
   let probe=ActualObserveActionProbe(capture:value.capture,executor:value.executor,harness:value.runtime)
   var error:String?,predicates:[String]=[],returned:ScreenFrame?
   let operation=Task { @MainActor in try await probe.run(settings:settings,after:value.boundary) }
   do {returned=try await operation.value.0}
   catch let caught as WorkflowLeaseFailure {error=String(reflecting:type(of:caught));predicates=caught.predicates.map(\.rawValue)}
   catch let caught {error=String(reflecting:type(of:caught))}
   expect(probe.freshReads==1,name+": one fresh initial frame; no automatic reread/retry")
   expect(value.executor.actions.isEmpty && value.executor.pointerMoves.isEmpty && value.executor.ble.releases==0,name+": zero HID/release")
   expect(value.roiCalls==0,name+": ordinary context never invokes workflow title ROI")
   if let supplied=probe.suppliedFrame {
    expect(supplied.image===value.origin.image && supplied.jpeg==value.origin.jpeg && supplied.confirmedAt==value.origin.confirmedAt,name+": Engine supplied frame is never retimed or substituted")
   } else {expect(false,name+": original frame supplied")}
   return (error,predicates,returned)
  }
  for (name,provider,noBLE,slow,idle,accepted) in [
   ("fast-connected",true,false,false,false,true),("fast-default-nil",false,false,false,false,true),
   ("fast-preview-noBLE-provider",true,true,false,false,true),("slow-real-idle",true,false,true,true,true),
   ("slow-timer-only",true,false,true,false,false),("slow-default-nil-real-idle",false,false,true,true,false),
   ("slow-preview-noBLE-real-idle",true,true,true,true,false)] {
   let value=try await fixture()
   if noBLE {value.executor.ble.ready=false;value.executor.ble.keyboardReady=false;value.executor.ble.selectedID=nil}
   install(value,name,provider:provider,delay:slow ? 1_750_000_000:0)
   let callback:Task<Void,Error>? = idle ? Task { @MainActor in
    try await Task.sleep(nanoseconds:1_600_000_000)
    value.capture.frozenFrame=contextAuditIdle(previous:value.origin,now:Date(),captureID:value.origin.captureID!,isFullDisplay:true)
   }:nil
   let (error,predicates,returned)=await invoke(value,name);try await callback?.value
   expect((error==nil)==accepted && ModelProbe.calls==(accepted ? 1:0),name+": correct actual Engine model-boundary decision")
   if accepted {expect(returned?.confirmedAt==value.origin.confirmedAt && returned?.image===value.origin.image,name+": Engine still returns original frame")}
   if !provider || noBLE {expect(value.providerCalls==0,name+": strict nil/noBLE path never consults provider")}
   if name=="slow-timer-only" {expect(predicates.contains("confirmationAgeValid"),name+": same static pixels without a real current confirmation do not renew age")}
   rows.append(["case":name,"error":error ?? "none","predicates":predicates,"modelBoundaryCalls":ModelProbe.calls,"fullOCR":value.fullCalls,"providerCalls":value.providerCalls]);try publish()
  }
  do {
   let value=try await fixture();value.executor.ble.selectedID="";install(value,"fast-empty-selected-provider")
   let(error,_,_)=await invoke(value,"fast-empty-selected-provider")
   expect(error==nil && ModelProbe.calls==1 && value.providerCalls==0,"empty selected ID preserves the original strict context path without provider admission")
   rows.append(["case":"fast-empty-selected-provider","error":error ?? "none","modelBoundaryCalls":ModelProbe.calls,"providerCalls":value.providerCalls]);try publish()
  }
  for invalid in ["empty-JPEG","nil-capture-ID"] {
   let seed=try await fixture(),frame=ScreenFrame(image:seed.origin.image,jpeg:invalid=="empty-JPEG" ? Data():seed.origin.jpeg,
    capturedAt:seed.origin.capturedAt,sourceWidth:2,sourceHeight:2,fullDisplay:true,
    confirmedAt:seed.origin.confirmedAt,captureID:invalid=="nil-capture-ID" ? nil:seed.origin.captureID)
   let value=ContextScenario(origin:frame,boundary:seed.boundary);install(value,"invalid-source-"+invalid)
   let(error,predicates,_)=await invoke(value,"invalid-source-"+invalid)
   expect(error != nil && predicates==["sourcePixelsValid"] && ModelProbe.calls==0 && value.fullCalls==0,"invalid-source-"+invalid+": failed strong source admission never calls OCR/model or falls back")
   rows.append(["case":"invalid-source-"+invalid,"error":error ?? "none","predicates":predicates,"modelBoundaryCalls":ModelProbe.calls,"fullOCR":value.fullCalls]);try publish()
  }
  let faults=["captureRunning","currentFramePresent","currentCaptureMatches","currentPixelsMatch","currentFullDisplay",
   "currentDimensionsMatch","currentSourceWidthMatches","currentSourceHeightMatches","currentImageObjectMatches","currentCGImageObjectMatches",
   "currentJPEGMatches","confirmationTimestampFinite","pixelBeforeConfirmation","confirmationNotRegressed",
   "expectedAccessoryMatches","accessoryReady","connectionGenerationMatches","runtimeGenerationMatches","cancel"]
  for stage in ["initial","ocr","final"] {for fault in faults {
   let name=stage+"-"+fault,value=try await fixture();value.stage=stage;value.fault=fault;install(value,name)
   let(error,predicates,_)=await invoke(value,name)
   expect(value.didMutate,name+": the requested field mutation actually executed")
   expect(error != nil && ModelProbe.calls==0,name+": failed binding cannot reach model or downgrade to strict")
   if fault=="cancel" {expect(error?.hasSuffix("CancellationError")==true,name+": original cancellation type")}
   else if !(fault=="runtimeGenerationMatches" && stage=="initial") {
    let expected=fault.hasPrefix("currentSource") ? "currentSourceDimensionsMatch":fault
    expect(predicates.contains(expected),name+": actual fixed predicate identifies the rejected field")
   }
   rows.append(["case":name,"error":error ?? "none","predicates":predicates,"modelBoundaryCalls":ModelProbe.calls,"fullOCR":value.fullCalls,"didMutate":value.didMutate,"stage":stage]);try publish()
  }}
  for fault in ["currentJPEGMatches","runtimeGenerationMatches","connectionGenerationMatches","cancel"] {
   let name="cache-final-"+fault,value=try await fixture();value.stage="final";value.fault=fault;value.armed=false;install(value,name)
   _=try await value.runtime.context(for:value.origin);value.armed=true
   let(error,predicates,_)=await invoke(value,name)
   expect(value.didMutate,name+": the cache-hit final mutation actually executed")
   expect(error != nil && ModelProbe.calls==0 && value.fullCalls==1,name+": raw cache hit still revalidates actual final state")
   if fault=="cancel" {expect(error?.hasSuffix("CancellationError")==true,name+": cache-hit cancellation preserves type")}
   rows.append(["case":name,"error":error ?? "none","predicates":predicates,"modelBoundaryCalls":ModelProbe.calls,"fullOCR":value.fullCalls,"didMutate":value.didMutate,"stage":value.stage]);try publish()
  }
  for collision in ["UIImage","CGImage","JPEG"] {
   let name="weak-cache-collision-"+collision,value=try await fixture();install(value,name,uniqueLabels:true)
   _=try await value.runtime.context(for:value.origin)
   var bytes=value.origin.jpeg;bytes.append(0)
   let second=collision=="UIImage" ? value.copy(image:UIImage(cgImage:value.origin.image.cgImage!)):
    collision=="CGImage" ? value.copy(image:ContextScenario.image(2,2)):value.copy(jpeg:bytes)
   value.capture.frozenFrame=second
   let context=try await value.runtime.context(for:second)
   expect(value.fullCalls==2 && context.contains("Synthetic marker 2"),name+": weak key never authorizes a different strong pixel value")
   expect(value.roiCalls==0,name+": cache mismatch does not add ROI")
   rows.append(["case":name,"fullOCR":value.fullCalls]);try publish()
  }
  do {
   let value=try await fixture();install(value,"JSON-equality")
   let baseline=PhoneHarnessRuntime(executor:value.executor,memoryURL:work.appendingPathComponent("baseline-json.json"),recognize:{_ in
    [.init(id:"marker",label:"Synthetic marker",rect:.init(x:0.2,y:0.3,width:0.5,height:0.1),source:"ocr")]
   })
   let oldContext=try await baseline.context(for:value.origin)
   let newContext=try await value.runtime.context(for:value.origin)
   expect(oldContext==newContext,"complete admitted context JSON equals the default strict path at the same pixels")
   let generation=UUID(),connection=value.executor.ble.pointerConnectionGeneration
   let context=try WorkflowObservationLease.contextFrame(value.origin,runtimeGeneration:generation,selectedDeviceID:value.executor.ble.selectedID,connectionGeneration:connection,current:{value.current()})
   expect(try context.advance(runtimeGeneration:generation).confirmedAt==value.origin.confirmedAt,"context allows first slot equal to actual origin floor")
   let workflow=try WorkflowObservationLease(frame:value.origin,after:value.origin.confirmedAt,runtimeGeneration:generation,selectedDeviceID:value.executor.ble.selectedID,connectionGeneration:connection,current:{value.current()})
   var refused=false;do {_=try workflow.advance(runtimeGeneration:generation)}catch let e as WorkflowLeaseFailure {refused=e.predicates.contains(.confirmationAfterBoundary)}
   expect(refused,"workflow still rejects equality to its real external after boundary")
   rows.append(["case":"context JSON/floor and workflow strict Date boundary"]);try publish()
  }
  do {
   let value=try await fixture()
   value.runtime=PhoneHarnessRuntime(executor:value.executor,memoryURL:work.appendingPathComponent("nonregressing-final-floor.json"),recognize:{[unowned value] _ in
    value.fullCalls += 1;try await Task.sleep(nanoseconds:300_000_000)
    value.capture.frozenFrame=contextAuditIdle(previous:value.origin,now:Date(),captureID:value.origin.captureID!,isFullDisplay:true)
    return [.init(id:"marker",label:"Synthetic marker",rect:.init(x:0.2,y:0.3,width:0.5,height:0.1),source:"ocr")]
   },contextCurrent:{[unowned value] in value.current()})
   value.runtime.savedWorkflowContext={[unowned value] in value.capture.frozenFrame=value.origin;return "{}"}
   let(error,predicates,_)=await invoke(value,"late-floor-regression")
   expect(error != nil && predicates==["confirmationNotRegressed"] && ModelProbe.calls==0,"return gate inherits post-OCR actual floor even when regressed frame remains within1.5s")
   rows.append(["case":"late-floor-regression","predicates":predicates,"modelBoundaryCalls":ModelProbe.calls]);try publish()
  }
  for mode in ["accepted","final-JPEG","final-cancel"] {
   let name="metrics-"+mode,value=try await fixture();install(value,name)
   if mode != "accepted" {value.stage="final";value.fault=mode=="final-JPEG" ? "currentJPEGMatches":"cancel"}
   let metrics=RunMetricsRecorder(taskID:UUID(),versions:.init(appVersion:"synthetic",appBuild:"synthetic",
    sourceRevision:"synthetic",harnessVersion:"synthetic",firmwareVersion:"synthetic",model:"none",endpointHost:"none",
    device:"synthetic",operatingSystem:"synthetic",executionKind:.offlineReplay),directory:nil)
   value.runtime.metrics=metrics
   let(error,predicates,_)=await invoke(value,name)
   let spans=metrics.snapshot.spans,ocr=spans.filter{$0.category == .ocr},contextGates=spans.filter{$0.label=="harness.context-lease-binding"}
   expect(ocr.count==1 && ocr[0].outcome == .completed,name+": full OCR returned once; completion is not adopted-result authority")
   expect(contextGates.count==3 && contextGates.allSatisfy{$0.category == .verification},name+": all three context gates are fixed verification spans")
   let expected:RunStageOutcome=mode=="accepted" ? .completed:mode=="final-JPEG" ? .failed:.cancelled
   expect(contextGates.last?.outcome==expected && (error==nil)==(mode=="accepted") && ModelProbe.calls==(mode=="accepted" ? 1:0),name+": terminal gate and original result/cancellation remain observable")
   rows.append(["case":name,"error":error ?? "none","predicates":predicates,"modelBoundaryCalls":ModelProbe.calls,
    "fullOCR":value.fullCalls,"verificationOutcomes":contextGates.map{$0.outcome?.rawValue ?? "unfinished"}]);try publish()
  }
  try publish(true)
  print("ContextLease: \(checks); cases=\(rows.count); failures=\(failures)")
  guard failures.isEmpty else {throw AgentError.message("ContextLease assertions failed: "+failures.joined(separator:"; "))}
 }
}
