import Foundation
import Darwin
import ResizeCore
import NativeSystem

/// The helper's operation state. iOS 12 has no Swift concurrency, so this is a
/// class guarded by one lock instead of an actor. The lock is released exactly
/// where the actor used to suspend (disk inspections, the worker heartbeat
/// sleep); everything between those points runs as one locked step, as it ran
/// isolated on the actor. Blocking disk reads therefore never hold the lock, and
/// status requests stay answerable while an inspection or the worker runs.
public final class DeviceEngine: @unchecked Sendable {
    private struct Record: Codable {
        var operation: ResizeCore.Operation
        var workerJob: URL?
        var bootIdentity: String
    }
    private let source: DeviceSource
    private let directory: URL
    private let executable: String
    private let lock = NSRecursiveLock()
    private var record: Record?
    private var inspection: DeviceInspection?
    private var inspectionError = "Inspecting disk0; no storage changes have started."
    private var pending: [UUID: (ResizePlan, GPTImage)] = [:]
    private var executing = false
    private var sampling = false
    private var inheritedOperation = false
    /// A snapshot removal or creation is in progress; no plan or start meanwhile.
    private var snapshotting = false
    /// The system snapshot's last scanned state. The on-disk scan is expensive,
    /// so refresh repeats it at most once a minute; other inspections keep it.
    private var systemSnapshot: SystemSnapshot?
    private var snapshotScannedAt: Date?

    public init(source: DeviceSource, directory: URL, executable: String) throws {
        self.source = source; self.directory = directory; self.executable = executable
        let state = directory.appendingPathComponent("operation.json")
        if FileManager.default.fileExists(atPath: state.path) {
            record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: state))
            if record?.operation.status == .running {
                record?.operation.status = .unknown
                record?.operation.workerPID = nil
                record?.operation.message = "The supervising helper restarted. A prior worker may still be running. No resize or partition write has been retried."
                inheritedOperation = true
                try DeviceJournal.write(record!, to: state)
            }
        }
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    public func refresh() {
        let flags: (minimum: Bool, snapshots: Bool)? = sync {
            guard !sampling else { return nil }
            sampling = true
            let idle = record?.operation.status != .running && !snapshotting
            let due = snapshotScannedAt.map { Date().timeIntervalSince($0) >= 60 } ?? true
            return (record?.operation.status != .running, idle && due)
        }
        guard let flags else { return }
        let source = source
        let result: Result<DeviceInspection, Error>
        do {
            var latest = try DeviceInspector.inspect(source, queryMinimum: flags.minimum)
            if flags.snapshots { latest.layout.systemSnapshot = SystemSnapshots.inspect(source, latest) }
            result = .success(latest)
        } catch { result = .failure(error) }
        sync {
            switch result {
            case .success(let latest):
                if flags.snapshots { systemSnapshot = latest.layout.systemSnapshot; snapshotScannedAt = Date() }
                accept(latest)
                if record?.operation.status == .completed, let plan = record?.operation.plan,
                   (latest.layout.diskID != plan.after.diskID || latest.layout.containerID != plan.after.containerID ||
                    latest.layout.containerBytes != plan.targetBytes || latest.layout.backingBytes != plan.targetBytes ||
                    !Self.samePartitions(latest.layout.partitions, plan.after.partitions)) {
                    record?.operation.status = .stopped
                    record?.operation.message = "The previous operation completed, but the storage layout has changed since then. Current metadata were inspected; no previous operation was repeated."
                    try? persist()
                }
                if inheritedOperation, var saved = record {
                    let result = saved.workerJob.flatMap { try? Data(contentsOf: DeviceWorker.resultURL(for: $0)) }
                        .flatMap { try? JSONDecoder().decode(WorkerResult.self, from: $0) }
                    let job = saved.workerJob.flatMap { try? Data(contentsOf: $0) }
                        .flatMap { try? JSONDecoder().decode(DeviceJob.self, from: $0) }
                    let returned = result != nil && result?.jobID == job?.id
                    let differentBoot = saved.bootIdentity != Self.bootIdentity()
                    if (returned && result?.outcome != .unknown) || differentBoot {
                        saved.operation.status = .stopped
                        saved.operation.workerPID = nil
                        saved.operation.message = differentBoot
                            ? "The device restarted after the previous operation. Current APFS and GPT metadata were inspected. Review a new plan; no old operation was repeated."
                            : "The previous worker returned after the helper restarted. Current metadata were inspected, but remaining stages were not run. Review any further changes."
                        record = saved; inheritedOperation = false
                        try? persist()
                    }
                }
            case .failure(let error): inspectionError = error.localizedDescription
            }
            sampling = false
        }
    }

    public func snapshot() throws -> ServiceSnapshot {
        try sync { try currentSnapshot() }
    }

    public func plan(_ request: PlanRequest) throws -> ResizePlan {
        try sync {
            try ensureIdle()
            guard source.writesEnabled else { throw ResizeError("This overlay permits inspection only. Use a write-enabled overlay to resize storage.") }
        }
        let source = source
        let fresh = try DeviceInspector.inspect(source)
        return try sync {
            try ensureIdle()
            let plan = try Planner.make(request, on: fresh.layout)
            // Validate that the intended slot and every raw entry are supported before
            // offering a review, not only after the long APFS resize has finished.
            let addition = plan.after.partitions.first { candidate in !fresh.layout.partitions.contains(where: { $0.id == candidate.id }) }
            _ = try fresh.gpt.changingEnd(partitionID: fresh.layout.backingPartitionID,
                                         to: plan.after.apfs.lastLBA, adding: addition)
            if pending.count >= 16 { pending.removeAll() }
            pending[plan.id] = (plan, fresh.gpt)
            accept(fresh)
            return plan
        }
    }

    public func start(_ request: StartRequest) throws -> ServiceSnapshot {
        try sync {
            if record?.operation.requestID == request.requestID { return try currentSnapshot() }
            try ensureIdle()
            guard source.writesEnabled, let (plan, _) = pending[request.planID],
                  plan.before.revision == inspection?.layout.revision else {
                throw ResizeError("The reviewed plan expired or storage changed. No mutation was started.")
            }
            let now = Date()
            let operation = ResizeCore.Operation(id: UUID(), requestID: request.requestID, plan: plan, status: .running,
                                                  stepIndex: 0, completedSteps: [], startedAt: now, stepStartedAt: now,
                                                  lastConfirmedAt: nil, observedCapacityBytes: inspection?.layout.containerBytes,
                                                  observedAt: inspection?.observedAt, workerPID: nil, message: nil)
            record = Record(operation: operation, workerJob: nil, bootIdentity: Self.bootIdentity())
            // Persist authorization and the exact original GPT before any worker exists.
            do {
                try DeviceJournal.write(inspection!.gpt, to: directory.appendingPathComponent("backups/\(operation.id.uuidString).gpt.json"))
                try persist()
            } catch {
                record?.operation.status = .stopped
                record?.operation.message = "The authorization record could not be saved. No worker was started: " + error.localizedDescription
                try? persist()
                throw error
            }
            pending.removeAll()
            executing = true
            // The operation runs on its own thread; it waits for this lock, so it
            // starts once the accepted snapshot below has been taken.
            Thread { [self] in perform() }.start()
            return try currentSnapshot()
        }
    }

    public func removeSnapshot(_ request: SnapshotRequest) throws -> ServiceSnapshot { try changeSnapshot(request, remove: true) }
    public func takeSnapshot(_ request: SnapshotRequest) throws -> ServiceSnapshot { try changeSnapshot(request, remove: false) }

    /// Removes or creates the system snapshot, as its own mutation: refused while
    /// an operation runs, for a stale view, or when a fresh check of the mounted
    /// list and the on-disk metadata disagrees with the request. Afterwards the
    /// disk is inspected again, so iOS's minimum query reports the new limit.
    private func changeSnapshot(_ request: SnapshotRequest, remove: Bool) throws -> ServiceSnapshot {
        try sync {
            try ensureIdle()
            guard source.writesEnabled, !source.isFixture else { throw ResizeError("This helper permits inspection only. The snapshot was not changed.") }
            guard SystemSnapshots.applicable else { throw ResizeError("This iOS version has no snapshot to manage here.") }
            snapshotting = true
        }
        defer { sync { snapshotting = false } }
        let source = source
        var fresh = try DeviceInspector.inspect(source)
        fresh.layout.systemSnapshot = SystemSnapshots.inspect(source, fresh)
        guard fresh.layout.revision == request.revision else { throw ResizeError("Storage changed. Inspect it again; the snapshot was not changed.") }
        guard let system = fresh.layout.systemSnapshot, system.name == request.name else {
            throw ResizeError("The snapshot \(request.name) could not be checked. It was not changed.")
        }
        let status: Int32
        if remove {
            guard system.present else { throw ResizeError("There is no snapshot \(system.name) to remove.") }
            guard system.removable else {
                throw ResizeError("iOS boots from or would revert to \(system.name), or its metadata could not be confirmed. It was not removed.")
            }
            status = raf_delete_snapshot(SystemSnapshots.mount, system.name)
        } else {
            guard !system.present else { throw ResizeError("A snapshot \(system.name) already exists.") }
            status = raf_create_snapshot(SystemSnapshots.mount, system.name)
        }
        guard status == 0 else {
            throw ResizeError("\(remove ? "Removing" : "Taking") the snapshot \(system.name) failed: \(String(cString: strerror(status))). Nothing else was changed.")
        }
        var after = try DeviceInspector.inspect(source)
        after.layout.systemSnapshot = SystemSnapshots.inspect(source, after)
        return try sync {
            systemSnapshot = after.layout.systemSnapshot; snapshotScannedAt = Date()
            accept(after)
            return try currentSnapshot()
        }
    }

    /// True while an operation this journal started is running, or its worker
    /// process is still alive. Used by `--operation-active`, which runs while
    /// the session helper holds the journal lock, so it reads the journal file.
    public static func operationActive(directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("operation.json")),
              let saved = try? JSONDecoder().decode(Record.self, from: data) else { return false }
        if saved.operation.status == .running { return true }
        if let pid = saved.operation.workerPID, pid > 0, kill(pid, 0) == 0 || errno == EPERM { return true }
        return false
    }

    private func perform() {
        defer { sync { executing = false } }
        do {
            while true {
                let next: (Record, OperationStep)? = sync {
                    guard let saved = record, saved.operation.status == .running, let step = saved.operation.currentStep else { return nil }
                    return (saved, step)
                }
                guard let (saved, step) = next else { break }
                let source = source
                let before = try DeviceInspector.inspect(source, queryMinimum: step == .checking || step.isResize)
                let plan = saved.operation.plan
                if [.expandPartition, .shrinkPartition, .shrinkAPFS, .growAPFS, .createLinux].contains(step) {
                    try sync {
                        guard let current = record, current.operation.id == saved.operation.id else { throw ResizeError("Operation ownership changed.") }
                        accept(before)
                    }
                    let job = DeviceJob(source: source, step: step, plan: plan, expectedGPT: before.gpt,
                                        expectedContainerBytes: before.layout.containerBytes)
                    let result = try run(job)
                    if result.outcome != .success {
                        stopAfterWorker(result)
                        return
                    }
                    let after = try DeviceInspector.inspect(source, queryMinimum: false)
                    try sync {
                        if step.isResize {
                            guard after.layout.containerBytes == plan.targetBytes, after.gpt == before.gpt else {
                                throw ResizeError("The resize call returned, but independent APFS/GPT readback did not match the plan.")
                            }
                        } else {
                            let addition = step == .createLinux ? plan.after.partitions.first { candidate in !before.layout.partitions.contains(where: { $0.id == candidate.id }) } : nil
                            let expected = try before.gpt.changingEnd(partitionID: before.layout.backingPartitionID,
                                                                     to: step == .createLinux ? before.layout.apfs.lastLBA : plan.after.apfs.lastLBA,
                                                                     adding: addition,
                                                                     removing: step == plan.removalStep ? plan.request.replacing : [])
                            guard after.gpt == expected else { throw ResizeError("The GPT worker returned, but independent readback did not match.") }
                        }
                        accept(after)
                        try completeStep(step)
                    }
                } else {
                    try sync {
                        guard let current = record, current.operation.id == saved.operation.id else { throw ResizeError("Operation ownership changed.") }
                        accept(before)
                        if step == .checking {
                            guard before.layout.revision == plan.before.revision,
                                  before.layout.diskID == plan.before.diskID,
                                  before.layout.containerID == plan.before.containerID else {
                                throw ResizeError("Storage changed after authorization. No worker was started.")
                            }
                            _ = try Planner.make(plan.request, on: before.layout)
                        } else if step == .verifyAPFS {
                            guard before.layout.containerBytes == plan.targetBytes else { throw ResizeError("APFS capacity did not match the approved target.") }
                        } else if step == .verifyPartition {
                            guard before.layout.backingBytes == plan.targetBytes else { throw ResizeError("The backing-partition update could not be verified.") }
                        } else if step == .verifyLayout {
                            let originalGPT = try tryOriginalGPT(saved.operation.id)
                            guard before.layout.containerBytes == plan.targetBytes, before.layout.backingBytes == plan.targetBytes,
                                  Self.samePartitions(before.layout.partitions, plan.after.partitions),
                                  before.gpt.mbr == originalGPT.mbr else {
                                throw ResizeError("The final layout does not match the approved plan.")
                            }
                        }
                        try completeStep(step)
                    }
                }
            }
            let source = source
            let final = try DeviceInspector.inspect(source)
            try sync {
                snapshotScannedAt = nil
                accept(final)
                record?.operation.status = .completed
                record?.operation.message = "All requested storage changes were completed and verified from APFS and both GPT copies. This is not a full filesystem-integrity check."
                try persist()
            }
        } catch {
            sync {
                record?.operation.status = .unknown
                record?.operation.workerPID = nil
                record?.operation.message = error.localizedDescription + " No remaining stage was attempted."
                try? persist()
            }
        }
    }

    /// Caller holds the lock.
    private func completeStep(_ step: OperationStep) throws {
        record?.operation.completedSteps.append(step)
        record?.operation.stepIndex += 1
        record?.operation.stepStartedAt = Date()
        record?.operation.workerPID = nil
        record?.workerJob = nil
        try persist()
    }

    private func run(_ job: DeviceJob) throws -> WorkerResult {
        let url = directory.appendingPathComponent("jobs/\(job.id.uuidString).job.json")
        enum Launch { case released(pid_t), refused(Int32) }
        let launch: Launch = try sync {
            try DeviceJournal.write(job, to: url)
            record?.workerJob = url
            try persist()
            var pid: pid_t = 0, releaseFD: Int32 = -1
            let status = raf_spawn_worker(executable, url.path, &pid, &releaseFD)
            guard status == 0 else { return .refused(status) }
            // Closing the gate unreleased makes the waiting child exit without mutating.
            defer { close(releaseFD) }
            record?.operation.workerPID = pid
            record?.operation.lastConfirmedAt = Date()
            // The child is waiting on a pipe. Finish disk-backed journal writes
            // before releasing it into Apple's potentially filesystem-freezing call.
            try persist()
            guard raf_release_worker(releaseFD) == 0 else { throw ResizeError("Could not release the prepared worker.") }
            return .released(pid)
        }
        let pid: pid_t
        switch launch {
        case .refused(let status):
            return WorkerResult(jobID: job.id, outcome: .refused, message: "Could not start the worker: \(String(cString: strerror(status))).")
        case .released(let spawned): pid = spawned
        }
        while true {
            let finished: WorkerResult? = sync {
                var exitStatus: Int32 = 0
                let state = raf_poll_worker(pid, &exitStatus)
                if state != 0 {
                    record?.operation.workerPID = nil
                    guard state == 1, exitStatus == 0,
                          let data = try? Data(contentsOf: DeviceWorker.resultURL(for: url)),
                          let result = try? JSONDecoder().decode(WorkerResult.self, from: data), result.jobID == job.id else {
                        return WorkerResult(jobID: job.id, outcome: .unknown,
                                            message: "The worker exited without a valid completion record. Its operation may have changed storage.")
                    }
                    return result
                }
                // A real waitpid observation of our own live child, not a UI timer.
                record?.operation.lastConfirmedAt = Date()
                return nil
            }
            if let finished { return finished }
            usleep(500_000)
        }
    }

    private func stopAfterWorker(_ result: WorkerResult) {
        sync {
            snapshotScannedAt = nil
            record?.operation.workerPID = nil
            record?.operation.message = result.message
        }
        let source = source
        do {
            let observed = try DeviceInspector.inspect(source)
            sync {
                accept(observed)
                record?.operation.status = result.outcome == .unknown ? .unknown : .stopped
                try? persist()
            }
        } catch {
            sync {
                record?.operation.status = .unknown
                record?.operation.message = result.message + " Current metadata could not be verified: " + error.localizedDescription
                try? persist()
            }
        }
    }
    // The helpers below are called with the lock held.
    private func currentSnapshot() throws -> ServiceSnapshot {
        guard let inspection else { throw ResizeError(inspectionError) }
        return ServiceSnapshot(mode: source.isFixture ? "fixture" : "device", layout: inspection.layout,
                               operation: record?.operation)
    }
    private func accept(_ latest: DeviceInspection) {
        guard inspection == nil || latest.observedAt >= inspection!.observedAt else { return }
        inspection = latest
        if inspection?.layout.systemSnapshot == nil { inspection?.layout.systemSnapshot = systemSnapshot }
        record?.operation.observedCapacityBytes = latest.layout.containerBytes
        record?.operation.observedAt = latest.observedAt
    }
    private func ensureIdle() throws {
        guard !executing, !snapshotting, record?.operation.status != .running, record?.operation.status != .unknown else {
            throw ResizeError("An operation is active or its outcome is unknown. No new mutation is allowed.")
        }
    }
    private func persist() throws {
        if let record { try DeviceJournal.write(record, to: directory.appendingPathComponent("operation.json")) }
    }
    private func tryOriginalGPT(_ id: UUID) throws -> GPTImage {
        try JSONDecoder().decode(GPTImage.self, from: Data(contentsOf: directory.appendingPathComponent("backups/\(id.uuidString).gpt.json")))
    }
    private static func samePartitions(_ lhs: [Partition], _ rhs: [Partition]) -> Bool {
        lhs.count == rhs.count && lhs.allSatisfy { p in rhs.contains { q in
            p.id == q.id && p.name == q.name && p.firstLBA == q.firstLBA && p.lastLBA == q.lastLBA && p.typeGUID == q.typeGUID
        } }
    }
    private static func bootIdentity() -> String {
        var time = timeval(), length = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &length, nil, 0) == 0 else { return "unknown-boot" }
        return "\(time.tv_sec):\(time.tv_usec)"
    }
}
