import UIKit
import ResizeCore

/// The app's state, ported from the SwiftUI AppModel without Swift concurrency
/// (iOS 12). Service completions hop to the main queue; every public method
/// runs on the main queue and ends by notifying `onChange`.
final class AppModel {
    private(set) var machine: WorkflowMachine
    private(set) var snapshot: ServiceSnapshot?
    private(set) var reviewedPlan: ResizePlan?
    private(set) var connectionOK = false
    private(set) var receivedAt: Date?
    private(set) var connectionMessage: String?
    var error: String? { didSet { notify() } }
    private(set) var busy = false
    private(set) var targetText = ""
    private(set) var freeText = ""
    private(set) var createLinux = false
    /// The partitions after APFS the user approved erasing (all of them, or none).
    private(set) var eraseFollowing = false
    let service: ResizeService
    let isSimulator: Bool
    var onChange: (() -> Void)?

    /// Replaces the cancellable polling Task: a refresh only counts while its
    /// polling generation is current, as `Task.isCancelled` guarded it before.
    private var polling = false
    private var pollGeneration = 0
    private var editRevision: UUID?

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

    private func notify() { onChange?() }

    var layout: StorageLayout? { snapshot?.layout }
    var state: ScreenState { machine.state }
    var operation: ResizeCore.Operation? { snapshot?.operation }

    /// The partitions after APFS, which only an approved erase can replace.
    var followingPartitions: [Partition] {
        guard let layout else { return [] }
        return layout.partitions.filter { $0.firstLBA > layout.apfs.lastLBA }.sorted { $0.firstLBA < $1.firstLBA }
    }
    /// The layout the size limits come from: without the approved partitions.
    var editingLayout: StorageLayout? {
        guard var layout else { return nil }
        if eraseFollowing { let end = layout.apfs.lastLBA; layout.partitions.removeAll { $0.firstLBA > end } }
        return layout
    }
    var request: PlanRequest? {
        guard let layout, let bytes = Capacity.parseGB(targetText) else { return nil }
        return PlanRequest(revision: layout.revision, requestedBytes: bytes,
                           createLinux: createLinux && canCreateLinuxPartition,
                           replacing: eraseFollowing ? followingPartitions.map(\.id) : [])
    }
    var canCreateLinuxPartition: Bool {
        guard !eraseFollowing, let layout, let bytes = Capacity.parseGB(targetText) else { return false }
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
    /// The requested size equals the current layout: nothing to review yet.
    var unchanged: Bool {
        guard let layout, let request, !request.createLinux, request.replacing.isEmpty else { return false }
        let target = alignDown(request.requestedBytes, to: max(Int64(4096), layout.sectorSize))
        return target == layout.containerBytes && target == layout.backingBytes
    }

    // MARK: Connection

    func connect() {
        guard !polling else { return }
        polling = true
        pollGeneration += 1
        poll(pollGeneration)
    }
    func disconnectUI() { polling = false; pollGeneration += 1 }

    private func poll(_ generation: Int) {
        refresh(generation: generation) { [weak self] in
            guard let self, self.polling, generation == self.pollGeneration else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.polling, generation == self.pollGeneration else { return }
                self.poll(generation)
            }
        }
    }

    /// `generation`: the polling round that asked; nil for an explicit check.
    func refresh(generation: Int? = nil, completion: (() -> Void)? = nil) {
        service.snapshot { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { completion?() }
                if let generation, !self.polling || generation != self.pollGeneration { return }
                switch result {
                case .success(let fresh):
                    if let current = self.snapshot, fresh.capturedAt < current.capturedAt { return }
                    guard fresh.mode == (self.isSimulator ? "mock" : "device") else {
                        self.connectionLost(ResizeError("The service mode does not match this app build. No storage operation is allowed."))
                        return
                    }
                    if let editRevision = self.editRevision, [.editor, .review].contains(self.state), fresh.layout.revision != editRevision {
                        self.reviewedPlan = nil
                        self.error = "Storage changed while editing. Review a fresh plan before applying changes."
                    }
                    self.snapshot = fresh; self.connectionOK = true; self.receivedAt = Date(); self.connectionMessage = nil
                    self.machine.receive(fresh)
                    self.notify()
                case .failure(let error):
                    self.connectionLost(error)
                }
            }
        }
    }
    private func connectionLost(_ error: Error) {
        connectionOK = false; connectionMessage = error.localizedDescription
        machine.connectionLost()
        notify()
    }

    // MARK: Editing

    func edit() {
        guard let layout else { return }
        do {
            try layout.validate(); try machine.edit()
            targetText = Capacity.input(layout.containerBytes)
            freeText = Capacity.input(layout.maximumBytes - layout.containerBytes)
            createLinux = false; eraseFollowing = false; reviewedPlan = nil; editRevision = layout.revision; error = nil
        } catch { self.error = error.localizedDescription }
        notify()
    }
    func setTarget(_ text: String) {
        targetText = text; reviewedPlan = nil; error = nil
        if let bytes = Capacity.parseGB(text), let layout = editingLayout {
            freeText = Capacity.input(max(0, layout.maximumBytes - bytes))
            if !canCreateLinuxPartition { createLinux = false }
        }
        notify()
    }
    func setFree(_ text: String) {
        freeText = text; reviewedPlan = nil; error = nil
        if let bytes = Capacity.parseGB(text), let layout = editingLayout, bytes <= layout.maximumBytes {
            targetText = Capacity.input(layout.maximumBytes - bytes)
            if !canCreateLinuxPartition { createLinux = false }
        } else { targetText = "" }
        notify()
    }
    func useAvailable() { if let layout = editingLayout { setTarget(Capacity.input(layout.maximumBytes)) } }
    func setCreateLinux(_ value: Bool) {
        createLinux = value && canCreateLinuxPartition; reviewedPlan = nil
        notify()
    }
    func setEraseFollowing(_ value: Bool) {
        guard !followingPartitions.isEmpty else { return }
        eraseFollowing = value
        if value { createLinux = false }
        // The limit changed; keep the typed size and recompute the free space.
        setTarget(targetText)
    }
    func back() { machine.back(); error = nil; notify() }
    func cancelEditing() {
        machine.back(); if state == .editor { machine.back() }
        error = nil; notify()
    }

    // MARK: Review and start

    func review() {
        guard let request, !busy else { return }
        busy = true; error = nil
        notify()
        service.plan(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.busy = false; self.notify() }
                switch result {
                case .success(let plan):
                    guard self.state == .editor else { return }
                    self.reviewedPlan = plan; self.editRevision = plan.before.revision
                    do { try self.machine.review() } catch { self.error = error.localizedDescription }
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }
    func apply() {
        guard let plan = reviewedPlan, !busy else { return }
        do { try machine.submit() } catch { self.error = error.localizedDescription; return }
        busy = true; error = nil
        notify()
        service.start(StartRequest(planID: plan.id, requestID: UUID())) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.busy = false; self.notify() }
                switch result {
                case .success(let accepted):
                    self.snapshot = accepted; self.connectionOK = true; self.receivedAt = Date(); self.machine.receive(accepted)
                case .failure:
                    // A lost start response can mean the operation started. Never resubmit.
                    self.error = "Could not confirm the start request. Checking service status; no retry was sent."
                    self.connectionOK = false; self.machine.connectionLost()
                }
            }
        }
    }
    func done() {
        guard let operation else { return }
        do {
            try machine.acknowledge(operation)
            UserDefaults.standard.set(operation.id.uuidString, forKey: "acknowledgedOperation")
            reviewedPlan = nil; error = nil
        } catch { self.error = error.localizedDescription }
        notify()
    }

    // MARK: Simulator mock service

    func configure(_ scenario: MockScenario, scale: Double, completion: @escaping (Bool) -> Void) {
        busy = true
        notify()
        service.configureMock(ScenarioRequest(scenario: scenario, timeScale: scale, discardSimulation: true)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.busy = false; self.notify() }
                switch result {
                case .success(let fresh):
                    self.machine.resetMock(); self.snapshot = fresh; self.machine.receive(fresh)
                    self.reviewedPlan = nil; self.editRevision = nil; self.connectionOK = true; self.receivedAt = Date(); self.error = nil
                    UserDefaults.standard.removeObject(forKey: "acknowledgedOperation")
                    completion(true)
                case .failure(let error):
                    self.error = error.localizedDescription
                    completion(false)
                }
            }
        }
    }
}
