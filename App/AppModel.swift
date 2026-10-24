import SwiftUI
import ResizeCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var machine: WorkflowMachine
    @Published private(set) var snapshot: ServiceSnapshot?
    @Published private(set) var reviewedPlan: ResizePlan?
    @Published private(set) var connectionOK = false
    @Published private(set) var receivedAt: Date?
    @Published private(set) var connectionMessage: String?
    @Published var error: String?
    @Published var busy = false
    @Published var targetText = ""
    @Published var freeText = ""
    @Published var createLinux = false
    @Published var showLab = false
    @Published var showTechnical = false
    let service: any ResizeService
    private var polling: Task<Void, Never>?
    private var editRevision: UUID?
    let isSimulator: Bool

    init() {
        let acknowledged = UserDefaults.standard.string(forKey: "acknowledgedOperation").flatMap(UUID.init(uuidString:))
        machine = WorkflowMachine(acknowledgedOperationID: acknowledged)
        #if targetEnvironment(simulator)
        isSimulator = true
        let args = ProcessInfo.processInfo.arguments
        let url = args.firstIndex(of: "--service-url").flatMap { $0 + 1 < args.count ? URL(string: args[$0 + 1]) : nil }
        service = HTTPResizeService(baseURL: url ?? URL(string: "http://127.0.0.1:8472")!)
        #else
        isSimulator = false
        service = LocalSocketResizeService()
        #endif
    }

    var layout: StorageLayout? { snapshot?.layout }
    var state: ScreenState { machine.state }
    var operation: ResizeCore.Operation? { snapshot?.operation }
    var request: PlanRequest? {
        guard let layout, let bytes = Capacity.parseGB(targetText) else { return nil }
        return PlanRequest(revision: layout.revision, requestedBytes: bytes,
                           createLinux: createLinux && canCreateLinuxPartition)
    }
    var canCreateLinuxPartition: Bool {
        guard let layout, let bytes = Capacity.parseGB(targetText) else { return false }
        let candidate = PlanRequest(revision: layout.revision, requestedBytes: bytes, createLinux: true)
        return (try? Planner.make(candidate, on: layout)) != nil
    }
    var localPlan: ResizePlan? {
        guard let request, let layout else { return nil }
        return try? Planner.make(request, on: layout)
    }
    var editorMessage: String? {
        guard let layout else { return nil }
        guard let request else { return "Enter a valid size in GB." }
        do { _ = try Planner.make(request, on: layout); return nil }
        catch { return error.localizedDescription }
    }

    func connect() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
            }
        }
    }
    func disconnectUI() { polling?.cancel(); polling = nil }

    func refresh() async {
        do {
            let fresh = try await service.snapshot()
            guard !Task.isCancelled else { return }
            if let current = snapshot, fresh.capturedAt < current.capturedAt { return }
            guard fresh.mode == (isSimulator ? "mock" : "device") else {
                throw ResizeError("The service mode does not match this app build. No storage operation is allowed.")
            }
            if let editRevision, [.editor, .review].contains(state), fresh.layout.revision != editRevision {
                reviewedPlan = nil
                error = "Storage changed while editing. Review a fresh plan before applying changes."
            }
            snapshot = fresh; connectionOK = true; receivedAt = Date(); connectionMessage = nil
            machine.receive(fresh)
        } catch {
            guard !Task.isCancelled else { return }
            connectionOK = false; connectionMessage = error.localizedDescription
            machine.connectionLost()
        }
    }

    func edit() {
        guard let layout else { return }
        do {
            try layout.validate(); try machine.edit()
            targetText = Capacity.input(layout.containerBytes)
            freeText = Capacity.input(layout.maximumBytes - layout.containerBytes)
            createLinux = false; reviewedPlan = nil; editRevision = layout.revision; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func setTarget(_ text: String) {
        targetText = text; reviewedPlan = nil; error = nil
        if let bytes = Capacity.parseGB(text), let layout {
            freeText = Capacity.input(max(0, layout.maximumBytes - bytes))
            if !canCreateLinuxPartition { createLinux = false }
        }
    }
    func setFree(_ text: String) {
        freeText = text; reviewedPlan = nil; error = nil
        if let bytes = Capacity.parseGB(text), let layout, bytes <= layout.maximumBytes {
            targetText = Capacity.input(layout.maximumBytes - bytes)
            if !canCreateLinuxPartition { createLinux = false }
        } else { targetText = "" }
    }
    func useAvailable() { if let layout { setTarget(Capacity.input(layout.maximumBytes)) } }
    func back() { machine.back(); error = nil }

    func review() async {
        guard let request, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let plan = try await service.plan(request)
            guard state == .editor else { return }
            reviewedPlan = plan; editRevision = plan.before.revision
            try machine.review()
        } catch { self.error = error.localizedDescription }
    }
    func apply() async {
        guard let plan = reviewedPlan, !busy else { return }
        do { try machine.submit() } catch { self.error = error.localizedDescription; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let accepted = try await service.start(StartRequest(planID: plan.id, requestID: UUID()))
            snapshot = accepted; connectionOK = true; receivedAt = Date(); machine.receive(accepted)
        } catch {
            // A lost POST response can mean the operation started. Never resubmit.
            self.error = "Could not confirm the start request. Checking service status; no retry was sent."
            connectionOK = false; machine.connectionLost()
        }
    }
    func done() {
        guard let operation else { return }
        do {
            try machine.acknowledge(operation)
            UserDefaults.standard.set(operation.id.uuidString, forKey: "acknowledgedOperation")
            reviewedPlan = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func configure(_ scenario: MockScenario, scale: Double) async {
        busy = true
        defer { busy = false }
        do {
            let fresh = try await service.configureMock(ScenarioRequest(scenario: scenario, timeScale: scale, discardSimulation: true))
            machine.resetMock(); snapshot = fresh; machine.receive(fresh)
            reviewedPlan = nil; editRevision = nil; connectionOK = true; receivedAt = Date(); error = nil
            UserDefaults.standard.removeObject(forKey: "acknowledgedOperation")
            showLab = false
        } catch { self.error = error.localizedDescription }
    }
}
