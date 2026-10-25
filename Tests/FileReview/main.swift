import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Error boundary required by PhoneHarness; no harness business logic is replaced.
enum AgentError:Error {case message(String)}

@main struct FileReviewChecks {
    @MainActor static func main() async throws {
        var checks=0
        func expect(_ value:Bool,_ message:String) {precondition(value,message);checks+=1}
        func rejects(_ message:String,_ body:() throws->Void) {do {try body();preconditionFailure(message)} catch {checks+=1}}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("file-review-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=FileTransferStore(url:root.appendingPathComponent("store/checkpoints.json"))
        var artifacts:[FileTransferArtifact]=[]
        for index in 1...3 {
            let url=root.appendingPathComponent("original-\(index).bin")
            try Data("actual original \(index)".utf8).write(to:url)
            artifacts.append(try store.importFile(at:url,sourceID:"original-source-\(index)",mediaType:"public.data"))
        }
        let ids=artifacts.map(\.id),coordinator=FileTransferCoordinator(store:store)
        let environment=FileTransferEnvironment(deviceKey:"offline",accessoryKey:"fixture",captureSessionID:UUID().uuidString,foreground:true)
        var presentations=0
        let initial=try await coordinator.beginNativeShare(operationID:"review-batch-1",taskID:"review-task-1",artifactIDs:ids,requestedRecipientDescription:"synthetic-only",environment:environment) {_ in presentations+=1;return .dismissedOrUnknown}
        expect(initial.pending && initial.items.allSatisfy {$0.state == .unknown},"Native uncertainty stays unknown")
        let diagnostics=WorkflowDiagnosticsStore(directory:root.appendingPathComponent("diagnostics"))
        let context=CGContext(data:nil,width:16,height:16,bitsPerComponent:8,bytesPerRow:64,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        let jpeg=NSMutableData(),destination=CGImageDestinationCreateWithData(jpeg,UTType.jpeg.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil);precondition(CGImageDestinationFinalize(destination))
        let at=Date()
        let snapshot=PhoneUISnapshot(deviceKey:"offline",scene:"fixture",elements:[],capturedAt:at,blockingOverlay:false)
        let protected=try diagnostics.record(jpeg:jpeg as Data,context:.init(operationID:initial.id,boundary:.pendingSubmission,captureID:UUID(),capturedAt:at,confirmedAt:at,snapshot:snapshot,protectPendingSubmission:true))
        expect(try FileTransferReviewDiagnostics.reconcile(fileStore:store,diagnostics:diagnostics)==0 && diagnostics.records.first!.isProtectedPendingSubmission,"Unknown durable receipt cannot release diagnostic protection")
        let first=FileTransferReviewRequest(operationID:initial.id,artifactIDs:[ids[0]],resolution:.userReportsSubmitted,detail:"实际测试边界：人工仅检查第一项")
        try first.validate(operation:initial)
        var value=try coordinator.resolveReviewed(operationID:first.operationID,artifactIDs:first.artifactIDs,resolution:first.resolution,detail:first.detail)
        expect(value.items[0].state == .userReportedSubmitted && value.items[1].state == .unknown && value.items[2].state == .unknown,"Only selected item changes")
        expect(try FileTransferReviewDiagnostics.reconcile(fileStore:store,diagnostics:diagnostics)==0,"Partial human review cannot release batch protection")
        expect(store.hasPendingReview && value.humanReviews?.count == 1,"Other unresolved files keep pending protection")
        expect(value.humanReviews?.first?.artifactIDs == first.artifactIDs && value.humanReviews?.first?.detail == first.detail,"Human scope and actual note survive in receipt")
        let reload=FileTransferStore(url:store.url)
        expect(try reload.operation(id:initial.id)?.humanReviews == value.humanReviews,"Audit survives process reload")
        rejects("Resolved stale selection rejected by current UI request") {try first.validate(operation:value)}
        rejects("Coordinator independently rejects stale native selection") {_ = try coordinator.resolveReviewed(operationID:first.operationID,artifactIDs:first.artifactIDs,resolution:.userConfirmsNotSubmitted,detail:"stale")}
        for selection in [[],[ids[1],ids[1]],[UUID()]] {
            rejects("Invalid selection cannot change receipt") {try FileTransferReviewRequest(operationID:initial.id,artifactIDs:selection,resolution:.stillUnknown,detail:"note").validate(operation:value)}
        }
        rejects("Other operation cannot borrow findings") {try FileTransferReviewRequest(operationID:"another-batch",artifactIDs:[ids[1]],resolution:.stillUnknown,detail:"note").validate(operation:value)}
        rejects("Blank finding not saved") {try FileTransferReviewRequest(operationID:initial.id,artifactIDs:[ids[1]],resolution:.stillUnknown,detail:"  \n").validate(operation:value)}
        rejects("Unbounded finding not saved") {try FileTransferReviewRequest(operationID:initial.id,artifactIDs:[ids[1]],resolution:.stillUnknown,detail:String(repeating:"x",count:1001)).validate(operation:value)}
        value=try coordinator.resolveReviewed(operationID:initial.id,artifactIDs:[ids[1]],resolution:.stillUnknown,detail:"第二项未能核实")
        expect(try FileTransferReviewDiagnostics.reconcile(fileStore:store,diagnostics:diagnostics)==0,"Still unknown findings cannot release screenshot protection")
        expect(value.humanReviews?.count == 2 && value.items[1].state == .unknown,"Unknown finding is audited without unlocking")
        value=try coordinator.resolveReviewed(operationID:initial.id,artifactIDs:[ids[1]],resolution:.userConfirmsNotSubmitted,detail:"第二项已独立确认未提交")
        expect(value.items[1].state == .confirmedFailed && value.items[2].pending,"Mixed outcomes retain unselected unknown")
        value=try coordinator.resolveReviewed(operationID:initial.id,artifactIDs:[ids[2]],resolution:.userReportsSubmitted,detail:"第三项已独立检查")
        expect(!value.pending && !store.hasPendingReview,"Only all individually resolved findings release pending protection")
        expect(value.humanReviews?.map(\.resolution) == [.userReportsSubmitted,.stillUnknown,.userConfirmsNotSubmitted,.userReportsSubmitted],"All distinct human findings remain ordered")
        expect(value.stage != .complete && value.items.allSatisfy {$0.state != .observedSent},"Human findings never become verified sending or delivery")
        // The native export path can fail after audit persistence. Recovery
        // reads the durable human outcome, never requires another UI review.
        let exportBlocker=root.appendingPathComponent("blocked-export")
        try Data("block directory".utf8).write(to:exportBlocker)
        rejects("A failed optional export does not alter the persisted audit") {try store.exportData().write(to:exportBlocker.appendingPathComponent("file.json"))}
        let restartedFileStore=FileTransferStore(url:store.url)
        let restartedDiagnostics=WorkflowDiagnosticsStore(directory:diagnostics.directory)
        expect(try FileTransferReviewDiagnostics.reconcile(fileStore:restartedFileStore,diagnostics:restartedDiagnostics)==1,"Restart releases protection using completed persisted human findings even after export failure")
        expect(restartedDiagnostics.records.first {$0.id==protected.id}?.isProtectedPendingSubmission == false,"All resolved screenshots can be cleaned without re-reviewing nonpending items")
        expect(try FileTransferReviewDiagnostics.reconcile(fileStore:restartedFileStore,diagnostics:restartedDiagnostics)==0,"Reconciliation is idempotent and never initiates submission")
        expect(presentations == 1,"Review never presents or resends")
        let encoder=JSONEncoder()
        var legacy=try JSONSerialization.jsonObject(with:encoder.encode(value)) as! [String:Any]
        legacy.removeValue(forKey:"humanReviews")
        let migrated=try JSONDecoder().decode(FileTransferOperation.self,from:JSONSerialization.data(withJSONObject:legacy))
        try migrated.validate()
        expect(migrated.humanReviews == nil && migrated.items == value.items,"Build74 receipt migration retains its original states")
        var budget=initial
        budget.operationID="audit-budget-batch";budget.taskID="audit-budget-task"
        budget.humanReviews=(0..<450).map {_ in .init(id:UUID(),artifactIDs:[ids[0]],resolution:.stillUnknown,detail:"historical synthetic unknown finding",reviewedAt:initial.updatedAt)}
        try store.put(budget)
        rejects("Repeated unknown findings leave room for decisive review") {_ = try coordinator.resolveReviewed(operationID:budget.id,artifactIDs:[ids[0]],resolution:.stillUnknown,detail:"still unknown")}
        let budgetResolved=try coordinator.resolveReviewed(operationID:budget.id,artifactIDs:ids,resolution:.userReportsSubmitted,detail:"all originals independently checked")
        expect(!budgetResolved.pending && budgetResolved.humanReviews?.count==451,"Audit cap reserves definitive decisions and retains every previous finding")
        print("FileReview: \(checks) production request/coordinator/audit checks passed; temporary originals and synthetic share only")
    }
}
