from pathlib import Path
import argparse,subprocess,json,hashlib,sys
ux=Path(__file__).resolve().parent;root=ux.parents[1]
p=argparse.ArgumentParser(description='Replay the real card policy and Shared parser from a selected production source root; no simulator or device.')
p.add_argument('--source-root',type=Path);p.add_argument('--shared-source-root',type=Path);p.add_argument('--output-dir',type=Path)
a=p.parse_args();source_root=(a.source_root or ux.parents[1]).resolve();shared_root=(a.shared_source_root or (source_root if a.source_root else root)).resolve()
out=(a.output_dir or (ux/'tests'/('replay-'+source_root.parent.name) if a.source_root else ux/'tests')).resolve();out.mkdir(parents=True,exist_ok=True)
inputs=[source_root/'PhoneAgent/Views/CtripFlightCards.swift',shared_root/'Shared/ComposerAttachment.swift',shared_root/'Shared/AssistantConversationContext.swift',shared_root/'Shared/ConversationUnderstanding.swift',shared_root/'Shared/NativeTaskResult.swift']
def hashes():return {str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs}
before=hashes()
subprocess.run(['python3',str(ux/'extract-policy.py'),'--source-root',str(source_root),'--output-dir',str(out)],check=True)
args=['xcrun','swiftc','-parse-as-library','-module-cache-path',str(out/'module-cache'),str(inputs[1]),str(inputs[2]),str(inputs[3]),str(inputs[4]),str(out/'ProductionPolicy.swift'),str(ux/'main.swift'),'-o',str(out/'checks')]
r=subprocess.run(args,capture_output=True,text=True);(out/'host-compile.log').write_text(r.stdout+r.stderr)
status={'source_root':str(source_root),'shared_source_root':str(shared_root),'input_hashes_before':before,'compile_exit_code':r.returncode,'command':args,'device_or_simulator_started':False}
if r.returncode:
 print(r.stdout+r.stderr,file=sys.stderr)
 (out/'host-verification.json').write_text(json.dumps(status,indent=2)+'\n');raise SystemExit(r.returncode)
r=subprocess.run([str(out/'checks'),str(ux/'Fixtures/fresh-flight-response.json')],capture_output=True,text=True);(out/'results.json').write_text(r.stdout);(out/'runtime.log').write_text(r.stderr)
after=hashes();status.update(run_exit_code=r.returncode,input_hashes_after=after,sources_stable=before==after);(out/'host-verification.json').write_text(json.dumps(status,indent=2)+'\n')
if r.returncode:raise SystemExit(r.returncode)
data=json.loads(r.stdout);print(json.dumps({'passed':data['passed'],'total':data['total'],'sources_stable':before==after,'output_dir':str(out),'failed':[x for x in data['checks'] if not x['passed']]}))
if before!=after:raise SystemExit('Production input source changed during replay; rerun after integration is stable.')
