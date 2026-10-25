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
print('Native planning recovery wiring: only model request is retried; native dispatch stays outside')
