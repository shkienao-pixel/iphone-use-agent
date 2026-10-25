from pathlib import Path
import sys

root = Path(sys.argv[1])
text = (root / 'PhoneAgent/Services/AgentEngine.swift').read_text()
native = text[text.index('    private func runTools('):text.index('    private func run(goal:')]
assert native.count('NativePlanningRecovery.nextAction(') == 1
request = native.split('request: {', 1)[1].split('wait:', 1)[0]
assert request.count('client.nextAction(') == 1
assert 'executeTool(' not in request and 'systemTool(' not in request
assert 'self.stillCurrent(token)' in native and 'self.measuredWait(nanoseconds: $0)' in native
assert native.index('NativePlanningRecovery.nextAction(') < native.index('switch action.kind')
assert native.index('switch action.kind') < native.index('try await executeTool(')
assert native.count('try await executeTool(') == 1
client = (root / 'PhoneAgent/Services/VisionClient.swift').read_text()
load = client[client.index('    private func load('):client.index('    func checkPlanInference(')]
assert load.count('NativePlanningServiceFailure.response(') == 2
assert load.index('ChatGPTPlanStore.active(id)') < load.index('NativePlanningServiceFailure.response(')
assert 'retryAfter: http.value(forHTTPHeaderField: "Retry-After")' in load
assert 'ChatGPTPlanDiagnostics.record(result.0' in load
print('Native planning recovery wiring: only model request is retried; native dispatch stays outside')
