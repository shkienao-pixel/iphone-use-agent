import SwiftUI
import MapKit

// Shared with the read-only DiDi service. Unknown prices stay unknown.
struct DidiSimulationPlace: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let latitude: Double
    let longitude: Double
    var city: String = ""
    var verifiedByDidi: Bool = false
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var region: MKCoordinateRegion { .init(center: coordinate, span: .init(latitudeDelta: 0.008, longitudeDelta: 0.008)) }
}

struct DidiSimulationCar: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let priceText: String
    var displayPrice: String {
        let text = priceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || ["null", "nil", "undefined", "n/a", "na", "--", "—", "-"].contains(text.lowercased()) {
            return "待核实"
        }
        if text.contains("元") || text.contains("¥") || text.contains("￥") { return text }
        // Bare numeric amounts retain the existing CNY presentation. Unknown
        // or qualified service text stays verbatim instead of becoming ¥0 or
        // gaining a misleading currency prefix.
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) != nil &&
            text.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil ? "¥" + text : text
    }
}

/// Real location and read-only map/quote data; order progress is local simulation.
@MainActor
struct DidiRideSimulationView: View {
    let embedded: Bool
    let onSummary: (String) -> Void
    let onEnd: (() -> Void)?
    let initialRequest: String
    let hints: DidiRequestHints

    init(embedded: Bool = false, initialRequest: String = "", onSummary: @escaping (String) -> Void = { _ in }, onEnd: (() -> Void)? = nil) {
        self.embedded = embedded
        self.initialRequest = initialRequest
        self.hints = DidiRequestHints(initialRequest)
        self.onSummary = onSummary
        self.onEnd = onEnd
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var service = DidiSimulationService()
    @State private var stage: DidiSimulationStage = .route
    @State private var pickup: DidiSimulationPlace?
    @State private var destination: DidiSimulationPlace?
    @State private var stops: [DidiSimulationPlace] = []
    @State private var cars: [DidiSimulationCar] = []
    @State private var selectedCarID: String?
    @State private var picker: DidiSimulationPickerTarget?
    @State private var showConnection = false
    @State private var loadingCars = false
    @State private var error = ""
    @State private var banner: DidiSimulationBanner?
    @State private var quoteTask: Task<Void, Never>?
    @State private var rideTask: Task<Void, Never>?
    @State private var bannerTask: Task<Void, Never>?
    @State private var quoteRevision = UUID()

    private var selectedCar: DidiSimulationCar? { cars.first { $0.id == selectedCarID } }
    private var canQuery: Bool { pickup != nil && destination != nil && service.isConfigured }

    var body: some View {
        Group {
            if embedded { conversationCard }
            else { standalonePage }
        }
        .sheet(item: $picker) { target in
            DidiSimulationPlacePicker(title: target.title, initial: place(for: target),
                initialQuery: target.searchHint(hints), near: pickup ?? service.nearbyPlaces.first, service: service) { place in
                    apply(place, to: target)
                }
        }
        .sheet(isPresented: $showConnection) { DidiSimulationConnectionView(service: service) }
        .onAppear { publishSummary() }
        .onChange(of: stage) { _, _ in publishSummary() }
        .onChange(of: initialRequest) { _, _ in
            clearSelections(); invalidateRoute(); service.resetTripData()
        }
        .onDisappear { cancelTasks(); clearSelections(); service.disconnect() }
        .tint(SelaHomePalette.accent)
    }

    private var conversationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("打车 · 模拟", systemImage: "car.side")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Button { goBack() } label: {
                    Image(systemName: "chevron.left").frame(width: 30, height: 30)
                }
                .buttonStyle(.plain).disabled(stage == .route)
                .accessibilityLabel("上一步")
                .accessibilityIdentifier("didi.chat.previous")
                Button("结束") { closeSimulation() }
                    .font(.caption).buttonStyle(.plain).frame(minHeight: 30)
                    .accessibilityIdentifier("didi.chat.end")
            }
            .foregroundStyle(SelaHomePalette.secondary)
            Text("地点和车型查询来自滴滴；接单与司机为模拟，不会叫车或扣费。")
                .font(.caption).foregroundStyle(SelaHomePalette.secondary)
            if !initialRequest.isEmpty {
                Text("你的请求：" + initialRequest).font(.caption).foregroundStyle(SelaHomePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            conversationProgress
            HStack {
                Text(stage.title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Button(service.isConfigured ? "断开滴滴" : "连接滴滴") {
                    if service.isConfigured {
                        service.disconnect(); pickup = nil; destination = nil; stops = []; invalidateRoute()
                    } else { showConnection = true }
                }.font(.caption)
            }
            if let banner {
                DidiSimulationBannerView(banner: banner)
                    .transition(.opacity)
            }
            if stage == .route {
                DidiSimulationRouteMap(pickup: pickup, destination: destination, stops: stops,
                    nearby: service.nearbyPlaces.first)
                    .frame(height: 155).clipShape(RoundedRectangle(cornerRadius: 14))
                locationArea
                routeCard
            } else {
                compactRoute
            }
            stageContent
            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 8) {
                stageActions
                Button { closeSimulation() } label: {
                    Text("结束本次模拟").font(.subheadline)
                        .foregroundStyle(SelaHomePalette.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("didi.simulation.end")
            }.padding(.top, 3)
        }
        .padding(15)
        .background(SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(SelaHomePalette.line, lineWidth: 0.8) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("didi.chat.card")
    }

    private var progressIndex: Int {
        switch stage {
        case .route: 0
        case .cars: 1
        case .confirm: 2
        case .matching, .driver, .near, .arrived, .cancelled: 3
        }
    }

    private var conversationProgress: some View {
        let labels = ["地点", "车型", "确认", "接车"]
        let cancelled = stage == .cancelled
        return HStack(spacing: 7) {
            ForEach(0..<4, id: \.self) { index in
                VStack(spacing: 6) {
                    Capsule()
                        .fill(index == progressIndex && !cancelled ? SelaHomePalette.accent :
                              index < progressIndex ? SelaHomePalette.accent.opacity(0.45) : SelaHomePalette.line)
                        .frame(height: 3)
                    Text(cancelled && index == 3 ? "已取消" : labels[index])
                        .font(.caption2)
                        .foregroundStyle(index == progressIndex && !cancelled ? SelaHomePalette.accent : SelaHomePalette.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cancelled ? "打车模拟已取消，停在接车步骤，第4步，共4步" :
                            "打车进度，第\(progressIndex + 1)步，共4步，\(labels[progressIndex])")
        .accessibilityIdentifier("didi.chat.progress")
    }

    private var compactRoute: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text((pickup?.name ?? "上车点") + " → " + (destination?.name ?? "目的地"))
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                if !stops.isEmpty {
                    Text("经停 " + stops.map(\.name).joined(separator: " → "))
                        .font(.caption2).foregroundStyle(SelaHomePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("修改") { invalidateRoute() }
                .font(.caption).buttonStyle(.plain).frame(minHeight: 30)
                .accessibilityLabel("修改行程")
        }
        .padding(12)
        .background(SelaHomePalette.accentSurface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var standalonePage: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text(stage.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            if !service.isConfigured {
                                Button("连接滴滴") { showConnection = true }.font(.caption)
                            }
                        }.id("stage")
                        DidiSimulationRouteMap(pickup: pickup, destination: destination, stops: stops,
                            nearby: service.nearbyPlaces.first)
                            .frame(height: stage == .route ? 210 : 155)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        if stage == .route { locationArea }
                        routeCard
                        stageContent
                        if !error.isEmpty {
                            Text(error).font(.caption).foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .onChange(of: stage) { _, _ in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        reader.scrollTo("stage", anchor: .top)
                    }
                }
            }
            .background(SelaHomePalette.background)
            .navigationTitle("打车 · 模拟")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { goBack() } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("上一步")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { closeSimulation() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭打车模拟")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomActions }
            .overlay(alignment: .top) {
                if let banner {
                    DidiSimulationBannerView(banner: banner)
                        .padding(.horizontal, 16).padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity)).zIndex(10)
                }
            }
        }.tint(SelaHomePalette.accent)
    }

    private var locationButtonText: String {
        if service.locationState == .locating { return "定位中…" }
        #if targetEnvironment(simulator)
        return service.locationState == .failed ? "模拟定位失败，重试" : "模拟定位"
        #else
        return service.locationState == .failed ? "定位失败，重试" : "使用我的位置"
        #endif
    }

    private var locationArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("主动定位会将坐标发送滴滴查找附近地点；坐标可能有偏差，请核对地点。")
                .font(.caption).foregroundStyle(SelaHomePalette.secondary)
            Button { service.requestLocation() } label: {
                HStack(spacing: 9) {
                    if service.locationState == .locating { ProgressView().controlSize(.small) }
                    else { Image(systemName: "location.fill") }
                    Text(locationButtonText)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }.frame(minHeight: 38).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(service.locationState == .locating)
                .accessibilityIdentifier("didi.simulation.locate")
            if !service.locationError.isEmpty {
                Text(service.locationError).font(.caption).foregroundStyle(SelaHomePalette.secondary)
            }
            if !service.nearbyPlaces.isEmpty {
                Text("附近上车点").font(.caption).foregroundStyle(SelaHomePalette.secondary)
                ForEach(service.nearbyPlaces.prefix(3)) { place in
                    Button { pickup = place; invalidateRoute() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.and.ellipse").font(.subheadline)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(place.name).font(.subheadline)
                                if !place.detail.isEmpty {
                                    Text(place.detail).font(.caption2).foregroundStyle(SelaHomePalette.secondary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: pickup?.id == place.id ? "checkmark.circle.fill" : "chevron.right")
                                .font(.caption)
                        }.padding(12).background(SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 13))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Text("附近地点搜索结果，请确认现场是否方便上车。")
                    .font(.caption2).foregroundStyle(SelaHomePalette.secondary)
            }
        }
    }

    private var routeCard: some View {
        VStack(spacing: 0) {
            placeButton(label: "上车", place: pickup, placeholder: "选择上车点", target: .pickup)
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, place in
                Divider().padding(.leading, 44)
                HStack(spacing: 0) {
                    placeButton(label: "经停 \(index + 1)", place: place, placeholder: "选择经停点", target: .stop(place.id))
                    if index > 0 {
                        Button {
                            stops.swapAt(index, index - 1); invalidateRoute()
                        } label: { Image(systemName: "arrow.up").font(.caption) }
                            .buttonStyle(.plain).accessibilityLabel("上移" + place.name)
                            .frame(width: 34, height: 44)
                    }
                    Button {
                        stops.removeAll { $0.id == place.id }; invalidateRoute()
                    } label: { Image(systemName: "minus.circle").font(.subheadline) }
                        .buttonStyle(.plain).accessibilityLabel("删除" + place.name)
                        .frame(width: 38, height: 44).padding(.trailing, 4)
                }
            }
            Divider().padding(.leading, 44)
            placeButton(label: "到达", place: destination, placeholder: "选择目的地", target: .destination)
            Divider().padding(.leading, 44)
            Button { picker = .newStop } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus").font(.caption).frame(width: 20)
                    Text("添加经停点").font(.subheadline)
                    Spacer()
                }.padding(.horizontal, 16).frame(minHeight: 46).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("didi.simulation.stops")
        }
        .background(SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(SelaHomePalette.line, lineWidth: 0.7) }
    }

    private func placeButton(label: String, place: DidiSimulationPlace?, placeholder: String,
                             target: DidiSimulationPickerTarget) -> some View {
        Button { picker = target } label: {
            HStack(alignment: .center, spacing: 10) {
                Circle().fill(label == "上车" ? SelaHomePalette.accent : SelaHomePalette.secondary)
                    .frame(width: 6, height: 6).frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(.caption2).foregroundStyle(SelaHomePalette.secondary)
                    Text(place?.name ?? placeholder).font(.subheadline.weight(place == nil ? .regular : .medium))
                        .foregroundStyle(place == nil ? SelaHomePalette.secondary : SelaHomePalette.accent)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "pencil").font(.caption).foregroundStyle(SelaHomePalette.secondary)
            }.padding(16).frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityIdentifier("didi.simulation.place." + target.id)
    }

    @ViewBuilder private var stageContent: some View {
        switch stage {
        case .route:
            EmptyView()
        case .cars:
            if loadingCars {
                HStack(spacing: 12) { ProgressView(); Text("正在查询滴滴车型…").font(.subheadline) }
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else if cars.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("暂未取得可用车型").font(.subheadline)
                    Button("重新查询") { loadCars() }.font(.subheadline)
                }
            } else {
                VStack(spacing: 9) {
                    ForEach(cars) { car in
                        DidiSimulationCarRow(car: car, selected: selectedCarID == car.id) { selectedCarID = car.id }
                    }
                }
                Text("滴滴实时车型与预估价格").font(.caption2).foregroundStyle(SelaHomePalette.secondary)
                if !stops.isEmpty {
                    Text("当前车型预估按起终点查询，未计经停；真实经停服务尚未接入。")
                        .font(.caption2).foregroundStyle(SelaHomePalette.secondary)
                }
            }
        case .confirm:
            if let car = selectedCar {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(car.name).font(.headline)
                        Spacer()
                        Text(car.displayPrice).font(.title3.weight(.semibold))
                    }
                    if !car.detail.isEmpty { Text(car.detail).font(.caption).foregroundStyle(SelaHomePalette.secondary) }
                    Text("接下来只演示司机接单和到达，不会创建订单。")
                        .font(.caption).foregroundStyle(SelaHomePalette.secondary)
                }.padding(18).background(SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 18))
            }
        case .matching:
            HStack(spacing: 12) {
                ProgressView()
                Text("正在寻找司机…").font(.subheadline)
                Spacer()
            }.padding(20).background(SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 18))
        case .driver, .near, .arrived:
            driverCard
        case .cancelled:
            Text("本次体验已取消。").font(.subheadline).foregroundStyle(SelaHomePalette.secondary)
        }
    }

    private var driverCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stage == .arrived ? "已到达" : stage == .near ? "1" : "3")
                    .font(.system(size: stage == .arrived ? 30 : 42, weight: .semibold, design: .rounded))
                if stage != .arrived { Text("分钟后到达").font(.caption).foregroundStyle(SelaHomePalette.secondary) }
            }
            Divider()
            HStack(spacing: 12) {
                Text("陈").font(.headline).frame(width: 42, height: 42)
                    .background(SelaHomePalette.accentSurface, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("陈师傅").font(.subheadline.weight(.semibold))
                    Text("演示司机 · 白色轿车").font(.caption).foregroundStyle(SelaHomePalette.secondary)
                }
                Spacer()
                Image(systemName: "car.side.fill").font(.title3)
            }
            Text("京 A·DEMO").font(.title2.weight(.semibold)).tracking(1.2)
        }.padding(18).background(SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityIdentifier("didi.simulation.driverCard")
    }

    @ViewBuilder private var stageActions: some View {
    switch stage {
    case .route:
        primaryButton("确认行程，查看车型", identifier: "confirmPickup", disabled: !canQuery) { loadCars() }
    case .cars:
        primaryButton("下一步，核对行程", identifier: "review", disabled: selectedCar == nil || loadingCars) { stage = .confirm }
    case .confirm:
        primaryButton("开始体验叫车", identifier: "start", disabled: selectedCar == nil) { startProgress(at: .matching) }
    case .matching, .driver, .near:
        primaryButton("取消本次体验", identifier: "cancel") { cancelTasks(); banner = nil; stage = .cancelled }
    case .arrived, .cancelled:
        primaryButton("再体验一次", identifier: "reset") { reset() }
    }
    }

    private var bottomActions: some View {
        VStack(spacing: 8) { stageActions }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
            .background(SelaHomePalette.background)
            .overlay(alignment: .top) { SelaHomePalette.line.frame(height: 0.7) }
    }

    private func primaryButton(_ title: String, identifier: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 48)
                .foregroundStyle(SelaHomePalette.onSend)
                .background(SelaHomePalette.send, in: RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.4 : 1)
            .accessibilityIdentifier("didi.simulation." + identifier)
    }

    private func place(for target: DidiSimulationPickerTarget) -> DidiSimulationPlace? {
        switch target {
        case .pickup: pickup
        case .destination: destination
        case .newStop: nil
        case .stop(let id): stops.first { $0.id == id }
        }
    }

    private func apply(_ place: DidiSimulationPlace, to target: DidiSimulationPickerTarget) {
        switch target {
        case .pickup: pickup = place
        case .destination: destination = place
        case .newStop:
            guard !stops.contains(where: { $0.id == place.id }) else { return }
            stops.append(place)
        case .stop(let id):
            if let index = stops.firstIndex(where: { $0.id == id }) {
                guard !stops.enumerated().contains(where: { $0.offset != index && $0.element.id == place.id }) else { return }
                stops[index] = place
            }
        }
        invalidateRoute()
    }

    private func invalidateRoute() {
        cancelTasks(); banner = nil; cars = []; selectedCarID = nil; error = ""; stage = .route
    }

    private func loadCars() {
        guard let pickup, let destination, service.isConfigured else { return }
        cancelTasks(); banner = nil; error = ""; cars = []; selectedCarID = nil; stage = .cars; loadingCars = true
        let revision = UUID(); quoteRevision = revision
        let routeStops = stops
        quoteTask = Task { @MainActor in
            do {
                let result = try await service.loadCars(from: pickup, to: destination, stops: routeStops)
                guard !Task.isCancelled, quoteRevision == revision else { return }
                cars = result; selectedCarID = result.first?.id; loadingCars = false
            } catch {
                guard !Task.isCancelled, quoteRevision == revision else { return }
                self.error = error.localizedDescription; loadingCars = false
            }
        }
    }

    private func goBack() {
        switch stage {
        case .route: closeSimulation()
        case .cars: cancelTasks(); error = ""; stage = .route
        case .confirm: cancelTasks(); banner = nil; stage = .cars
        case .matching: cancelTasks(); banner = nil; stage = .confirm
        case .driver, .near, .arrived: cancelTasks(); banner = nil; stage = .confirm
        case .cancelled: stage = selectedCar == nil ? .route : .confirm
        }
    }

    private func startProgress(at startingStage: DidiSimulationStage) {
        cancelTasks(); banner = nil; stage = startingStage
        rideTask = Task { @MainActor in
            do {
                if stage == .matching {
                    try await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled, stage == .matching else { return }
                    stage = .driver; showBanner(.accepted)
                }
                if stage == .driver {
                    try await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled, stage == .driver else { return }
                    stage = .near
                }
                if stage == .near {
                    try await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled, stage == .near else { return }
                    stage = .arrived; showBanner(.arrived)
                }
            } catch { }
        }
    }

    private func showBanner(_ value: DidiSimulationBanner) {
        bannerTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { banner = value }
        bannerTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { banner = nil }
            } catch { }
        }
    }

    private func publishSummary() {
        onSummary("打车模拟 · " + stage.title)
    }

    private func closeSimulation() {
        cancelTasks(); banner = nil; clearSelections(); service.disconnect()
        if let onEnd { onEnd() }
        else { dismiss() }
    }

    private func clearSelections() {
        pickup = nil; destination = nil; stops = []; cars = []; selectedCarID = nil; picker = nil
    }

    private func reset() {
        cancelTasks(); banner = nil; clearSelections(); error = ""
        service.resetTripData(); stage = .route
    }
    private func cancelTasks() {
        quoteRevision = UUID(); loadingCars = false
        quoteTask?.cancel(); quoteTask = nil
        rideTask?.cancel(); rideTask = nil
        bannerTask?.cancel(); bannerTask = nil
    }
}

/// One real assistant-message anchor. Old or restored sessions remain read-only.
@MainActor
struct DidiConversationCard: View {
    let sessionID: UUID
    let messageID: UUID
    let conversationID: UUID
    let active: Bool
    let onSummary: (String) -> Void
    let onEnd: () -> Void
    let onRestart: () -> Void
    @ObservedObject private var registry = DidiChatSimulationRegistry.shared

    var body: some View {
        Group {
            if active {
                DidiRideSimulationView(embedded: true, initialRequest: registry.request(sessionID: sessionID), onSummary: onSummary, onEnd: onEnd)
                    .id(sessionID)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label("打车 · 模拟", systemImage: "car.side").font(.caption.weight(.semibold))
                        .foregroundStyle(SelaHomePalette.secondary)
                    Text("本次模拟已结束").font(.subheadline)
                    Button("重新体验", action: onRestart).font(.subheadline)
                        .buttonStyle(.plain).frame(minHeight: 40)
                }
                .padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).stroke(SelaHomePalette.line, lineWidth: 0.8) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("didi.chat.message." + messageID.uuidString)
    }
}

private enum DidiSimulationStage: Equatable {
    case route, cars, confirm, matching, driver, near, arrived, cancelled
    var title: String {
        switch self {
        case .route: "先确定行程"
        case .cars: "选择车型"
        case .confirm: "核对行程"
        case .matching: "正在寻找司机"
        case .driver: "找到司机了"
        case .near: "司机快到了"
        case .arrived: "司机已到达"
        case .cancelled: "已取消"
        }
    }
}

private enum DidiSimulationPickerTarget: Identifiable {
    case pickup, destination, newStop, stop(String)
    var id: String {
        switch self { case .pickup: "pickup"; case .destination: "destination"; case .newStop: "new-stop"; case .stop(let id): "stop-" + id }
    }
    var title: String {
        switch self { case .pickup: "选择上车点"; case .destination: "选择目的地"; case .newStop, .stop: "选择经停点" }
    }
    func searchHint(_ hints: DidiRequestHints) -> String {
        switch self { case .pickup: hints.pickup; case .destination: hints.destination; case .newStop, .stop: "" }
    }
}

@MainActor
private struct DidiSimulationPlacePicker: View {
    let title: String
    let near: DidiSimulationPlace?
    @ObservedObject var service: DidiSimulationService
    let onSelect: (DidiSimulationPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition
    @State private var selected: DidiSimulationPlace?
    @State private var query = ""
    @State private var city = ""
    @State private var results: [DidiSimulationPlace] = []
    @State private var searching = false
    @State private var resolving = false
    @State private var error = ""
    @State private var requestRevision = UUID()
    @State private var requestTask: Task<Void, Never>?

    init(title: String, initial: DidiSimulationPlace?, initialQuery: String, near: DidiSimulationPlace?,
         service: DidiSimulationService, onSelect: @escaping (DidiSimulationPlace) -> Void) {
        self.title = title; self.near = near; self.service = service; self.onSelect = onSelect
        _selected = State(initialValue: initial)
        _query = State(initialValue: initialQuery)
        _city = State(initialValue: initial?.city.isEmpty == false ? initial!.city : (near?.city ?? ""))
        let center = initial ?? near
        _position = State(initialValue: center.map { .region($0.region) } ?? .automatic)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                TextField("地点所在城市，如上海市", text: $city).font(.subheadline)
                    .accessibilityIdentifier("didi.simulation.city")
                    .padding(13).background(SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 13)).padding(.horizontal, 16).padding(.top, 12)
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(SelaHomePalette.secondary)
                    TextField("搜索地址", text: $query).font(.subheadline).submitLabel(.search).onSubmit { search() }
                        .accessibilityIdentifier("didi.simulation.search")
                    Button("搜索") { search() }.font(.subheadline).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searching)
                }.padding(13).background(SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 13)).padding(16)
                }
                ZStack(alignment: .top) {
                    DidiSimulationMap(position: $position, onCoordinate: resolveCoordinate)
                    if searching {
                        ProgressView("搜索中…").padding(20).frame(maxWidth: .infinity).background(SelaHomePalette.surface)
                    } else if !results.isEmpty {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(results) { place in
                                    Button { chooseSearchResult(place) } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(place.name).font(.subheadline.weight(.medium))
                                            Text(place.detail).font(.caption).foregroundStyle(SelaHomePalette.secondary).lineLimit(2)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Divider()
                                }
                            }
                        }.frame(maxHeight: 300).background(SelaHomePalette.surface)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    if resolving {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在获取地址…").font(.subheadline) }
                    } else if let selected {
                        Text(selected.name).font(.subheadline.weight(.semibold))
                        if !selected.detail.isEmpty {
                            Text(selected.detail).font(.caption).foregroundStyle(SelaHomePalette.secondary).lineLimit(3)
                        }
                    } else {
                        Text("搜索地址，或拖动地图选点").font(.subheadline).foregroundStyle(SelaHomePalette.secondary)
                    }
                    Text("定位和地图选点可能存在偏差；询价前请搜索并选择滴滴返回的地点。")
                        .font(.caption).foregroundStyle(SelaHomePalette.secondary)
                    if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
                    Button {
                        guard let selected, !resolving else { return }
                        requestTask?.cancel(); onSelect(selected); dismiss()
                    } label: {
                        Text("确认这个地点").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 48)
                            .foregroundStyle(SelaHomePalette.onSend)
                            .background(SelaHomePalette.send, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).disabled(selected == nil || resolving || searching).opacity(selected == nil || resolving || searching ? 0.4 : 1)
                        .accessibilityIdentifier("didi.simulation.place.confirm")
                }.padding(18).background(SelaHomePalette.background)
            }
            .background(SelaHomePalette.background)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("返回") { requestTask?.cancel(); dismiss() } } }
            .onDisappear { requestTask?.cancel() }
        }.tint(SelaHomePalette.accent)
    }

    private func search() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        requestTask?.cancel(); let revision = UUID(); requestRevision = revision
        searching = true; resolving = false; error = ""; results = []
        requestTask = Task { @MainActor in
            do {
                let places = try await service.searchPlaces(value, city: city, near: selected ?? near)
                guard !Task.isCancelled, requestRevision == revision else { return }
                results = places; searching = false
                if places.isEmpty { error = "没有找到地点，请换个关键词。" }
            } catch {
                guard !Task.isCancelled, requestRevision == revision else { return }
                self.error = error.localizedDescription; searching = false
            }
        }
    }

    private func chooseSearchResult(_ place: DidiSimulationPlace) {
        requestTask?.cancel(); requestRevision = UUID(); selected = place
        results = []; error = ""; searching = false; resolving = false; position = .region(place.region)
    }

    private func resolveCoordinate(_ coordinate: CLLocationCoordinate2D, recenter: Bool) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        requestTask?.cancel(); let revision = UUID(); requestRevision = revision
        selected = nil; resolving = true; searching = false; results = []; error = ""
        if recenter { position = .region(.init(center: coordinate, span: .init(latitudeDelta: 0.008, longitudeDelta: 0.008))) }
        requestTask = Task { @MainActor in
            do {
                let place = try await service.resolvePlace(latitude: coordinate.latitude, longitude: coordinate.longitude)
                guard !Task.isCancelled, requestRevision == revision else { return }
                selected = place; resolving = false
            } catch {
                guard !Task.isCancelled, requestRevision == revision else { return }
                self.error = "地址暂未解析，可换点或搜索地点。"
                selected = DidiSimulationPlace(id: "map-\(coordinate.latitude)-\(coordinate.longitude)", name: "地图选点",
                    detail: "手动选点",
                    latitude: coordinate.latitude, longitude: coordinate.longitude, city: city)
                resolving = false
            }
        }
    }
}

private struct DidiSimulationRouteMap: View {
    let pickup: DidiSimulationPlace?
    let destination: DidiSimulationPlace?
    let stops: [DidiSimulationPlace]
    let nearby: DidiSimulationPlace?
    private var mapIdentity: String {
        ([pickup?.id ?? "", destination?.id ?? "", nearby?.id ?? ""] + stops.map(\.id)).joined(separator: "|")
    }
    private var initialPosition: MapCameraPosition {
        if pickup != nil || destination != nil || !stops.isEmpty { return .automatic }
        return nearby.map { .region($0.region) } ?? .automatic
    }
    var body: some View {
        Group {
            if pickup == nil && destination == nil && nearby == nil && stops.isEmpty {
                ZStack {
                    SelaHomePalette.accentSurface
                    Label("选择地点后显示行程地图", systemImage: "map")
                        .font(.caption).foregroundStyle(SelaHomePalette.secondary)
                }
            } else {
                Map(initialPosition: initialPosition, interactionModes: []) {
                    if let pickup { Marker("上车", coordinate: pickup.coordinate).tint(SelaHomePalette.accent) }
                    if let destination { Marker("目的地", coordinate: destination.coordinate).tint(.orange) }
                    ForEach(stops) { stop in Marker(stop.name, coordinate: stop.coordinate).tint(.gray) }
                }
                .mapStyle(.standard(elevation: .flat)).mapControlVisibility(.hidden)
                .id(mapIdentity)
            }
        }
        .accessibilityLabel("行程地图，点按下方地址修改地点")
    }

}

private final class DidiSimulationMapInteraction: ObservableObject {
    // Reference-only state: programmatic camera callbacks must never redraw Map.
    var awaitingUserDragEnd = false
}

private struct DidiSimulationMap: View {
    @StateObject private var interaction = DidiSimulationMapInteraction()
    @Binding var position: MapCameraPosition
    let onCoordinate: (CLLocationCoordinate2D, Bool) -> Void

    var body: some View {
        MapReader { proxy in
            Map(position: $position, interactionModes: [.pan, .zoom]) { }
                .mapStyle(.standard(elevation: .flat)).mapControlVisibility(.hidden)
                .onMapCameraChange(frequency: .onEnd) { context in
                    guard interaction.awaitingUserDragEnd, position.positionedByUser else { return }
                    interaction.awaitingUserDragEnd = false
                    onCoordinate(context.camera.centerCoordinate, false)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in
                    interaction.awaitingUserDragEnd = true
                })
                .onChange(of: position.positionedByUser) { _, byUser in
                    if !byUser { interaction.awaitingUserDragEnd = false }
                }
                .onTapGesture { point in
                    guard let coordinate = proxy.convert(point, from: .local) else { return }
                    interaction.awaitingUserDragEnd = false
                    onCoordinate(coordinate, true)
                }
                .overlay {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 34))
                        .symbolRenderingMode(.palette).foregroundStyle(SelaHomePalette.accent, SelaHomePalette.surface)
                        .offset(y: -16).allowsHitTesting(false)
                }
                .accessibilityLabel("地图，拖动或点按选择地点")
        }
    }
}

private struct DidiSimulationCarRow: View {
    let car: DidiSimulationCar
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "car.side").font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(car.name).font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 4)
                Text(car.displayPrice).font(.subheadline.weight(.semibold))
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.subheadline)
            }.padding(14)
                .background(selected ? SelaHomePalette.accentSurface : SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 15))
                .overlay { RoundedRectangle(cornerRadius: 15).stroke(selected ? SelaHomePalette.accent : SelaHomePalette.line, lineWidth: selected ? 1.2 : 0.7) }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
private struct DidiSimulationConnectionView: View {
    @ObservedObject var service: DidiSimulationService
    @Environment(\.dismiss) private var dismiss
    @State private var credential = ""
    @State private var connecting = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                SecureField("滴滴 MCP Key", text: $credential).textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
                Button(connecting ? "连接中…" : "连接") { connect() }.disabled(connecting || credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.navigationTitle("连接滴滴").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("返回") { credential = ""; dismiss() } } }
                .onDisappear {
                    credential = ""
                    if connecting { connectionTask?.cancel(); service.disconnect(); connecting = false }
                }
        }.tint(SelaHomePalette.accent)
    }
    private func connect() {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        credential = ""; connecting = true; error = ""
        connectionTask = Task { @MainActor in
            do {
                try await service.configure(credential: value)
                guard !Task.isCancelled else { return }
                connecting = false; dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription.replacingOccurrences(of: value, with: "[隐藏]"); connecting = false
            }
        }
    }
}

private enum DidiSimulationBanner {
    case accepted, arrived
    var title: String { self == .accepted ? "司机已接单" : "司机已到达" }
    var detail: String { self == .accepted ? "陈师傅预计 3 分钟后到达。" : "白色轿车 · 京 A·DEMO" }
}

private struct DidiSimulationBannerView: View {
    let banner: DidiSimulationBanner
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "car.side.fill").font(.title3)
            VStack(alignment: .leading, spacing: 5) {
                Text(banner.title).font(.subheadline.weight(.semibold))
                Text(banner.detail).font(.caption).foregroundStyle(SelaHomePalette.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16).background(SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(SelaHomePalette.line, lineWidth: 0.8) }
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
            .accessibilityElement(children: .combine).accessibilityIdentifier("didi.simulation.banner")
    }
}
