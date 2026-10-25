#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,sys
root,out=[Path(s).resolve() for s in sys.argv[1:]]
out.mkdir(parents=True,exist_ok=True)
def member(text, signature):
 assert text.count(signature)==1,(signature,text.count(signature))
 a=text.index(signature);b=text.index("{",a)+1;depth=1
 while depth:
  depth+=(text[b]=="{")-(text[b]=="}");b+=1
 return text[a:b]
content=(root/"PhoneAgent/ContentView.swift").read_text()
nav=(root/"PhoneAgent/Models/WorkspaceNavigation.swift").read_text()
contracts={
 "bothSidebarCallbacks": "onNewTask: requestNewTask," in content and "onNewConversation: requestNewConversation" in content,
 "noDiscardConfirmationOrResetBranch": all(s not in content for s in ["清空未提交的任务？", "discardingDraft", "private func resetDraft()", "case create, reset, open(UUID)", "taskAction: .create", "taskAction: .reset"]),
 "homeUsesUnifiedComposer": "if displayedRecord == nil {" in content and "unifiedConversation" in member(content,"    @ViewBuilder private var taskPage:"),
 "originalPauseRuleRetained": "case .assistant, .memory, .workbench," in nav,
}
assert all(contracts.values()),contracts
coordinator=(root/"PhoneAgent/Services/UnifiedConversationCoordinator.swift").read_text()
members={k:member(content,v) for k,v in {
 "assistantActionType":"    private enum AssistantNavigationAction",
 "taskActionType":"    private enum TaskNavigationAction",
 "navigate":"    private func navigate(",
 "completeNavigation":"    private func completeNavigation(",
 "applyAssistantAction":"    private func applyAssistantAction(",
 "applyTaskAction":"    private func applyTaskAction(",
 "preserveLegacyDraft":"    private func preserveLegacyTaskDraft()",
 "newTask":"    private func requestNewTask()",
 "newConversation":"    private func requestNewConversation()",
}.items()}
reuse=member(coordinator,"    @discardableResult\n    func reuseTaskInNewConversation(")
workspace=member(nav,"enum WorkspaceDestination:")
scaffold='import Foundation\n\nenum ExternalAppService: Hashable { case sample; var title: String { "App" } }\nenum NativeAppConnection: Hashable { case sample; var title: String { "Native" } }\nstruct WorkspaceSheet {}\nenum TaskScreen: Hashable { case draft, conversation(UUID) }\n@MainActor final class NavigationEngine {\n    let id = UUID()\n    var currentRecord: PhoneTaskRecord?\n    var running = false, releasing = false, paused = false\n}\n@MainActor final class NavigationHistory { var records: [PhoneTaskRecord] = [] }\nstruct NavigationQueueItem { var record: PhoneTaskRecord }\n@MainActor final class NavigationQueue { var items: [NavigationQueueItem] = [] }\nstruct NavigationPending { var goal: String }\n@MainActor final class NavigationModel {\n    let conversation: AssistantConversation\n    let engine = NavigationEngine(), history = NavigationHistory(), taskQueue = NavigationQueue()\n    var pendingConversationTask: NavigationPending?\n    var goal = "遗留任务原文", taskPlan = ["保留旧计划"]\n    var legacyAttachments: [ComposerAttachment] = []\n    var queueIDs = [UUID()], voicePending = false, workbenchHasDraft = false, notice = ""\n    var pauseCalls = 0, engineError = "", pauseNotice = ""\n    // PRODUCTION_REUSE\n    init(_ conversation: AssistantConversation) { self.conversation = conversation }\n    @discardableResult func pauseTask() -> Bool {\n        pauseCalls += 1; engine.running = false; engine.paused = true; if !pauseNotice.isEmpty { notice = pauseNotice }; return true\n    }\n}\n@MainActor final class NavigationAttachmentDraft { var items: [ComposerAttachment] = [] }\n@MainActor final class NavigationHarness {\n    let model: NavigationModel\n    var selectedDestination = WorkspaceDestination.tasks\n    var composing = false, modeSwitcherOpen = false, navigationForward = false, settingsPageOpen = false\n    var toolsPath: [WorkspaceDestination] = [], pendingDestination: WorkspaceDestination?\n    private var pendingDestinationSheet: WorkspaceSheet?, pendingAssistantAction: AssistantNavigationAction?, pendingTaskAction: TaskNavigationAction?\n    var confirmingWorkbenchExit = false, screen = TaskScreen.draft, expandedSteps = false, followLatest = false\n    let attachmentDraft = NavigationAttachmentDraft()\n    var attachmentSnapshots: [TaskScreen: [ComposerAttachment]] = [:]\n    var sidebarOpen = true, presented: WorkspaceSheet?\n    init(_ model: NavigationModel) { self.model = model }\n    func setSidebar(_ value: Bool) { sidebarOpen = value }\n    func present(_ sheet: WorkspaceSheet) { presented = sheet }\n    func pressNewTask() { requestNewTask() }\n    func pressNewConversation() { requestNewConversation() }\n    func openChat(_ id: UUID) { navigate(.assistant, assistantAction: .open(id)) }\n    // PRODUCTION_MEMBERS\n}\n'
(out/"NavigationEnvironment.swift").write_text(workspace+"\n"+scaffold.replace("    // PRODUCTION_MEMBERS","\n".join(members.values())).replace("    // PRODUCTION_REUSE",reuse))
agent=member((root/"Shared/AgentModels.swift").read_text(),"enum AgentError: LocalizedError")
(out/"AgentError.swift").write_text("import Foundation\n"+agent+"\n")
boundaries=(root/"Tests/AssistantConversation/Environment.swift").read_text()
# Newer root fixtures already define AgentError; keep the tested real enum and
# remove only that duplicate synthetic boundary declaration.
if "enum AgentError: LocalizedError" in boundaries:
 boundaries=boundaries.replace(member(boundaries,"enum AgentError: LocalizedError"),"",1)
marker="    var logs: [AgentLogEntry] = []"
assert boundaries.count(marker)==1
(out/"ModelBoundaries.swift").write_text(boundaries.replace(marker,marker+"\n    var attachments: [ComposerAttachment]? = nil\n    var effectiveGoalOverride: String? = nil",1).replace("var effectiveGoal: String { goal }", "var effectiveGoal: String { effectiveGoalOverride ?? goal }"))
(out/"extraction.json").write_text(json.dumps({"contracts":contracts,"completeProductionMethods":True,"substitutions":[],"methodSHA256":{k:hashlib.sha256(v.encode()).hexdigest() for k,v in members.items()},"reuseSHA256":hashlib.sha256(reuse.encode()).hexdigest(),"sourceSHA256":{n:hashlib.sha256((root/n).read_bytes()).hexdigest() for n in ["PhoneAgent/ContentView.swift","PhoneAgent/Services/UnifiedConversationCoordinator.swift","PhoneAgent/Models/WorkspaceNavigation.swift"]},"limits":"Real complete ContentView navigation methods and real conversation/store. SwiftUI rendering, platform presentation and engine pause side effects are synthetic boundaries; no device/model/network."},indent=2)+"\n")
