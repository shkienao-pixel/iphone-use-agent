import Foundation

/// Both sides are the actual current Store: generic full validation versus the
/// restricted append API. This is not a second implementation of a validator.
@MainActor enum ChatAppendTransactionChecks {
    @MainActor private final class Checks {
        var count=0
        func expect(_ value:Bool,_ label:String) { count += 1;precondition(value,label) }
    }
    private struct Document:Codable { var version=1;var sessions:[ChatEvidenceSession] }
    private struct Raw:Encodable {
        var request:ChatReadRequest,frames:[ChatEvidenceFrame],messages:[ChatEvidenceMessage]
        var unmergedBatches:[ChatUnmergedBatch]?,pageSelection:ChatPageSelection?
        var state:ChatReadState,detail:String
        init(_ s:ChatEvidenceSession) { request=s.request;frames=s.frames;messages=s.messages;unmergedBatches=s.unmergedBatches;pageSelection=s.pageSelection;state=s.state;detail=s.detail }
    }
    private static func encode<T:Encodable>(_ value:T)throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return try encoder.encode(value)
    }
    private static func error(_ body:()throws->Void)->String? {
        do { try body();return nil } catch { return String(reflecting:error) }
    }
    private static func uuid(_ n:Int)->String { "00000000-0000-4000-8000-"+String(format:"%012llx",Int64(n+1)) }
    private static func claim(_ message:ChatEvidenceMessage)->ChatSummaryClaim {
        .init(category:.fact,statement:message.observation.text,citations:[.init(messageID:message.id,quote:message.observation.text)])
    }
    private static func segment(_ s:ChatEvidenceSession,_ n:Int=1)->ChatSummarySegment {
        .init(id:"cs-v2-"+uuid(n),messageIDs:s.selectedMessages.map(\.id),contextMessageIDs:[],claims:[claim(s.selectedMessages[0])],generatedAt:Date(timeIntervalSince1970:1_900_000_000),validationVersion:2)
    }
    private static func report(_ s:ChatEvidenceSession,_ segment:ChatSummarySegment)->ChatSummaryReport {
        .init(id:"cr-v2-"+uuid(50),scopeID:s.id,conversation:s.request.conversation,range:s.request.range,messageIDs:s.selectedMessages.map(\.id),segmentIDs:[segment.id],claims:segment.claims,warnings:["Fixed metadata is a Store test, not a phone result"],generatedAt:Date(timeIntervalSince1970:1_900_000_001),validationVersion:2)
    }
    private static func element(_ id:String,_ label:String,_ x:Double,_ y:Double,_ width:Double=0.18)->PhoneUIElement {
        .init(id:id,label:label,rect:.init(x:x-width/2,y:y-0.015,width:width,height:0.03),source:"ocr")
    }
    private static func fixture(_ scope:String)->ChatEvidenceSession {
        let epoch=Date(timeIntervalSince1970:1_700_000_000),captured=epoch.addingTimeInterval(100)
        let target=ChatConversationTarget(stableID:"wechat.builtin.file-transfer",title:"文件传输助手",deviceKey:"append-offline-fixture")
        let sources=[element("row-0","Synthetic fact one",0.75,0.32),element("row-1","Alice owns Friday",0.75,0.40),element("row-2","Correction Bob owns Monday",0.75,0.48)]
        let snapshot=PhoneUISnapshot(deviceKey:target.deviceKey,scene:"wechat.chat",elements:[element("back","微信",0.1,0.08),element("title",target.title,0.5,0.08),element("proof","可以在手机和电脑间互传文件",0.5,0.22,0.64),element("input","发送消息",0.4,0.9)]+sources,capturedAt:captured)
        // Explicit fixture known times/occurrences, not an OCR capability.
        let rows=sources.enumerated().map { index,source in ChatObservedMessage(platformMessageID:"fixture-occurrence-\(index)",speaker:"Fixture",sentAt:epoch.addingTimeInterval(Double(index)),text:source.label,anchor:.init(frameID:"fixture-frame",elementIDs:[source.id],rect:source.rect,capturedAt:captured)) }
        let frame=ChatEvidenceFrame(id:"fixture-frame",snapshot:snapshot,conversation:.init(stableID:target.stableID,title:target.title,kind:.builtInTransfer,evidenceElementIDs:["back","title","proof","input"]),rows:rows)
        var s=ChatEvidenceSession(request:.init(scopeID:scope,conversation:target,range:.time(start:epoch,end:epoch.addingTimeInterval(3)),maxPages:1))
        s.frames=[frame];s.messages=rows.enumerated().map { .init(id:"fixture-message-\($0.offset)",observation:$0.element,anchors:[$0.element.anchor]) };s.state = .partial;s.updatedAt=epoch
        return s
    }
    private static func withRaw(_ s:ChatEvidenceSession)->ChatEvidenceSession {
        var value=s,snapshot=s.frames[0].snapshot;snapshot.capturedAt=snapshot.capturedAt.addingTimeInterval(1)
        let rows=s.frames[0].rows.map { row->ChatObservedMessage in var row=row;row.anchor.frameID="raw-batch";row.anchor.capturedAt=snapshot.capturedAt;return row }
        value.unmergedBatches=[.init(id:"raw-batch",snapshot:snapshot,rows:rows,captureSessionID:nil,scopeID:s.id,requestedConversation:s.request.conversation,direction:.older,reason:.unverifiedOccurrenceContinuity,sourceFrameID:s.frames[0].id)]
        return value
    }
    @MainActor private final class Pair {
        let generic:ChatEvidenceStore,append:ChatEvidenceStore,left:URL,right:URL,checks:Checks
        init(_ sessions:[ChatEvidenceSession],_ name:String,_ folder:URL,_ checks:Checks)throws {
            self.checks=checks
            let base=folder.appendingPathComponent(name);try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
            left=base.appendingPathComponent("generic.json");right=base.appendingPathComponent("append.json")
            let data=try ChatAppendTransactionChecks.encode(Document(sessions:sessions));try data.write(to:left,options:.atomic);try data.write(to:right,options:.atomic)
            generic=ChatEvidenceStore(url:left);append=ChatEvidenceStore(url:right)
            checks.expect(generic.sessions.count==sessions.count && append.sessions.count==sessions.count,"Append fixture must pass actual native init")
        }
        func same(_ label:String)throws {
            checks.expect(try Data(contentsOf:left)==Data(contentsOf:right),"Complete checkpoint bytes: "+label)
            checks.expect(try ChatAppendTransactionChecks.encode(Document(sessions:generic.sessions))==ChatAppendTransactionChecks.encode(Document(sessions:append.sessions)),"Complete memory fields: "+label)
            checks.expect(ChatEvidenceStore(url:right).sessions==append.sessions,"Append checkpoint full-native reload: "+label)
            let mode=(try FileManager.default.attributesOfItem(atPath:right.path)[.posixPermissions] as! NSNumber).intValue & 0o777
            checks.expect(mode==0o600,"Actual append checkpoint permissions stay0600")
        }
        func genericSummary(_ value:ChatSummarySegment,_ id:String,_ expected:[String])throws {
            var s=try generic.session(id:id)
            guard s.selectedMessages.map(\.id)==expected else { throw ChatEvidenceError.invalidSummary }
            s.summaries.append(value);s.updatedAt=value.generatedAt;try generic.save(s)
        }
        func addSummary(_ value:ChatSummarySegment,_ id:String,_ expected:[String])throws {
            try genericSummary(value,id,expected)
            let returned=try append.appendSummary(value,sessionID:id,expectedSelectedMessageIDs:expected,updatedAt:value.generatedAt)
            checks.expect(returned==append.sessions.last!,"Append returns complete latest private session")
            try same("summary")
        }
        func genericReport(_ value:ChatSummaryReport,_ id:String,_ expected:[String])throws {
            // Required new API precondition reference. The original final
            // report path had no separate guard because it contained no await.
            var s=try generic.session(id:id)
            guard s.selectedMessages.map(\.id)==expected else { throw ChatEvidenceError.invalidSummary }
            s.reports.append(value);s.updatedAt=value.generatedAt;try generic.save(s)
        }
        func addReport(_ value:ChatSummaryReport,_ id:String,_ expected:[String])throws {
            try genericReport(value,id,expected)
            _ = try append.appendReport(value,sessionID:id,expectedSelectedMessageIDs:expected,updatedAt:value.generatedAt)
            try same("report")
        }
        func rejectSummary(_ value:ChatSummarySegment,_ id:String,_ expected:[String])throws {
            let before=try ChatAppendTransactionChecks.encode(Document(sessions:append.sessions)),disk=try Data(contentsOf:right)
            let a=ChatAppendTransactionChecks.error { try genericSummary(value,id,expected) },b=ChatAppendTransactionChecks.error { _ = try append.appendSummary(value,sessionID:id,expectedSelectedMessageIDs:expected,updatedAt:value.generatedAt) }
            checks.expect(a != nil && a==b,"Restricted summary retains original native rejection type")
            checks.expect(try ChatAppendTransactionChecks.encode(Document(sessions:append.sessions))==before && Data(contentsOf:right)==disk,"Rejected summary never adopts or writes")
        }
        func rejectReport(_ value:ChatSummaryReport,_ id:String,_ expected:[String])throws {
            let before=try ChatAppendTransactionChecks.encode(Document(sessions:append.sessions)),disk=try Data(contentsOf:right)
            let a=ChatAppendTransactionChecks.error { try genericReport(value,id,expected) },b=ChatAppendTransactionChecks.error { _ = try append.appendReport(value,sessionID:id,expectedSelectedMessageIDs:expected,updatedAt:value.generatedAt) }
            checks.expect(a != nil && a==b,"Restricted report retains original native rejection type")
            checks.expect(try ChatAppendTransactionChecks.encode(Document(sessions:append.sessions))==before && Data(contentsOf:right)==disk,"Rejected report never adopts or writes")
        }
    }
    @MainActor private final class Gate {
        private enum Failure:Error { case modelDidNotStartWithinFiveSeconds }
        private var entered=false,released=false,resume:CheckedContinuation<Void,Never>?
        func pause()async { entered=true;if released{return};await withCheckedContinuation { resume=$0 } }
        func wait()async throws {
            let start=DispatchTime.now().uptimeNanoseconds
            while !entered {
                guard DispatchTime.now().uptimeNanoseconds-start < 5_000_000_000 else { throw Failure.modelDidNotStartWithinFiveSeconds }
                try await Task.sleep(nanoseconds:10_000_000)
            }
        }
        func release() { released=true;resume?.resume();resume=nil }
    }
    private static func echo(_ prompt:String)throws->String {
        let payload=try JSONSerialization.jsonObject(with:Data(prompt.components(separatedBy:"原消息数据：\n").last!.utf8)) as! [String:Any]
        let messages=payload["messages"] as! [[String:Any]],ids=Set(payload["newMessageIDs"] as! [String]),source=messages.first { ids.contains($0["id"] as! String) }!
        let quote=source["text"] as! String
        return String(decoding:try JSONSerialization.data(withJSONObject:["claims":[["category":"fact","statement":quote,"citations":[["messageID":source["id"]!,"quote":quote]],"owner":NSNull(),"deadline":NSNull()]]]),as:UTF8.self)
    }
    private static func unicode(_ folder:URL,_ checks:Checks)throws {
        let epoch=Date(timeIntervalSince1970:1_700_000_000),capture=UUID()
        let target=ChatConversationTarget(stableID:try WeChatContactIdentity.stableID(account:"wxid_fixtureK"),title:"Synthetic contact",deviceKey:"append-unicode-fixture")
        let profile=PhoneUISnapshot(deviceKey:target.deviceKey,scene:"unknown",elements:[element("back","通讯录",0.1,0.07),element("name",target.title,0.5,0.18),element("account","微信号：wxid_fixtureK",0.55,0.25,0.65),element("moments","朋友圈",0.25,0.48),element("message","发消息",0.5,0.7),element("call","音视频通话",0.5,0.8)],capturedAt:epoch)
        let evidence=try WeChatContactIdentity.profile(snapshot:profile,frameID:"profile",captureSessionID:capture,target:target)
        let nav=WeChatContactNavigationEvidence(profile:evidence,tapStartedAt:epoch.addingTimeInterval(0.1),tapCompletedAt:epoch.addingTimeInterval(0.2),chatConfirmedAt:epoch.addingTimeInterval(1))
        let chat=PhoneUISnapshot(deviceKey:target.deviceKey,scene:"unknown",elements:[element("back","微信",0.1,0.08),element("title",target.title,0.5,0.08),element("input","发送消息",0.4,0.9),element("row","Synthetic Unicode fact",0.75,0.32)],capturedAt:epoch.addingTimeInterval(1))
        var frame=try ChatEvidenceFrame.fromContactNavigation(snapshot:chat,id:"unicode-chat",captureSessionID:capture,target:target,navigation:nav)
        frame.rows[0].sentAt=chat.capturedAt // Explicit known fixture time only.
        var s=ChatEvidenceSession(request:.init(scopeID:"unicode",conversation:target,range:.time(start:epoch,end:epoch.addingTimeInterval(2)),maxPages:1))
        s.frames=[frame];s.messages=[.init(id:"unicode-message",observation:frame.rows[0],anchors:[frame.rows[0].anchor])];s.state = .partial
        let pair=try Pair([s],"unicode",folder,checks),before=try encode(s)
        var bad=s;bad.request.conversation.stableID="wechat.account:wxid_fixture\u{212A}"
        let badBytes=try encode(bad)
        checks.expect(bad==s && badBytes != before,"Unicode Equatable is not a native-validation witness")
        let a=error { try pair.generic.save(bad) },b=error { try pair.append.save(bad) }
        checks.expect(a != nil && a==b,"Generic save always reruns native account/profile validators")
        checks.expect(try encode(pair.append.session(id:s.id))==before,"Failed generic Unicode save cannot poison private values")
        try pair.addSummary(segment(s),s.id,s.selectedMessages.map(\.id))
    }
    static func run(folder:URL)async throws->Int {
        let checks=Checks(),s=fixture("append-scope"),ids=s.selectedMessages.map(\.id)
        let pair=try Pair([withRaw(s)],"append-transactions",folder,checks),good=segment(s)
        for wrong in [Array(ids.reversed()),Array(ids.dropLast()),ids+["raw-batch"],["outside"]] { try pair.rejectSummary(good,s.id,wrong) }
        var bad=good;bad.id="raw-batch";bad.validationVersion=nil;try pair.rejectSummary(bad,s.id,ids)
        bad=good;bad.claims[0].citations[0].quote="unknown quote";try pair.rejectSummary(bad,s.id,ids)
        bad=good;bad.validationVersion=99;try pair.rejectSummary(bad,s.id,ids)
        bad=good;bad.id="cr-v2-"+uuid(1);try pair.rejectSummary(bad,s.id,ids)
        try pair.addSummary(good,s.id,ids)
        try pair.rejectSummary(good,s.id,ids)
        let validReport=report(s,good)
        var badReport=validReport;badReport.id="raw-batch";badReport.validationVersion=nil;try pair.rejectReport(badReport,s.id,ids)
        badReport=validReport;badReport.scopeID="other";try pair.rejectReport(badReport,s.id,ids)
        badReport=validReport;badReport.messageIDs=Array(ids.reversed());try pair.rejectReport(badReport,s.id,ids)
        badReport=validReport;badReport.claims[0].citations[0].quote="not sourced";try pair.rejectReport(badReport,s.id,ids)
        try pair.addReport(validReport,s.id,ids)

        var current=s;current.request.range = .currentPage(limit:2);current.state = .complete
        current.pageSelection = .init(scopeID:s.id,requestedConversation:s.request.conversation,frameID:s.frames[0].id,capturedAt:s.frames[0].snapshot.capturedAt,limit:2,messageIDs:Array(ids.suffix(2)))
        let currentPair=try Pair([current],"append-current-page",folder,checks),selected=current.selectedMessages.map(\.id),currentSegment=segment(current)
        bad=currentSegment;bad.messageIDs=[ids[0]];bad.claims=[claim(s.messages[0])];try currentPair.rejectSummary(bad,s.id,selected)
        try currentPair.addSummary(currentSegment,s.id,selected)
        var currentReport=report(current,currentSegment);currentReport.messageIDs=Array(ids.prefix(2));try currentPair.rejectReport(currentReport,s.id,selected)
        try currentPair.addReport(report(current,currentSegment),s.id,selected)

        let legacyPair=try Pair([s],"append-legal-namespaces",folder,checks)
        var legacySegment=good;legacySegment.id=s.frames[0].id;legacySegment.validationVersion=nil
        try legacyPair.addSummary(legacySegment,s.id,ids)
        var legacyReport=report(s,legacySegment);legacyReport.id=ids[0];legacyReport.validationVersion=nil
        try legacyPair.addReport(legacyReport,s.id,ids)
        var cold=s;cold.request.scopeID="append-cold-same-IDs"
        let scopes=try Pair([s,cold],"append-local-scopes",folder,checks)
        try scopes.addSummary(good,s.id,ids);try scopes.addSummary(good,cold.id,ids)
        try scopes.addReport(report(s,good),s.id,ids);try scopes.addReport(report(cold,good),cold.id,ids)
        try unicode(folder,checks)

        // Genuine filesystem shape failure, no public IO injection. Move the
        // existing checkpoint aside and place a directory at the target path;
        // the native atomic write cannot replace it with a file. The retained
        // checkpoint bytes and private value must survive; then restore it.
        let io=try Pair([s],"append-native-IO",folder,checks),backup=io.right.appendingPathExtension("backup")
        let original=try Data(contentsOf:io.right),memory=try encode(io.append.session(id:s.id))
        try FileManager.default.moveItem(at:io.right,to:backup)
        try FileManager.default.createDirectory(at:io.right,withIntermediateDirectories:false)
        let writeError=error { _ = try io.append.appendSummary(good,sessionID:s.id,expectedSelectedMessageIDs:ids,updatedAt:good.generatedAt) }
        checks.expect(writeError != nil,"Actual native atomic write failure is retained")
        checks.expect(try Data(contentsOf:backup)==original && encode(io.append.session(id:s.id))==memory,"Failed append keeps retained checkpoint bytes and private memory")
        try FileManager.default.removeItem(at:io.right);try FileManager.default.moveItem(at:backup,to:io.right)
        try io.addSummary(good,s.id,ids)

        // Actual model awaits, not direct transaction calls: both operations
        // must preserve each other's summaries/reports plus an unrelated scope.
        let concurrent=try Pair([s],"append-concurrent",folder,checks),a=Gate(),b=Gate()
        let first=Task { try await ChatEvidenceSummarizer { prompt in await a.pause();return try echo(prompt) }.summarize(sessionID:s.id,store:concurrent.append) }
        let second=Task { try await ChatEvidenceSummarizer { prompt in await b.pause();return try echo(prompt) }.summarize(sessionID:s.id,store:concurrent.append) }
        defer { a.release();b.release() }
        do {
            try await a.wait();try await b.wait();try concurrent.append.save(cold)
            a.release();_ = try await first.value;b.release();_ = try await second.value
        } catch {
            first.cancel();second.cancel();a.release();b.release()
            _ = await first.result;_ = await second.result
            throw error
        }
        let combined=try concurrent.append.session(id:s.id)
        checks.expect(combined.summaries.count==2 && combined.reports.count==2,"Actual concurrent summaries retain both products")
        checks.expect(concurrent.append.sessions.map(\.id)==[cold.id,s.id],"Actual await updates retain cold scope and original session order")
        checks.expect(ChatEvidenceStore(url:concurrent.right).sessions==concurrent.append.sessions,"Concurrent appended document passes complete native reload")
        let cancelPair=try Pair([s],"append-cancel",folder,checks),gate=Gate(),beforeCancel=try Data(contentsOf:folder.appendingPathComponent("append-cancel/append.json"))
        let task=Task { try await ChatEvidenceSummarizer { prompt in await gate.pause();return try echo(prompt) }.summarize(sessionID:s.id,store:cancelPair.append) }
        defer { gate.release() }
        var cancelled=false
        do {
            try await gate.wait();task.cancel();gate.release()
            do { _ = try await task.value } catch is CancellationError { cancelled=true }
        } catch {
            task.cancel();gate.release();_ = await task.result
            throw error
        }
        checks.expect(cancelled,"Actual cancelled model continuation retains CancellationError")
        checks.expect(try Data(contentsOf:cancelPair.right)==beforeCancel,"Cancellation prevents summary/report append")
        return checks.count
    }
}
