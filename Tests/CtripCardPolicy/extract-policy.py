from pathlib import Path
import argparse,hashlib,json
ux=Path(__file__).resolve().parent
p=argparse.ArgumentParser(description='Extract the pure card presentation policy from the chosen actual production UI source.')
p.add_argument('--source-root',type=Path,default=ux.parents[1]);p.add_argument('--output-dir',type=Path,default=ux/'tests')
a=p.parse_args();source_root=a.source_root.resolve();out=a.output_dir.resolve();out.mkdir(parents=True,exist_ok=True)
source=source_root/'PhoneAgent/Views/CtripFlightCards.swift';text=source.read_text()
start=text.index('enum CtripFlightCardPresentationPolicy {');end=text.index('\nstruct CtripFlightCards: View {',start)
policy='import Foundation\n\n'+text[start:end];(out/'ProductionPolicy.swift').write_text(policy)
result={'source_root':str(source_root),'source_file':str(source),'production_source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'extracted_policy_sha256':hashlib.sha256(policy.encode()).hexdigest()}
(out/'extraction-hashes.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
