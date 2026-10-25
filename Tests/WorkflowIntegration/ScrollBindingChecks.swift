import Foundation

/// Production capture, collector and live driver; only image/OCR/input I/O is synthetic.
@MainActor enum ScrollBindingChecks {
    static func run(folder: URL, elements: [PhoneUIElement]) async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        let task = XiaohongshuCollectionTask(id:"scroll-binding-checks",keyword:"人工智能",sampleSize:2)
        for older in [false, true] {
            let tape = CaptureReplay(folder:folder), frame = tape.show(elements)
            let gui = tape.driver(initial:frame)
            let live = LiveXiaohongshuCollectionDriver(gui:gui)
            let current = try await live.read()
            let target = XiaohongshuCollector.candidates(in:current.snapshot,task:task).first!
            if older { try await gui.scroll(older:true,at:target) }
            else { try await live.scrollResults(at:target) }
            expect(tape.executor.actions == [.scroll], "Anchoring submits one scroll and no focus tap")
            let action = tape.executor.dispatched[0]
            expect(action.x == target.rect.centerX && action.y == target.rect.centerY && action.amount == (older ? 3 : -3), "The live bridge forwards exact current OCR bounds and direction")
        }
        for mode in ["bounds","source","id","new-pixels","connection","calibration","cancelled"] {
            let tape = CaptureReplay(folder:folder), frame = tape.show(elements)
            let gui = tape.driver(initial:frame)
            let current = try await gui.read()
            var target = XiaohongshuCollector.candidates(in:current.1,task:task).first!
            switch mode {
            case "bounds": target.rect.y += 0.01
            case "source": target.source = "model"
            case "id": target.id += ".old"
            case "new-pixels": _ = tape.show(elements)
            case "connection": tape.executor.ble.pointerConnectionGeneration = UUID()
            case "calibration": tape.executor.calibrationValid = false
            default: break
            }
            let boundTarget = target
            let worker = Task { @MainActor in
                if mode == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
                do { try await gui.scroll(older:false,at:boundTarget); return false }
                catch { return true }
            }
            let rejected = await worker.value
            expect(rejected && tape.executor.actions.isEmpty, "Unsafe bound scroll fails before dispatch: " + mode)
        }

        let headers = elements.filter { !$0.label.hasPrefix("标题") }
        let empty = CaptureReplay(folder:folder), emptyFrame = empty.show(headers)
        let emptyStore = XiaohongshuCollectionStore(url:folder.appendingPathComponent("empty-scroll-target.json"))
        let emptyTask = XiaohongshuCollectionTask(id:"empty-scroll-target",keyword:"人工智能",sampleSize:2)
        let stopped = try await XiaohongshuCollector(store:emptyStore).collect(task:emptyTask,
            driver:LiveXiaohongshuCollectionDriver(gui:empty.driver(initial:emptyFrame)))
        expect(stopped.status == .paused && stopped.stopReason.hasPrefix("scroll_target_unavailable"), "An empty viewport pauses rather than inventing a scroll target or declaring full coverage")
        expect(empty.executor.actions.isEmpty && stopped.checkpoint?.scrollCount == 0, "Unavailable target neither dispatches input nor consumes scroll count")
        expect(try emptyStore.run(id:emptyTask.id)?.status == .paused, "The unavailable-target checkpoint is durable")

        func element(_ id: String, _ label: String, _ x: Double, _ y: Double, _ width: Double) -> PhoneUIElement {
            .init(id:id,label:label,rect:.init(x:x,y:y,width:width,height:0.03),source:"ocr")
        }
        func note(_ id: String) -> [PhoneUIElement] {
            [element("brand","小红书",0.4,0.02,0.2),element("back","返回",0.03,0.08,0.15),
             element("follow","关注",0.8,0.14,0.15),element("composer","说点什么",0.1,0.90,0.3),
             element("body","正文：人工智能 实测",0.1,0.40,0.8),
             element("source","https://www.xiaohongshu.com/explore/"+id,0.01,0.75,0.98)]
        }
        let a = "0123456789abcdef01234567", b = "1123456789abcdef01234567"
        let firstPage = headers + [element("first-card","标题甲：人工智能笔记",0.09,0.51,0.36)]
        let secondPage = headers + [element("second-card","标题乙：人工智能笔记",0.52,0.63,0.4)]
        let paged = CaptureReplay(folder:folder), initial = paged.show(firstPage)
        paged.queue = [note(a),firstPage,secondPage,note(b)]
        let store = XiaohongshuCollectionStore(url:folder.appendingPathComponent("anchored-pagination.json"))
        let result = try await XiaohongshuCollector(store:store).collect(
            task:.init(id:"anchored-pagination",keyword:"人工智能",sampleSize:2),
            driver:LiveXiaohongshuCollectionDriver(gui:paged.driver(initial:initial)))
        expect(result.status == .sampleReached && result.notes.map(\.id) == [a,b], "Production collection continues across the anchored scroll into a second page")
        expect(paged.executor.actions == [.tap,.tap,.scroll,.tap] && result.checkpoint?.scrollCount == 1, "Return from a note is followed by one bound scroll, not a guessed focus click")
        let scroll = paged.executor.dispatched[2]
        expect(scroll.x == firstPage.last!.rect.centerX && scroll.y == firstPage.last!.rect.centerY && scroll.amount == -3, "Pagination uses the fresh returned card bounds rather than the prior Back location")
        return checks
    }
}
