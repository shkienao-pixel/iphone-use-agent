from pathlib import Path
import subprocess, tempfile, json, re, sys
root=Path(__file__).resolve().parents[2]
out=Path(sys.argv[1]) if len(sys.argv)>1 else Path(tempfile.mkdtemp(prefix='sela-flight-selection-'))
out.mkdir(parents=True,exist_ok=True)
coordinator=(root/'PhoneAgent/Services/UnifiedConversationCoordinator.swift').read_text()
start=coordinator.index('    func openConversationFlight(')
end=re.search(r'\n}\s*\n(?=struct CtripFlightHandoffOrigin)',coordinator[start:])
assert end
body='import Foundation\n@MainActor extension PhoneAgentViewModel {\n'+coordinator[start:start+end.start()]+'\n}\n\n'+coordinator[start+end.end():]
(out/'ProductionFlightOpen.swift').write_text(body)
conversation=(root/'PhoneAgent/Services/AssistantConversation.swift').read_text()
a=conversation.index('    private var flightOpeningVisibleOwners = ')
b=conversation.index('    static let maximumParallelConversations',a)
lease=conversation[a:b]
a=conversation.index('    @discardableResult\n    func claimPresentation(')
b=conversation.index('    /// Navigation must not terminate',a)
lease+=conversation[a:b]
(root/'Tests/FlightSelection/ConversationStub.swift').exists() or sys.exit('Missing stub')
stub=(root/'Tests/FlightSelection/ConversationStub.swift').read_text().replace('// INSERT_PRODUCTION_LEASE',lease)
(out/'ConversationStub.swift').write_text(stub)
fake=(root/'Tests/CtripHandoff/FakeUIKit.swift').read_text()
(out/'FakeUIKit.swift').write_text(fake)
inputs=['Shared/ComposerAttachment.swift','Shared/NativeTaskResult.swift','Shared/AssistantConversationContext.swift','Shared/ConversationUnderstanding.swift','Tests/FlightSelection/main.swift']
cmd=['xcrun','swiftc','-parse-as-library','-module-cache-path',str(out/'module-cache'),*[str(root/p) for p in inputs],str(out/'ProductionFlightOpen.swift'),str(out/'ConversationStub.swift'),str(out/'FakeUIKit.swift'),'-o',str(out/'checks')]
r=subprocess.run(cmd,capture_output=True,text=True);(out/'compile.log').write_text(r.stdout+r.stderr)
if r.returncode: print(r.stdout+r.stderr);sys.exit(r.returncode)
r=subprocess.run([str(out/'checks')],capture_output=True,text=True);(out/'results.json').write_text(r.stdout);(out/'runtime.log').write_text(r.stderr)
data=json.loads(r.stdout) if r.stdout else {};print(json.dumps({'passed':data.get('passed'),'total':data.get('total'),'failed':[v for v in data.get('checks',[]) if not v['passed']], 'error':r.stderr[-2000:],'output':str(out),'actual_production_lease_and_bridge_extracted':True,'device_actions':False}))
if r.returncode: sys.exit(r.returncode)
lifecycle=['xcrun','swiftc','-parse-as-library','-module-cache-path',str(out/'module-cache'),
    *[str(root/p) for p in inputs[:4]],str(root/'PhoneAgent/Stores/AssistantConversationStore.swift'),
    str(root/'PhoneAgent/Services/AssistantConversation.swift'),str(root/'Tests/AssistantConversation/Environment.swift'),
    str(root/'Tests/FlightSelection/Lifecycle.swift'),'-o',str(out/'lifecycle')]
r=subprocess.run(lifecycle,capture_output=True,text=True);(out/'lifecycle-compile.log').write_text(r.stdout+r.stderr)
if r.returncode: print(r.stdout+r.stderr);sys.exit(r.returncode)
r=subprocess.run([str(out/'lifecycle')],capture_output=True,text=True);(out/'lifecycle-results.json').write_text(r.stdout);(out/'lifecycle-runtime.log').write_text(r.stderr)
print(r.stdout or r.stderr);sys.exit(r.returncode)
