import Foundation

@MainActor enum XHSAnalysisWrapperChecks {
    private struct Document:Codable { var version=1;var runs:[XiaohongshuCollectionRun] }
    @MainActor private final class Checks {
        var count=0,passed:[String]=[],failures:[String]=[]
        func expect(_ value:Bool,_ label:String)throws {
            count+=1
            if value {passed.append(label)} else {failures.append(label);throw AgentError.message(label)}
        }
        func write(_ url:URL,_ complete:Bool)throws {
            try JSONSerialization.data(withJSONObject:["complete":complete,"checks":count,"passed":passed,"failures":failures,"realPhoneModelOrNetwork":false,"actualCandidateStoreBothPaths":true,"benchmark":false],options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
        }
    }
    private static func encode<T:Encodable>(_ value:T)throws->Data {
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(value)
    }
    private static func caught(_ body:()throws->Void)->String? {
        do {try body();return nil}catch{return String(reflecting:error)}
    }
    private static func uuid(_ n:Int)->UUID {
        UUID(uuidString:"00000000-0000-4000-8000-"+String(format:"%012llx",Int64(n+1)))!
    }
    private static func segment(_ run:XiaohongshuCollectionRun,_ n:Int=1)throws->XiaohongshuAnalysisSegment {
        let input=XiaohongshuAnalysisService.inputs(run.notes[0])[0]
        let quote=String(input.excerpt.prefix(500))
        return .init(id:uuid(n),createdAt:run.updatedAt.addingTimeInterval(1),inputs:[input],items:[.init(noteID:input.noteID,quote:quote,topic:String(quote.prefix(40)))])
    }
    private static func response(_ prompt:String)throws->String {
        guard let range=prompt.range(of:"INPUT_EXCERPTS_JSON:\n") else {throw AgentError.message("Original full prompt marker")}
        let inputs=try JSONDecoder().decode([XiaohongshuAnalysisInput].self,from:Data(prompt[range.upperBound...].utf8))
        let items=inputs.map { value->[String:String] in let quote=String(value.excerpt.prefix(500));return ["noteID":value.noteID,"quote":quote,"topic":String(quote.prefix(40))] }
        return String(decoding:try JSONSerialization.data(withJSONObject:["kind":"visible_fragment_topics","items":items],options:.sortedKeys),as:UTF8.self)
    }
    @MainActor private final class Pair {
        let full:XiaohongshuCollectionStore,append:XiaohongshuCollectionStore,left:URL,right:URL,c:Checks
        init(_ runs:[XiaohongshuCollectionRun],_ name:String,_ folder:URL,_ c:Checks)throws {
            self.c=c;let dir=folder.appendingPathComponent(name);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            left=dir.appendingPathComponent("full.json");right=dir.appendingPathComponent("append.json")
            let bytes=try encode(Document(runs:runs));try bytes.write(to:left,options:.atomic);try bytes.write(to:right,options:.atomic)
            full=XiaohongshuCollectionStore(url:left);append=XiaohongshuCollectionStore(url:right)
            try c.expect(full.runs.count==runs.count && append.runs.count==runs.count,"Original full native init accepts \(name)")
        }
        func fullAppend(_ value:XiaohongshuAnalysisSegment,_ id:String,_ date:Date)throws {
            guard var run=try full.run(id:id) else {throw XiaohongshuCollectionError.invalidTask}
            run.analysisSegments.append(value);run.updatedAt=date;try full.save(run)
        }
        func same(_ id:String,_ label:String)throws {
            try c.expect(try Data(contentsOf:left)==Data(contentsOf:right),"Complete checkpoint Data equal: "+label)
            try c.expect(try encode(Document(runs:full.runs))==encode(Document(runs:append.runs)),"Complete canonical values equal: "+label)
            let reopened=XiaohongshuCollectionStore(url:right)
            try c.expect(try encode(Document(runs:reopened.runs))==Data(contentsOf:right),"Complete full-native reopen: "+label)
            try c.expect(try full.export(id:id)==append.export(id:id),"Complete statistics/export Data equal: "+label)
        }
        func add(_ value:XiaohongshuAnalysisSegment,_ id:String,_ date:Date)throws {
            try fullAppend(value,id,date)
            let returned=try append.appendAnalysis(value,taskID:id,updatedAt:date)
            try c.expect(try encode(returned)==encode(append.run(id:id)!),"Return latest committed complete value")
            try same(id,"analysis append")
        }
        func reject(_ value:XiaohongshuAnalysisSegment,_ id:String,_ date:Date)throws {
            let before=try Data(contentsOf:right),memory=try encode(Document(runs:append.runs))
            let a=caught{try fullAppend(value,id,date)}
            let b=caught{_ = try append.appendAnalysis(value,taskID:id,updatedAt:date)}
            try c.expect(a != nil && a==b,"Same original dynamic rejection: "+(a ?? "unexpected success"))
            try c.expect(try Data(contentsOf:right)==before && encode(Document(runs:append.runs))==memory,"Rejected analysis preserves full disk/canonical state")
        }
    }
    @MainActor private final class Gate {
        private(set) var entered=false
        private var released=false,continuation:CheckedContinuation<Void,Never>?
        func pause()async {entered=true;if released{return};await withCheckedContinuation{continuation=$0}}
        func wait()async throws {
            let start=DispatchTime.now().uptimeNanoseconds
            while !entered {guard DispatchTime.now().uptimeNanoseconds-start<5_000_000_000 else {throw AgentError.message("Model gate not entered")};try await Task.sleep(nanoseconds:10_000_000)}
        }
        func release(){released=true;continuation?.resume();continuation=nil}
    }
    static func run(folder:URL,fixture:URL,report:URL)async throws->Int {
        let c=Checks(),work=folder.appendingPathComponent("analysis-wrapper-controls")
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
        do {
            let document=try JSONDecoder().decode(Document.self,from:Data(contentsOf:fixture))
            let seed=document.runs[0],date=seed.updatedAt.addingTimeInterval(2)
            try c.expect(document.runs.count==1 && seed.notes.count==10 && seed.analysisSegments.isEmpty,"Exact ten-note cold full fixture")
            let good=try segment(seed),pair=try Pair([seed],"pair",work,c)
            try pair.add(good,seed.id,date)
            try pair.add(segment(seed,2),seed.id,date.addingTimeInterval(1))
            let wrapper=try ValidatedXiaohongshuCollectionRun(validating:seed)
            let anyWrapper:Any=wrapper
            try c.expect(!(anyWrapper is any Encodable) && !(anyWrapper is any Decodable),"Wrapper is non-Codable")
            var external=wrapper.value;external.notes[0].contentConclusionAllowed=true
            let derived=try wrapper.appendingAnalysis(good,updatedAt:date)
            try c.expect(derived.value.notes[0].contentConclusionAllowed==false,"Projected Run mutation cannot alter wrapper's private raw value")

            var cases:[(String,XiaohongshuCollectionRun)]=[]
            var bad=seed;bad.notes[0].source.shareCapture?.copyElementID="unobserved";cases.append(("note-source",bad))
            bad=seed;var revision=seed.notes[0];revision.contentConclusionAllowed=true;bad.noteRevisions=[revision];cases.append(("revision",bad))
            bad=seed;bad.sourceAttempts[0].detail="";cases.append(("attempt",bad))
            bad=seed;bad.sourceAttempts[bad.sourceAttempts.count-1].capture?.restoredNote.width=0;cases.append(("late-attempt-capture",bad))
            let pending=XiaohongshuPendingObservation(id:uuid(800),observedAt:seed.updatedAt,reason:"Synthetic pending",elements:seed.notes[0].elements,pageScene:"xiaohongshu.note")
            bad=seed;var invalidPending=pending;invalidPending.elements[0].rect.width = -1;bad.pending=[invalidPending];cases.append(("pending-shape",bad))
            bad=seed;bad.pending=[pending,pending];cases.append(("pending-duplicate",bad))
            bad=seed;bad.pages[0].scopeVersion=3;cases.append(("scope-native-downgrade",bad))
            bad=seed;bad.checkpoint?.width=0;cases.append(("checkpoint",bad))
            for (label,value) in cases {
                let direct=caught{try value.validate()},normal=caught{_ = try ValidatedXiaohongshuCollectionRun(validating:value)}
                try c.expect(direct != nil && direct==normal,"Normal wrapper full validation: "+label)
                let before=try encode(Document(runs:pair.append.runs)),disk=try Data(contentsOf:pair.right)
                let error=caught{try pair.append.save(value)}
                try c.expect(error==direct,"Generic Store still fully validates before adoption: "+label)
                try c.expect(try encode(Document(runs:pair.append.runs))==before && Data(contentsOf:pair.right)==disk,"Rejected generic raw never poisons wrapper state")
            }
            var changed=seed
            changed.task.fields=changed.task.fields.count>1 ? Array(changed.task.fields.dropLast()):[.title,.body]
            try changed.validate()
            try c.expect(caught{try pair.append.save(changed)}==String(reflecting:XiaohongshuCollectionError.conflictingTask),"Valid changed task retains conflict error")
            changed.notes[0].contentConclusionAllowed=true
            try c.expect(caught{try pair.append.save(changed)}==String(reflecting:XiaohongshuCollectionError.invalidDocument),"Raw validation precedes task conflict")

            let dynamic=try Pair([seed],"dynamic",work,c)
            var invalid=good;invalid.kind="full_note_summary";try dynamic.reject(invalid,seed.id,date)
            invalid=good;invalid.scope="all_content";try dynamic.reject(invalid,seed.id,date)
            invalid=good;invalid.inputs[0].visibleTextSHA256=String(repeating:"0",count:64);try dynamic.reject(invalid,seed.id,date)
            invalid=good;invalid.inputs[0].partCount+=1;try dynamic.reject(invalid,seed.id,date)
            invalid=good;invalid.inputs[0].excerpt="unsupported changed excerpt";try dynamic.reject(invalid,seed.id,date)
            invalid=good;invalid.items[0].topic="not a literal quote";try dynamic.reject(invalid,seed.id,date)
            try dynamic.reject(good,seed.id,seed.startedAt.addingTimeInterval(-1))
            try dynamic.reject(good,seed.id,Date(timeIntervalSince1970:.infinity))
            try dynamic.add(good,seed.id,date)
            try dynamic.reject(good,seed.id,date)
            invalid=try segment(seed,3);invalid.excluded=[String(repeating:"x",count:40_000_001)]
            try dynamic.reject(invalid,seed.id,date) // Original native allowance, original JSON cap rejects, zero big disk file.
            invalid.excluded=["unread_images"]

            var atLimit=seed
            atLimit.analysisSegments=(0..<5000).map { index in var value=good;value.id=uuid(10_000+index);return value }
            let limitPair=try Pair([atLimit],"segment-budget",work,c)
            try limitPair.reject(good,seed.id,date) // Unique new ID; reject5001 by the original header budget.
            var other=seed;other.task.id="wrapper-other-task"
            let multiple=try Pair([seed,other],"multiple-runs",work,c)
            try multiple.add(good,seed.id,date);try multiple.add(good,other.id,date)
            try c.expect(multiple.append.runs.map(\.id)==[seed.id,other.id],"Original filter-and-append ordering and per-run IDs preserved")
            var legacy=try JSONSerialization.jsonObject(with:encode(Document(runs:[seed]))) as! [String:Any]
            var legacyRuns=legacy["runs"] as! [[String:Any]];legacyRuns[0].removeValue(forKey:"analysisSegments");legacyRuns[0].removeValue(forKey:"sourceAttempts");legacy["runs"]=legacyRuns
            let legacyPath=work.appendingPathComponent("legacy-input.json");try JSONSerialization.data(withJSONObject:legacy).write(to:legacyPath,options:.atomic)
            let legacyStore=XiaohongshuCollectionStore(url:legacyPath)
            guard let old=try legacyStore.run(id:seed.id) else {throw AgentError.message("Legacy native reopen failed")}
            try c.expect(old.analysisSegments.isEmpty && old.sourceAttempts.isEmpty,"Legacy optional fields retain defaults through full wrapper init")
            let legacyPair=try Pair([old],"legacy",work,c);try legacyPair.add(good,seed.id,date)

            let corruptPath=work.appendingPathComponent("corrupt.json"),corrupt=Data("not a document".utf8);try corrupt.write(to:corruptPath)
            let unusable=XiaohongshuCollectionStore(url:corruptPath)
            try c.expect(caught{_ = try unusable.appendAnalysis(good,taskID:seed.id,updatedAt:date)}==String(reflecting:XiaohongshuCollectionError.unavailable),"Unusable Store cannot append")
            try c.expect(try Data(contentsOf:corruptPath)==corrupt && unusable.runs.isEmpty,"Corrupt index preserved and no private default write")
            try c.expect(caught{_ = try pair.append.appendAnalysis(good,taskID:"missing-task",updatedAt:date)}==String(reflecting:XiaohongshuCollectionError.invalidTask),"Missing task cannot be created by analysis append")

            let io=try Pair([seed],"native-IO",work,c),backup=io.right.appendingPathExtension("backup")
            let beforeIO=try Data(contentsOf:io.right),beforeMemory=try encode(Document(runs:io.append.runs))
            try FileManager.default.moveItem(at:io.right,to:backup);try FileManager.default.createDirectory(at:io.right,withIntermediateDirectories:false)
            let ioError=caught{_ = try io.append.appendAnalysis(good,taskID:seed.id,updatedAt:date)}
            try c.expect(ioError==String(reflecting:XiaohongshuCollectionError.unavailable),"Real native atomic I/O failure retains original type")
            try c.expect(try Data(contentsOf:backup)==beforeIO && encode(Document(runs:io.append.runs))==beforeMemory,"I/O failure preserves backed-up checkpoint and private canonical state")
            try FileManager.default.removeItem(at:io.right);try FileManager.default.moveItem(at:backup,to:io.right);try io.add(good,seed.id,date)

            let concurrent=try Pair([seed],"concurrent",work,c),a=Gate(),b=Gate()
            var firstCalls=0,secondCalls=0
            let firstService=XiaohongshuAnalysisService(store:concurrent.append,model:{prompt in firstCalls+=1;if firstCalls==1 {await a.pause()};return try response(prompt)})
            let secondService=XiaohongshuAnalysisService(store:concurrent.append,model:{prompt in secondCalls+=1;if secondCalls==1 {await b.pause()};return try response(prompt)})
            let first=Task{try await firstService.analyze(taskID:seed.id)},second=Task{try await secondService.analyze(taskID:seed.id)}
            defer{a.release();b.release()}
            do {
                try await a.wait();try await b.wait()
                var progress=try concurrent.append.run(id:seed.id)!
                progress.events.append(.init(at:date,kind:"synthetic-progress",detail:"Preserve while both real model boundaries await"))
                progress.checkpoint?.readCount+=1
                let checkpoint=progress.checkpoint
                try concurrent.append.save(progress);try concurrent.append.save(other)
                a.release();_ = try await first.value;b.release();let result=try await second.value
                try c.expect(firstCalls==2 && secondCalls==2 && result.analysisSegments.count==4,"Two real default8 Analyze calls retain all four batch checkpoints")
                try c.expect(result.events==progress.events && result.checkpoint==checkpoint,"Model await preserves saved events/checkpoint")
                try c.expect(concurrent.append.runs.count==2 && concurrent.append.runs.last?.id==seed.id,"Other run survives both same-Store asynchronous analyses")
                try c.expect(try encode(Document(runs:XiaohongshuCollectionStore(url:concurrent.right).runs))==Data(contentsOf:concurrent.right),"Concurrent analysis checkpoints reopen with full native validator")
            } catch {first.cancel();second.cancel();a.release();b.release();_ = await first.result;_ = await second.result;throw error}

            let stale=try Pair([seed],"changed-batch",work,c),gate=Gate()
            let staleService=XiaohongshuAnalysisService(store:stale.append,model:{prompt in await gate.pause();return try response(prompt)})
            let staleTask=Task{try await staleService.analyze(taskID:seed.id)};defer{gate.release()}
            do {
                try await gate.wait()
                var latest=try stale.append.run(id:seed.id)!,note=latest.notes[0]
                // The actual frozen fixture uses one unlabelled body element.
                // Bind the actual body value to that unique OCR element, then use
                // normal native Store.save; do not skip this changed-SHA control.
                guard let body=note.body else {throw AgentError.message("Fixture body is absent")}
                let bodyIndices=note.elements.indices.filter {note.elements[$0].source=="ocr" && note.elements[$0].label==body}
                try c.expect(bodyIndices.count==1 && XiaohongshuNoteEvidence.body(elements:note.elements)==body,"Actual source body is one unique OCR element")
                let index=bodyIndices[0],oldHash=note.visibleTextSHA256
                note.elements[index].label+=" changed synthetic"
                note.body=XiaohongshuNoteEvidence.body(elements:note.elements)
                note.source.shareCapture?.note.snapshot.elements=note.elements
                if var capture=note.source.shareCapture {
                    for i in capture.restoredNote.snapshot.elements.indices where capture.restoredNote.snapshot.elements[i].id==note.elements[index].id {capture.restoredNote.snapshot.elements[i].label=note.elements[index].label}
                    note.source.shareCapture=capture
                }
                try c.expect(note.visibleTextSHA256 != oldHash,"Actual modified source text changes the batch SHA")
                latest.notes[0]=note;try stale.append.save(latest)
                try c.expect(try stale.append.run(id:seed.id)!.notes[0].visibleTextSHA256==note.visibleTextSHA256,"Changed source passes complete native save before model resumes")
                let checkpoint=try Data(contentsOf:stale.right)
                gate.release();var mismatch=false
                do {_ = try await staleTask.value}catch let error as XiaohongshuAnalysisError {if case .changedEvidence = error { mismatch=true }}
                try c.expect(mismatch,"Original post-model batch noteID+SHA guard rejects changed evidence")
                try c.expect(try Data(contentsOf:stale.right)==checkpoint && stale.append.run(id:seed.id)!.analysisSegments.isEmpty,"Changed evidence retains latest complete checkpoint, no stale segment")
            } catch {staleTask.cancel();gate.release();_ = await staleTask.result;throw error}

            let cancelled=try Pair([seed],"cancel",work,c),cancelGate=Gate()
            let cancelService=XiaohongshuAnalysisService(store:cancelled.append,model:{prompt in await cancelGate.pause();return try response(prompt)})
            let beforeCancel=try Data(contentsOf:cancelled.right),cancelTask=Task{try await cancelService.analyze(taskID:seed.id)}
            defer{cancelGate.release()}
            do {
                try await cancelGate.wait()
                let overlap=caught{_ = try cancelled.append.appendAnalysis(good,taskID:"missing",updatedAt:date)}
                try c.expect(overlap != nil,"Persistence gate lookup remains independent from analysis active flag")
                let secondCall=Task{try await cancelService.analyze(taskID:seed.id)}
                var refused=false;do {_ = try await secondCall.value}catch let error as XiaohongshuCollectionError {if case .invalidTask = error { refused=true }}
                try c.expect(refused,"Same AnalysisService refuses overlapping call without a second model boundary")
                cancelTask.cancel();cancelGate.release()
                var wasCancelled=false;do {_ = try await cancelTask.value}catch is CancellationError {wasCancelled=true}
                try c.expect(wasCancelled,"Actual post-model cancellation retains CancellationError")
                try c.expect(try Data(contentsOf:cancelled.right)==beforeCancel && cancelled.append.run(id:seed.id)!.analysisSegments.isEmpty,"Cancellation leaves all checkpoint/canonical analysis untouched")
            } catch {cancelTask.cancel();cancelGate.release();_ = await cancelTask.result;throw error}

            try c.write(report,true);return c.count
        } catch {
            c.failures.append(String(reflecting:error));try? c.write(report,false)
            // Preserve this helper's own checkpoints before the legacy main's
            // existing defer removes its temporary folder. Best effort only:
            // an evidence-copy error must never replace the original failure.
            let failureRoot=report.deletingLastPathComponent().appendingPathComponent("failure-fixtures")
            do {
                try FileManager.default.createDirectory(at:failureRoot,withIntermediateDirectories:true)
                let retained=failureRoot.appendingPathComponent("analysis-wrapper-controls-"+UUID().uuidString)
                try FileManager.default.copyItem(at:work,to:retained)
            } catch let copyError {
                try? Data(String(reflecting:copyError).utf8).write(to:report.deletingLastPathComponent().appendingPathComponent("failure-fixture-copy-error.txt"),options:.atomic)
            }
            throw error
        }
    }
}
