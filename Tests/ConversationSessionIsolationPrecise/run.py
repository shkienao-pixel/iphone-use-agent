from pathlib import Path
import subprocess,json,hashlib,argparse
p=argparse.ArgumentParser();p.add_argument('--source-root');a=p.parse_args()
out=Path(__file__).resolve().parent;root=Path(a.source_root).resolve() if a.source_root else out.parent/'source'
subprocess.run(['python3',str(out/'extract.py'),'--source-root',str(root)],check=True)
files=['Shared/NativeTaskResult.swift','Shared/ComposerAttachment.swift','Shared/AssistantConversationContext.swift','Shared/ConversationUnderstanding.swift','PhoneAgent/Stores/AssistantConversationStore.swift','PhoneAgent/Services/DidiChatSimulationRegistry.swift','PhoneAgent/Services/AssistantConversation.swift']
args=['xcrun','swiftc','-parse-as-library','-module-cache-path',str(out.parent/'tests/module-cache')]+[str(root/f) for f in files]+[str(out/'Environment.swift'),str(out/'Production.swift'),str(out/'main.swift'),'-o',str(out/'checks')]
r=subprocess.run(args,capture_output=True,text=True);(out/'compile.log').write_text(r.stdout+r.stderr)
if r.returncode:print(r.stderr[-10000:]);raise SystemExit(r.returncode)
r=subprocess.run([str(out/'checks'),str(out/'results.json'),str(out/'store-fixtures')],capture_output=True,text=True);(out/'run.log').write_text(r.stdout+r.stderr)
(out/'verification.json').write_text(json.dumps({'source_root':str(root),'compile_exit_code':0,'run_exit_code':r.returncode,'source_sha256':{f:hashlib.sha256((root/f).read_bytes()).hexdigest() for f in files},'extraction':json.loads((out/'extraction.json').read_text())},indent=2)+'\n');print(r.stdout);print(r.stderr[-1000:]);raise SystemExit(r.returncode)
