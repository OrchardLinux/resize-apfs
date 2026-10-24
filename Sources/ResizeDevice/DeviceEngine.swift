import Foundation
import Darwin
import ResizeCore
import NativeSystem

public actor DeviceEngine {
    private struct Record: Codable {
        var operation: ResizeCore.Operation
        var workerJob: URL?
        var bootIdentity: String
    }
    private let source: DeviceSource
    private let directory: URL
    private let executable: String
    private var record: Record?
    private var inspection: DeviceInspection?
    private var inspectionError = "Inspecting disk0; no storage changes have started."
    private var pending: [UUID: (ResizePlan, GPTImage)] = [:]
    private var executing = false
    private var sampling = false
    private var inheritedOperation = false

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

    public func refresh() async {
        guard !sampling else { return }
        sampling = true
        let includeMinimum = record?.operation.status != .running
        let source = source
        let result: Result<DeviceInspection, Error>
        do { result = .success(try await DeviceInspector.inspectAsync(source, queryMinimum: includeMinimum)) }
        catch { result = .failure(error) }
        switch result {
        case .success(let latest):
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

    public func snapshot() throws -> ServiceSnapshot {
        guard let inspection else { throw ResizeError(inspectionError) }
        return ServiceSnapshot(mode: source.isFixture ? "fixture" : "device", layout: inspection.layout,
                               operation: record?.operation)
    }

    public func plan(_ request: PlanRequest) async throws -> ResizePlan {
        try ensureIdle()
        guard source.writesEnabled else { throw ResizeError("This overlay permits inspection only. Use a write-enabled overlay to resize storage.") }
        let source = source
        let fresh = try await DeviceInspector.inspectAsync(source)
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

    public func start(_ request: StartRequest) throws -> ServiceSnapshot {
        if record?.operation.requestID == request.requestID { return try snapshot() }
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
        Task { await self.perform() }
        return try snapshot()
    }

    private func perform() async {
        defer { executing = false }
        do {
            while let saved = record, saved.operation.status == .running, let step = saved.operation.currentStep {
                let source = source
                let before = try await DeviceInspector.inspectAsync(source, queryMinimum: step == .checking || step.isResize)
                guard let current = record, current.operation.id == saved.operation.id else { throw ResizeError("Operation ownership changed.") }
                accept(before)
                let plan = saved.operation.plan
                if step == .checking {
                    guard before.layout.revision == plan.before.revision,
                          before.layout.diskID == plan.before.diskID,
                          before.layout.containerID == plan.before.containerID else {
                        throw ResizeError("Storage changed after authorization. No worker was started.")
                    }
                    _ = try Planner.make(plan.request, on: before.layout)
                } else if [.expandPartition, .shrinkPartition, .shrinkAPFS, .growAPFS, .createLinux].contains(step) {
                    let job = DeviceJob(source: source, step: step, plan: plan, expectedGPT: before.gpt,
                                        expectedContainerBytes: before.layout.containerBytes)
                    let result = try await run(job)
                    if result.outcome != .success {
                        await stopAfterWorker(result)
                        return
                    }
                    let after = try await DeviceInspector.inspectAsync(source, queryMinimum: false)
                    if step.isResize {
                        guard after.layout.containerBytes == plan.targetBytes, after.gpt == before.gpt else {
                            throw ResizeError("The resize call returned, but independent APFS/GPT readback did not match the plan.")
                        }
                    } else {
                        let addition = step == .createLinux ? plan.after.partitions.first { candidate in !before.layout.partitions.contains(where: { $0.id == candidate.id }) } : nil
                        let expected = try before.gpt.changingEnd(partitionID: before.layout.backingPartitionID,
                                                                 to: step == .createLinux ? before.layout.apfs.lastLBA : plan.after.apfs.lastLBA,
                                                                 adding: addition)
                        guard after.gpt == expected else { throw ResizeError("The GPT worker returned, but independent readback did not match.") }
                    }
                    accept(after)
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
                record?.operation.completedSteps.append(step)
                record?.operation.stepIndex += 1
                record?.operation.stepStartedAt = Date()
                record?.operation.workerPID = nil
                record?.workerJob = nil
                try persist()
            }
            let source = source
            let final = try await DeviceInspector.inspectAsync(source)
            accept(final)
            record?.operation.status = .completed
            record?.operation.message = "All requested storage changes were completed and verified from APFS and both GPT copies. This is not a full filesystem-integrity check."
            try persist()
        } catch {
            record?.operation.status = .unknown
            record?.operation.workerPID = nil
            record?.operation.message = error.localizedDescription + " No remaining stage was attempted."
            try? persist()
        }
    }

    private func run(_ job: DeviceJob) async throws -> WorkerResult {
        let url = directory.appendingPathComponent("jobs/\(job.id.uuidString).job.json")
        try DeviceJournal.write(job, to: url)
        record?.workerJob = url
        try persist()
        var pid: pid_t = 0, releaseFD: Int32 = -1
        let status = raf_spawn_worker(executable, url.path, &pid, &releaseFD)
        guard status == 0 else { return WorkerResult(jobID: job.id, outcome: .refused, message: "Could not start the worker: \(String(cString: strerror(status))).") }
        defer { if releaseFD >= 0 { close(releaseFD) } }
        record?.operation.workerPID = pid
        record?.operation.lastConfirmedAt = Date()
        // The child is waiting on a pipe. Finish disk-backed journal writes
        // before releasing it into Apple's potentially filesystem-freezing call.
        try persist()
        guard raf_release_worker(releaseFD) == 0 else { throw ResizeError("Could not release the prepared worker.") }
        close(releaseFD); releaseFD = -1
        while true {
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
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func stopAfterWorker(_ result: WorkerResult) async {
        record?.operation.workerPID = nil
        record?.operation.message = result.message
        let source = source
        do {
            let observed = try await DeviceInspector.inspectAsync(source)
            accept(observed)
            record?.operation.status = result.outcome == .unknown ? .unknown : .stopped
        } catch {
            record?.operation.status = .unknown
            record?.operation.message = result.message + " Current metadata could not be verified: " + error.localizedDescription
        }
        try? persist()
    }
    private func accept(_ latest: DeviceInspection) {
        guard inspection == nil || latest.observedAt >= inspection!.observedAt else { return }
        inspection = latest
        record?.operation.observedCapacityBytes = latest.layout.containerBytes
        record?.operation.observedAt = latest.observedAt
    }
    private func ensureIdle() throws {
        guard !executing, record?.operation.status != .running, record?.operation.status != .unknown else {
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
