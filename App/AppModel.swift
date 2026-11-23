import UIKit
import ResizeCore

/// The app's state, ported from the SwiftUI AppModel without Swift concurrency
/// (iOS 12). Service completions hop to the main queue; every public method
/// runs on the main queue and ends by notifying `onChange`.
final class AppModel {
    private(set) var machine: WorkflowMachine
    private(set) var snapshot: ServiceSnapshot? {
        didSet {
            var stable = snapshot
            stable?.capturedAt = Date(timeIntervalSince1970: 0)
            snapshotKey = stable.flatMap { try? JSONEncoder().encode($0) }.map { $0.base64EncodedString() } ?? "-"
        }
    }
    /// The snapshot without its capture time, encoded once per poll instead of on
    /// every render (a drag renders many times a second).
    private(set) var snapshotKey = "-"
    private(set) var reviewedPlan: ResizePlan?
    private(set) var connectionOK = false
    private(set) var receivedAt: Date?
    private(set) var connectionMessage: String?
    var error: String? { didSet { if error != oldValue { notify() } } }
    private(set) var busy = false
    private(set) var targetText = ""
    private(set) var freeText = ""
    /// The exact size behind a target the app filled in itself (current size,
    /// "Use available space", or derived from the free space). The field shows it
    /// rounded like every other size; typing in the field drops it.
    private var targetExact: Int64?
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
    /// Only Linux partitions (any Linux type, Orchard's root and boot included) are
    /// offered for erasing. Anything else after APFS just limits growth.
    var canEraseFollowing: Bool {
        let following = followingPartitions
        return !following.isEmpty && following.allSatisfy(\.isLinux)
    }
    /// The layout the size limits come from: without the approved partitions.
    var editingLayout: StorageLayout? {
        guard var layout else { return nil }
        if eraseFollowing { let end = layout.apfs.lastLBA; layout.partitions.removeAll { $0.firstLBA > end } }
        return layout
    }
    /// How large APFS may get. A gap after APFS smaller than the display rounding
    /// (an alignment remainder of a few MB) is not offered: growing into it would
    /// show "24 GB" becoming "24 GB".
    var maximumBytes: Int64? {
        guard let layout = editingLayout else { return nil }
        let tolerance: Int64 = 50_000_000
        return layout.maximumBytes - layout.containerBytes < tolerance && layout.maximumBytes >= layout.containerBytes
            ? layout.containerBytes : layout.maximumBytes
    }
    /// The requested size: the exact derived value, or what was typed. A typed
    /// value within the display rounding (0.05 GB) of the maximum, on either
    /// side, means the maximum: typing back the "31.6" shown for 31.64 GB or for
    /// 31.599980544 GB fills the space exactly instead of leaving a sliver
    /// unallocated or being refused. Just below the minimum means the minimum.
    var targetBytes: Int64? {
        if let targetExact { return targetExact }
        guard let typed = Capacity.parseGB(targetText) else { return nil }
        guard let layout = editingLayout, let maximum = maximumBytes else { return typed }
        let tolerance: Int64 = 50_000_000
        if abs(typed - maximum) < tolerance { return maximum }
        if let minimum = layout.minimumContainerBytes, typed < minimum, minimum - typed < tolerance { return minimum }
        return typed
    }
    var request: PlanRequest? {
        guard let layout, let bytes = targetBytes else { return nil }
        return PlanRequest(revision: layout.revision, requestedBytes: bytes,
                           createLinux: createLinux && canCreateLinuxPartition,
                           replacing: eraseFollowing ? followingPartitions.map(\.id) : [])
    }
    var canCreateLinuxPartition: Bool {
        guard let layout, let bytes = targetBytes else { return false }
        let candidate = PlanRequest(revision: layout.revision, requestedBytes: bytes, createLinux: true,
                                    replacing: eraseFollowing ? followingPartitions.map(\.id) : [])
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
            createLinux = false; eraseFollowing = false
            setDerivedTarget(layout.containerBytes, notifying: false)
            reviewedPlan = nil; editRevision = layout.revision; error = nil
        } catch { self.error = error.localizedDescription }
        notify()
    }
    /// A size as the fields show it: at most one decimal, "." as in what the fields accept.
    static func display(_ bytes: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.roundingMode = .halfEven
        return formatter.string(from: NSNumber(value: Double(bytes) / 1_000_000_000)) ?? Capacity.input(bytes)
    }
    private func updateFree() {
        if let bytes = targetBytes, let maximum = maximumBytes { freeText = Self.display(max(0, maximum - bytes)) }
    }
    private func setDerivedTarget(_ bytes: Int64, notifying: Bool = true) {
        targetExact = bytes; targetText = Self.display(bytes); reviewedPlan = nil; error = nil
        updateFree()
        if !canCreateLinuxPartition { createLinux = false }
        if notifying { notify() }
    }
    func setTarget(_ text: String) {
        targetText = text; targetExact = nil; reviewedPlan = nil; error = nil
        if Capacity.parseGB(text) != nil {
            updateFree()
            if !canCreateLinuxPartition { createLinux = false }
        }
        notify()
    }
    func setFree(_ text: String) {
        freeText = text; reviewedPlan = nil; error = nil
        if let bytes = Capacity.parseGB(text), let maximum = maximumBytes, bytes <= maximum {
            targetExact = maximum - bytes; targetText = Self.display(maximum - bytes)
            if !canCreateLinuxPartition { createLinux = false }
        } else { targetText = ""; targetExact = nil }
        notify()
    }
    func useAvailable() { if let maximum = maximumBytes { setDerivedTarget(maximum) } }
    /// While the bar is dragged: the fields follow without a render; the drag's
    /// end commits through `setTarget`/`useAvailable`, which renders once.
    func previewTarget(_ gb: Double) {
        guard let maximum = maximumBytes else { return }
        if gb >= Double(maximum) / 1e9 - 0.001 { targetExact = maximum; targetText = Self.display(maximum) }
        else { targetExact = nil; targetText = String(format: "%.0f", gb) }
        reviewedPlan = nil
        updateFree()
    }
    func setCreateLinux(_ value: Bool) {
        createLinux = value && canCreateLinuxPartition; reviewedPlan = nil
        notify()
    }
    func setEraseFollowing(_ value: Bool) {
        guard canEraseFollowing || !value else { return }
        eraseFollowing = value
        reviewedPlan = nil
        // The limit changed. A size past the new limit follows it, as the bar's
        // boundary does, instead of staying behind as an error; any other size stays.
        if let bytes = targetBytes, let maximum = maximumBytes, bytes > maximum {
            targetExact = maximum; targetText = Self.display(maximum); error = nil
        }
        updateFree()
        createLinux = createLinux && canCreateLinuxPartition
        notify()
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

    // MARK: System snapshot

    /// Remove orig-fs (after the user confirmed) or take a new one: from the storage
    /// overview or the size editor, never during an operation; the service checks
    /// again. In the editor, the new storage revision is the user's own change, so
    /// editing continues with the new limit instead of "Storage changed".
    func removeSnapshot() { snapshotAction(remove: true) }
    func takeSnapshot() { snapshotAction(remove: false) }
    private func snapshotAction(remove: Bool) {
        guard [.overview, .editor].contains(state), let layout, let system = layout.systemSnapshot, !busy else { return }
        busy = true; error = nil
        notify()
        let request = SnapshotRequest(revision: layout.revision, name: system.name)
        let completion: ServiceCompletion<ServiceSnapshot> = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.busy = false; self.notify() }
                switch result {
                case .success(let fresh):
                    if let current = self.snapshot, fresh.capturedAt < current.capturedAt { return }
                    if self.state == .editor { self.editRevision = fresh.layout.revision; self.reviewedPlan = nil }
                    self.snapshot = fresh; self.connectionOK = true; self.receivedAt = Date()
                    self.machine.receive(fresh)
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
        if remove { service.removeSnapshot(request, completion: completion) }
        else { service.takeSnapshot(request, completion: completion) }
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
