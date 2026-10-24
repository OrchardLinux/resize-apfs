import SwiftUI
import ResizeCore

enum Palette {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color.primary
    static let muted = Color.secondary
    static let blue = Color(red: 0.20, green: 0.36, blue: 0.91)
    static let green = Color(red: 0.20, green: 0.50, blue: 0.40)
    static let destructive = Color(red: 0.72, green: 0.26, blue: 0.21)
    static let linux = Color(red: 0.42, green: 0.34, blue: 0.72)
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct ValueRow: View {
    var title: String
    var value: String
    var emphasized = false
    var valueIdentifier: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(emphasized ? .semibold : .regular)
                .multilineTextAlignment(.trailing).monospacedDigit()
                .accessibilityIdentifier(valueIdentifier ?? "\(title)Value")
        }.font(.subheadline)
    }
}

struct ActionButton: View {
    var title: String
    var identifier: String
    var destructive = false
    var disabled = false
    var busy = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy { ProgressView().tint(.white) }
                Text(title).fontWeight(.semibold)
                if !busy { Image(systemName: "arrow.right") }
            }.frame(maxWidth: .infinity).frame(minHeight: 54)
                .foregroundStyle(disabled ? Color.secondary : .white)
                .background(disabled ? Color.secondary.opacity(0.13) : (destructive ? Palette.destructive : Palette.blue),
                            in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || busy)
        .accessibilityIdentifier(identifier)
    }
}

struct ResizeWarning: View {
    var beforeApplying = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(beforeApplying ? "Before you apply" : "Keep power connected",
                  systemImage: beforeApplying ? "exclamationmark.triangle" : "powerplug")
                .font(.headline)
            if beforeApplying { Text("Resizing can cause data loss. Back up your data before continuing.") }
            Text("The device may freeze, respond again, or appear idle while work continues. This does not mean resizing has finished or failed.")
            Text("Do not restart the device or start another resize. Wait until Resize APFS verifies completion.")
        }
        .font(.subheadline).foregroundStyle(Color(red: 0.48, green: 0.30, blue: 0.10))
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.99, green: 0.95, blue: 0.87), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct StorageMap: View {
    var layout: StorageLayout
    var editableTarget: Binding<Double>?
    private struct Segment: Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        let color: Color
    }
    private var segments: [Segment] {
        var result: [Segment] = []
        var cursor = layout.firstUsableLBA
        for part in layout.partitions.sorted(by: { $0.firstLBA < $1.firstLBA }) {
            if part.firstLBA > cursor {
                result.append(Segment(id: "free-\(cursor)", label: "Unallocated", bytes: (part.firstLBA - cursor) * layout.sectorSize, color: .gray.opacity(0.16)))
            }
            result.append(Segment(id: part.id.uuidString, label: part.kind == .apfs ? "APFS" : part.name,
                                  bytes: part.blocks * layout.sectorSize,
                                  color: part.kind == .apfs ? Palette.blue : part.kind == .linux ? Palette.linux : .gray.opacity(0.4)))
            cursor = part.lastLBA + 1
        }
        if cursor <= layout.lastUsableLBA {
            result.append(Segment(id: "free-\(cursor)", label: "Unallocated", bytes: (layout.lastUsableLBA - cursor + 1) * layout.sectorSize, color: .gray.opacity(0.16)))
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Canvas { context, size in
                guard size.width.isFinite, size.width > 0 else { return }
                let items = segments
                let total = Double(max(1, items.reduce(0) { $0 + $1.bytes }))
                let usableWidth = max(0, size.width - CGFloat(max(0, items.count - 1)) * 2)
                var x: CGFloat = 0
                for segment in items {
                    let width = usableWidth * CGFloat(Double(segment.bytes) / total)
                    let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                    context.fill(Path(rect), with: .color(segment.color))
                    if width > 85 {
                        let foreground: Color = segment.label == "Unallocated" ? .secondary : .white
                        var labelContext = context
                        labelContext.clip(to: Path(rect.insetBy(dx: 8, dy: 0)))
                        labelContext.draw(Text(segment.label).font(.subheadline.weight(.semibold)).foregroundColor(foreground),
                                          at: CGPoint(x: x + 14, y: 20), anchor: .topLeading)
                        labelContext.draw(Text(Capacity.gb(segment.bytes)).font(.caption.monospacedDigit()).foregroundColor(foreground),
                                          at: CGPoint(x: x + 14, y: 44), anchor: .topLeading)
                    }
                    x += width + 2
                }
            }.frame(height: 78).clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(segments.map { "\($0.label), \(Capacity.gb($0.bytes))" }.joined(separator: "; "))
            if let editableTarget {
                Slider(value: editableTarget,
                       in: Double(layout.minimumContainerBytes ?? layout.containerBytes) / 1e9...Double(layout.maximumBytes) / 1e9,
                       step: 0.1)
                    .tint(Palette.blue)
                    .accessibilityLabel("APFS size in gigabytes")
                    .accessibilityIdentifier("sizeSlider")
            }
            HStack(spacing: 16) {
                legend("APFS", color: Palette.blue)
                if layout.partitions.contains(where: { $0.kind == .other }) { legend("Other", color: .gray.opacity(0.4)) }
                if layout.partitions.contains(where: { $0.kind == .linux }) { legend("Linux", color: Palette.linux) }
                if layout.allUnallocatedBytes > 0 { legend("Unallocated", color: .gray.opacity(0.3)) }
            }.font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .contain)
    }
    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9); Text(text) }
    }
}

struct SizeField: View {
    var title: String
    var identifier: String
    var text: Binding<String>
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                TextField("0", text: text).keyboardType(.decimalPad)
                    .font(.title2.weight(.medium)).monospacedDigit()
                    .accessibilityLabel(title).accessibilityIdentifier(identifier)
                if !text.wrappedValue.isEmpty {
                    Button { text.wrappedValue = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain).accessibilityLabel("Clear \(title)")
                        .accessibilityIdentifier(identifier + "Clear")
                }
                Text("GB").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(14).background(Palette.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.blue.opacity(0.5), lineWidth: 1))
        }
    }
}
