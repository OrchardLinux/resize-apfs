import Foundation

// `Identifiable` exists from iOS 13 / macOS 10.15. The types keep their `id`
// on iOS 12; only the protocol conformance waits for the OS that has it.
@available(iOS 13, macOS 10.15, *)
extension Partition: Identifiable {}
@available(iOS 13, macOS 10.15, *)
extension ResizePlan: Identifiable {}
@available(iOS 13, macOS 10.15, *)
extension Operation: Identifiable {}
@available(iOS 13, macOS 10.15, *)
extension MockScenario: Identifiable {}
