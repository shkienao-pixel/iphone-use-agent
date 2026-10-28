from pathlib import Path
import hashlib,json,sys
root,out=map(Path,sys.argv[1:]);out.mkdir(parents=True,exist_ok=True)
def member(text,signature):
 assert text.count(signature)==1,signature
 start=text.index(signature); cursor=text.index('{',start)+1; depth=1
 while depth:
  depth+=(text[cursor]=='{')-(text[cursor]=='}');cursor+=1
 return text[start:cursor]
capture=(root/'PhoneAgent/Services/CaptureService.swift').read_text()
env=(root/'Tests/ProductState/Environment.swift').read_text()
env=env.replace(member(env,'struct ScreenFrame {'),member(capture,'struct ScreenFrame {'))
assert env.count('struct UIImage {')==1
env=env.replace('struct UIImage {','final class UIImage {')
env=env.replace('let cgImage: CGImage?','let cgImage: CGImage?\n    init(cgImage: CGImage) { self.cgImage = cgImage }')
assert env.count('return frozenFrame ?? ScreenFrame()')==1
env=env.replace('return frozenFrame ?? ScreenFrame()','return frozenFrame')
env=env.replace('var selectedID: String? = "offline-device"','var selectedID: String? = "offline-device"\n    var pointerConnectionGeneration = UUID()')
(out/'Environment.swift').write_text(env)
engine=(root/'PhoneAgent/Services/AgentEngine.swift').read_text()
(out/'HarnessInterface.swift').write_text('import Foundation\n'+engine[engine.index('/// Host-generated evidence'):engine.index('\nenum AgentPhase:')])
driver=(root/'PhoneAgent/Services/PhoneWorkflowCaptureDriver.swift').read_text()
(out/'DriverCore.swift').write_text(driver[:driver.index('\n@MainActor final class LiveXiaohongshuCollectionDriver:')])
start=capture.index('            let frame = ScreenFrame(image: previous.image, jpeg: previous.jpeg, capturedAt: previous.capturedAt,')
end=capture.index('\n            lastFrame = frame;',start)
(out/'IdleConstructor.swift').write_text('import Foundation\nfunc workflowLeaseIdleFrame(previous:ScreenFrame,now:Date,captureID:UUID,isFullDisplay:Bool)->ScreenFrame {\n'+capture[start:end]+'\n return frame\n}\n')
paths=['PhoneAgent/Services/CaptureService.swift','PhoneAgent/Services/PhoneHarnessRuntime.swift','PhoneAgent/Services/PhoneWorkflowCaptureDriver.swift','PhoneAgent/Services/WorkflowObservationLease.swift','Tests/ProductState/Environment.swift','PhoneAgent/Services/AgentEngine.swift','Shared/ComposerAttachment.swift','Shared/TaskCheckpointPolicy.swift']
(out/'extracted-source-sha256.json').write_text(json.dumps({p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths},indent=2)+'\n')
