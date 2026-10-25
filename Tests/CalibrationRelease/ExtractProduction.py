#!/usr/bin/env python3
"""Actual CalibrationModel + neutral release path; only low I/O is synthetic."""
from pathlib import Path
import hashlib,json,sys
root=Path(__file__).resolve().parents[2];out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
def member(text,signature):
 assert text.count(signature)==1,(signature,text.count(signature))
 start=text.index(signature);cursor=text.index('{',start)+1;depth=1
 while depth:
  depth+=(text[cursor]=='{')-(text[cursor]=='}');cursor+=1
 return text[start:cursor]
cal=(root/'PhoneAgent/Views/CalibrationView.swift').read_text()
original=cal[:cal.index('\nstruct CalibrationView:')]
compiled=original.replace('import UIKit','import CoreGraphics')
path='URL.documentsDirectory.appendingPathComponent("calibration-diagnostics.log")'
assert compiled.count(path)==1
compiled=compiled.replace(path,'CalibrationReleaseFixture.recordURL')
assert compiled==original.replace('import UIKit','import CoreGraphics').replace(path,'CalibrationReleaseFixture.recordURL')
(out/'CalibrationModel.swift').write_text(compiled)
ble=(root/'PhoneAgent/Services/BLETransport.swift').read_text()
start=ble.index('    private lazy var releaseController =');end=ble.index('    var ready:',start)
methods=ble[start:end]+'\n'+'\n'.join(member(ble,sig) for sig in [
 '    @discardableResult\n    func send(_ op:', '    private func writeCommand(',
 '    @discardableResult func release(', '    private func clear()',
 '    func peripheral(_ p: CBPeripheral, didWriteValueFor'])
env=(root/'Tests/CalibrationRelease/Environment.swift').read_text();assert env.count('// PRODUCTION_BLE_MEMBERS')==1
(out/'Environment.swift').write_text(env.replace('// PRODUCTION_BLE_MEMBERS',methods))
files=['PhoneAgent/Views/CalibrationView.swift','PhoneAgent/Services/BLETransport.swift','Shared/InputReleaseController.swift','Shared/AgentModels.swift','Shared/MouseProtocol.swift','Tests/CalibrationRelease/Environment.swift','Tests/CalibrationRelease/ExtractProduction.py','Tests/CalibrationRelease/main.swift','Tests/CalibrationRelease/run.sh']
(out/'source-hashes.json').write_text(json.dumps({'files':{p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in files},
 'entireOriginalModelSHA256':hashlib.sha256(original.encode()).hexdigest(),'compiledModelSHA256':hashlib.sha256(compiled.encode()).hexdigest(),
 'extractedBLEMembersSHA256':hashlib.sha256(methods.encode()).hexdigest(),
 'modelOnlyChanges':['UIKit import becomes CoreGraphics on host','diagnostics file destination is private synthetic temp'],
 'noCoreBluetoothInitialization':True,'noDocumentsWrites':True},indent=2)+'\n')
