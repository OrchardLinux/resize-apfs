import Foundation

public extension Operation {
    /// Every planned step completed and was verified (the last step is always
    /// the layout verification), whatever status an older helper recorded.
    var finished: Bool {
        stepIndex >= plan.steps.count && plan.steps.allSatisfy { completedSteps.contains($0) }
    }
}

public extension ResizePlan {
    /// True when `layout` is the layout this plan produces: same disk and
    /// container, the approved size, and the planned partitions.
    func produced(_ layout: StorageLayout) -> Bool {
        layout.diskID == after.diskID && layout.containerID == after.containerID &&
            layout.containerBytes == targetBytes && layout.backingBytes == targetBytes &&
            Partition.same(layout.partitions, after.partitions)
    }
}

public extension Partition {
    /// The same entries in any order, compared by what the GPT holds.
    static func same(_ lhs: [Partition], _ rhs: [Partition]) -> Bool {
        lhs.count == rhs.count && lhs.allSatisfy { p in rhs.contains { q in
            p.id == q.id && p.name == q.name && p.firstLBA == q.firstLBA && p.lastLBA == q.lastLBA && p.typeGUID == q.typeGUID
        } }
    }
}

/// A completed and verified operation is history: it is never an error, also
/// not after the layout changed later (Linux partitions added, another tool).
/// Only an unfinished operation is reported as stopped or unknown.
public enum OperationHistory {
    public static let completedMessage = "All requested storage changes were completed and verified from APFS and both GPT copies. This is not a full filesystem-integrity check."

    /// Undoes what helpers before this change wrote when the layout changed
    /// after a completed operation: status `stopped` on a finished operation.
    public static func restoringCompletion(_ operation: Operation) -> Operation {
        guard operation.status == .stopped, operation.finished else { return operation }
        var restored = operation
        restored.status = .completed
        restored.workerPID = nil
        restored.message = completedMessage
        return restored
    }

    /// The operation the service reports with `layout`: a completed operation
    /// only while the layout is still the one it produced, so the app shows its
    /// result once; afterwards it is history and the app starts at the overview.
    /// Every other operation is reported as it is.
    public static func reported(_ operation: Operation?, on layout: StorageLayout) -> Operation? {
        guard let operation else { return nil }
        if operation.status == .completed && !operation.plan.produced(layout) { return nil }
        return operation
    }
}
