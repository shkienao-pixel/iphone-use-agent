from pathlib import Path
import hashlib,json,sys
root,target=map(Path,sys.argv[1:]); target.mkdir(exist_ok=False)
s=(root/'PhoneAgent/PhoneAgentViewModel.swift').read_text()
marker='extension PhoneAgentViewModel {\n    private func queuedSnapshot()'
a=s.index(marker)
queue=s[a:]
assert queue.rstrip().endswith('}')
(target/'QueueController.swift').write_text((root/'Tests/ScreenTaskQueue/QueueEnvironment.swift').read_text()+'\n'+queue)
(target/'extraction.json').write_text(json.dumps({'completeQueueExtension':True,'substitutions':[],'sourceSHA256':hashlib.sha256(queue.encode()).hexdigest(),'scope':'Actual entire queue extension, full AgentEngine and queue/history stores; synthetic capture/model/BLE/permissions/UI'},indent=2))
print('ScreenTaskQueue: exact complete production queue extension extracted without substitutions')
