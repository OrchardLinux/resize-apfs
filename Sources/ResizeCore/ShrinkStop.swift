import Foundation

/// How far a stepwise shrink is, from what was observed: only the container's
/// size after verified steps counts, never time or the step count.
public struct ShrinkProgress: Equatable, Sendable {
    public var releasedBytes: Int64
    /// What the running step will release.
    public var stepBytes: Int64
    public var totalBytes: Int64
    /// Rounded down, so it reads 100 only once everything is released.
    public var percent: Int { totalBytes > 0 ? Int(releasedBytes * 100 / totalBytes) : 0 }
}

public extension Operation {
    /// The running step ends at the approved size; stopping after it changes nothing.
    var onLastShrinkStep: Bool { currentStep == .shrinkAPFS && apfsStep?.targetBytes == plan.targetBytes }

    /// A shrink runs in steps and can end between two of them, never inside one:
    /// the APFS call of a step cannot be interrupted.
    var canStop: Bool {
        status == .running && currentStep == .shrinkAPFS && !onLastShrinkStep && stopRequested != true
    }

    var shrinkProgress: ShrinkProgress? {
        guard currentStep == .shrinkAPFS else { return nil }
        let before = plan.before.containerBytes, total = before - plan.targetBytes
        guard total > 0 else { return nil }
        let current = min(before, max(plan.targetBytes, observedCapacityBytes ?? before))
        let next = apfsStep.map { min(current, max(plan.targetBytes, $0.targetBytes)) } ?? current
        return ShrinkProgress(releasedBytes: before - current, stepBytes: current - next, totalBytes: total)
    }

    /// Ends the operation between two steps, on `layout` as inspected after the
    /// last of `steps` completed ones.
    mutating func endStopped(on layout: StorageLayout, steps: Int) {
        status = .stopped
        stoppedByUser = true
        workerPID = nil
        guard steps > 0 else {
            message = "Resizing stopped before the first step. APFS keeps its \(Capacity.gb(layout.containerBytes))."
            return
        }
        message = "APFS is now \(Capacity.gb(layout.containerBytes)), after \(steps) \(steps == 1 ? "step" : "steps"). Its partition remains \(Capacity.gb(layout.backingBytes)), so the space after APFS (\(Capacity.gb(layout.backingBytes - layout.containerBytes))) is not free for anything else yet."
    }
}
