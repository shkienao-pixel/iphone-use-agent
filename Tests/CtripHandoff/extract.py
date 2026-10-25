from pathlib import Path
import argparse,hashlib,json,re
ux=Path(__file__).resolve().parent
parser=argparse.ArgumentParser(description='Extract the actual production Ctrip handoff methods, coordinator, and adapter without modifying their owning source.')
parser.add_argument('--source-root',type=Path,default=ux.parents[1])
parser.add_argument('--output-dir',type=Path,default=ux/'tests')
a=parser.parse_args();source_root=a.source_root.resolve();out=a.output_dir.resolve();out.mkdir(parents=True,exist_ok=True)
p=source_root/'PhoneAgent/Services/UnifiedConversationCoordinator.swift'
s=p.read_text();start=s.index('    func bookFlight(_ offer: CtripFlightOffer) {')
end=re.search(r'\n}\s*\n(?=struct CtripFlightHandoffOrigin)',s[start:])
if end is None: raise SystemExit('Could not locate the handoff extension boundary in actual production source')
end_start=start+end.start();type_start=start+end.end()
body='\n@MainActor extension PhoneAgentViewModel {\n'+s[start:end_start]+'\n}\n\n'+s[type_start:]
(out/'ProductionHandoff.swift').write_text('import Foundation\n'+body)
(out/'ProductionHandoffUIKit.swift').write_text('import Foundation\nimport UIKit\n'+body)
result={'source_root':str(source_root),'source_file':str(p),'source_sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'production_extract_sha256':hashlib.sha256(body.encode()).hexdigest()}
(out/'extraction-hashes.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
