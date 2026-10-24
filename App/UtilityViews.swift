import SwiftUI
import ResizeCore

struct MockLabView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: MockScenario = .normal
    @State private var scale = 1.0
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Synthetic storage only", systemImage: "flask").font(.headline)
                    Text("This service is a separate Mac process. Closing the app does not stop its operation. No disks, APFS APIs or partition tools are accessed.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Scenario") {
                    Picker("Behavior", selection: $selected) {
                        ForEach(MockScenario.allCases) { scenario in Text(scenario.title).tag(scenario) }
                    }.pickerStyle(.inline).accessibilityIdentifier("scenarioPicker")
                }
                Section("Timing") {
                    Picker("Speed", selection: $scale) {
                        Text("Fast · a few seconds").tag(0.15)
                        Text("Normal · about 20 seconds").tag(1.0)
                        Text("Slow · minutes").tag(10.0)
                    }
                    Text("Timing is deliberately synthetic. Capacity does not animate toward the target.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Load scenario", role: .destructive) { confirmReset = true }
                        .disabled(model.busy).accessibilityIdentifier("loadScenario")
                    Text("Resets the mock layout and discards any simulated operation. It never affects real storage.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Mock service")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
            .confirmationDialog("Discard the current simulation?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Load mock scenario", role: .destructive) { Task { await model.configure(selected, scale: scale) } }
            }
            .onAppear { selected = model.snapshot?.scenario ?? .normal }
        }
    }
}

struct TechnicalView: View {
    var layout: StorageLayout
    var isMock = true
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Disk") {
                    row("Name", layout.diskName)
                    row("Disk GUID", layout.diskID.uuidString)
                    row("Sector size", "\(layout.sectorSize) bytes")
                    row("Total size", "\(layout.totalBytes) bytes")
                    row("Usable LBAs", "\(layout.firstUsableLBA)…\(layout.lastUsableLBA) (inclusive)")
                }
                Section("APFS container") {
                    row("Container UUID", layout.containerID.uuidString)
                    row("Capacity", "\(layout.containerBytes) bytes")
                    row("Backing capacity", "\(layout.backingBytes) bytes")
                    row("Minimum APFS size", layout.minimumContainerBytes.map { "\($0) bytes" + (isMock ? " (mock fixture)" : " (APFS API)") } ?? "Unavailable")
                }
                ForEach(layout.partitions) { partition in
                    Section(partition.name) {
                        row("Device", partition.bsdName)
                        row("Unique GUID", partition.id.uuidString)
                        row("Type GUID", partition.typeGUID)
                        row("First LBA", "\(partition.firstLBA)")
                        row("Last LBA", "\(partition.lastLBA) (inclusive)")
                        row("Capacity", "\(partition.blocks * layout.sectorSize) bytes")
                        row("Contents", partition.contents)
                    }
                }
                Section { Text(isMock ? "Simulated metadata. This is not a partition-table or data backup." : "Read-only metadata inspection. The helper retains an original GPT copy before authorized mutations; that is not a backup of your files.").foregroundStyle(.secondary) }
            }
            .navigationTitle("Technical details")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
        }.padding(.vertical, 3)
    }
}
