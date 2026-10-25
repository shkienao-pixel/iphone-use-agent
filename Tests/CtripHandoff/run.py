from pathlib import Path
import argparse,subprocess,json,hashlib,re,sys
ux=Path(__file__).resolve().parent
p=argparse.ArgumentParser(description='Replay real handoff production methods from a selected source root against fake clipboard/app APIs; no device or app is opened.')
p.add_argument('--source-root',type=Path)
p.add_argument('--shared-source-root',type=Path)
p.add_argument('--output-dir',type=Path)
p.add_argument('--require-chat-visibility',action='store_true',help='Fail rather than skip if the chat-origin visibility overload has not been integrated')
a=p.parse_args();source_root=(a.source_root or ux.parents[1]).resolve()
shared_root=(a.shared_source_root or (source_root if a.source_root else ux.parents[1])).resolve()
out=(a.output_dir or (ux/'tests'/('replay-'+source_root.parent.name) if a.source_root else ux/'tests')).resolve();out.mkdir(parents=True,exist_ok=True)
source=source_root/'PhoneAgent/Services/UnifiedConversationCoordinator.swift'
chat_guard=re.search(r'func bookFlight\(_ offer: CtripFlightOffer, origin: CtripFlightHandoffOrigin,\s*isVisible:',source.read_text()) is not None
if a.require_chat_visibility and not chat_guard: raise SystemExit('Selected source lacks the chat-origin visibility overload; apply chat-visibility.patch before this required replay.')
inputs=[source,shared_root/'Shared/ComposerAttachment.swift',shared_root/'Shared/AssistantConversationContext.swift',shared_root/'Shared/ConversationUnderstanding.swift',shared_root/'Shared/NativeTaskResult.swift']
def hashes():return {str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs}
before=hashes()
subprocess.run(['python3',str(ux/'extract.py'),'--source-root',str(source_root),'--output-dir',str(out)],check=True)
binary=out/'checks-final'
args=['xcrun','swiftc','-parse-as-library','-module-cache-path',str(out/'module-cache')]
if chat_guard: args+=['-D','CTRIP_CHAT_VISIBILITY_GUARD']
args += [str(inputs[1]),str(inputs[2]),str(inputs[3]),str(inputs[4]),str(ux/'VMStubs.swift'),str(ux/'FakeUIKit.swift'),str(out/'ProductionHandoff.swift'),str(ux/'main.swift'),'-o',str(binary)]
r=subprocess.run(args,capture_output=True,text=True);(out/'host-compile.log').write_text(r.stdout+r.stderr)
status={'source_root':str(source_root),'shared_source_root':str(shared_root),'source_sha256':before[str(source)],'input_hashes_before':before,'compile_exit_code':r.returncode,'command':args,'chat_visibility_test_included':chat_guard,'real_clipboard_or_app_api_called':False}
if r.returncode:
 print(r.stdout+r.stderr,file=sys.stderr)
 (out/'host-verification.json').write_text(json.dumps(status,indent=2)+'\n');raise SystemExit(r.returncode)
r=subprocess.run([str(binary)],capture_output=True,text=True);(out/'results.json').write_text(r.stdout);(out/'runtime.log').write_text(r.stderr)
after=hashes();status.update(run_exit_code=r.returncode,input_hashes_after=after,sources_stable=before==after)
(out/'host-verification.json').write_text(json.dumps(status,indent=2)+'\n')
if r.returncode:raise SystemExit(r.returncode)
data=json.loads(r.stdout);print(json.dumps({'passed':data['passed'],'total':data['total'],'sources_stable':before==after,'chat_visibility_test_included':chat_guard,'output_dir':str(out),'failed':[x for x in data['checks'] if not x['passed']]}))
if before!=after:raise SystemExit('Production input source changed during replay; rerun after integration is stable.')
