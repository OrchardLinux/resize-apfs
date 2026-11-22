import UIKit
import ResizeCore

/// Adjust size. Updated in place: the fields keep the cursor and the bar keeps
/// its drag gesture while the model recomputes the plan on every change.
final class EditorPage: UIStackView {
    private let model: AppModel
    private let m: Metrics
    private let target: SizeField
    private let free: SizeField
    private let bar: PartitionBar
    private let dynamic = UIStackView()
    private let messageSlot = UIStackView()
    private let freeCaption: UILabel

    init(model: AppModel, metrics: Metrics, toolbar: UIToolbar) {
        self.model = model; m = metrics
        let layout = model.layout!
        target = SizeField(metrics, title: "New APFS size", identifier: "targetSize", text: model.targetText, error: false) { [model] in model.setTarget($0) }
        free = SizeField(metrics, title: "Free space after", identifier: "freeAfter", text: model.freeText, error: false) { [model] in model.setFree($0) }
        target.field.inputAccessoryView = toolbar
        free.field.inputAccessoryView = toolbar
        bar = PartitionBar(metrics, layout: model.localPlan?.after ?? layout, labels: true, boundary: nil)
        freeCaption = label("", Theme.font(metrics.caption), Theme.muted)
        super.init(frame: .zero)
        axis = .vertical; spacing = metrics.sectionGap

        let titleLabel = label("Adjust size", Theme.font(m.title, .semibold, .largeTitle))
        titleLabel.accessibilityTraits = .header
        addArrangedSubview(stack(.vertical, 5, [titleLabel, label("APFS container · \(layout.apfs.bsdName)", Theme.font(m.description), Theme.muted)]))

        let fields = stack(.horizontal, m.regular ? 24 : 12, [target, free], align: .top)
        fields.distribution = .fillEqually
        let use = UIButton(type: .system)
        use.setTitle("Use available space", for: .normal)
        use.titleLabel?.font = Theme.font(m.caption, .semibold)
        use.tintColor = Theme.blue
        use.contentHorizontalAlignment = .leading
        use.accessibilityIdentifier = "useAvailable"
        use.addAction { [model] in model.useAvailable() }
        use.setContentHuggingPriority(.required, for: .horizontal)
        let captionRow = m.regular ? stack(.horizontal, 16, [freeCaption, use], align: .firstBaseline)
                                   : stack(.vertical, 6, [freeCaption, use], align: .leading)
        messageSlot.axis = .vertical
        addArrangedSubview(Card(metrics, spacing: 14, [fields, messageSlot, bar, captionRow]))
        dynamic.axis = .vertical; dynamic.spacing = metrics.sectionGap
        addArrangedSubview(dynamic)
        update()
    }
    required init(coder: NSCoder) { fatalError() }

    /// The size the bar shows, clamped to its range, as the slider did.
    private var range: ClosedRange<Double> {
        guard let layout = model.editingLayout else { return 0...0 }
        let low = Double(layout.minimumContainerBytes ?? layout.containerBytes) / 1e9
        let high = Double(layout.maximumBytes) / 1e9
        return min(low, high)...high
    }

    func update() {
        guard let layout = model.layout, let editing = model.editingLayout else { return }
        let outOfRange = model.editorMessage != nil && !model.unchanged
        target.update(text: model.targetText, error: outOfRange)
        free.update(text: model.freeText, error: false)
        let range = self.range
        let current = Double(model.targetBytes ?? layout.containerBytes) / 1e9
        bar.update(layout: model.localPlan?.after ?? editing, boundary: PartitionBar.Boundary(
            range: range, value: min(max(current, range.lowerBound), range.upperBound),
            changed: { [model] value, _ in
                if value >= range.upperBound - 0.05 { model.useAvailable() }
                else { model.setTarget(String(format: "%.1f", value)) }
            }))
        freeCaption.text = "\(Capacity.gb(layout.freeInsideBytes)) free within APFS. Supported resize limits are checked separately."

        messageSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if outOfRange, let message = message(editing) {
            messageSlot.addArrangedSubview(fieldError(m, message, identifier: "sizeValidation"))
        }
        messageSlot.isHidden = messageSlot.arrangedSubviews.isEmpty

        dynamic.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let following = model.followingPartitions
        if !following.isEmpty && layout.growthSupported {
            let size = following.reduce(0) { $0 + $1.blocks * layout.sectorSize }
            let names = following.map { "\($0.kind == .linux ? "Linux partition" : "partition") \($0.bsdName)" }.joined(separator: ", ")
            dynamic.addArrangedSubview(Card(m, spacing: 0, [OptionRow(m, kind: .checkbox, selected: model.eraseFollowing,
                title: "Erase \(names) · \(Capacity.gb(size))",
                detail: "Growing APFS needs the space after it. Everything on \(following.count == 1 ? "this partition" : "these partitions") is erased.") { [model] in
                    model.setEraseFollowing(!model.eraseFollowing)
                }]))
        }
        dynamic.addArrangedSubview(resultingLayout(layout))
        if model.canCreateLinuxPartition {
            let plan = model.localPlan
            let shrinking = (plan?.targetBytes ?? layout.containerBytes) < layout.backingBytes
            let leave = OptionRow(m, kind: .radio, selected: !model.createLinux, title: "Leave unallocated", detail: nil) { [model] in model.setCreateLinux(false) }
            let create = OptionRow(m, kind: .radio, selected: model.createLinux, title: "Create Linux partition",
                                   detail: "Unformatted; format later in Linux.") { [model] in model.setCreateLinux(true) }
            create.accessibilityIdentifier = "createLinux"
            dynamic.addArrangedSubview(Card(m, spacing: 4, [label(shrinking ? "Space you free" : "Unallocated space", Theme.font(m.heading, .semibold, .headline)), leave, create]))
        }
    }

    /// Why the typed size can't be reviewed, in the user's terms where possible.
    private func message(_ layout: StorageLayout) -> String? {
        guard let bytes = model.targetBytes else { return model.editorMessage }
        if let minimum = layout.minimumContainerBytes, bytes < minimum, bytes < layout.containerBytes {
            return "Can’t go below \(Capacity.gb(minimum))."
        }
        if bytes > layout.maximumBytes {
            return model.followingPartitions.isEmpty || model.eraseFollowing
                ? "Can’t go above \(Capacity.gb(layout.maximumBytes)): the disk ends there."
                : "Can’t go above \(Capacity.gb(layout.maximumBytes)): a partition follows APFS."
        }
        return model.editorMessage
    }

    private func resultingLayout(_ layout: StorageLayout) -> UIView {
        let plan = model.localPlan
        let heading = label("Resulting layout", Theme.font(m.heading, .semibold, .headline))
        var top: [UIView] = [heading, spacer()]
        if model.unchanged { top.append(label("No changes yet", Theme.font(m.caption), Theme.muted, lines: 1)) }
        var rows: [UIView] = [stack(.horizontal, 8, top, align: .firstBaseline),
                              LegendRow(m, swatch: nil, title: "APFS container", value: Capacity.gb(plan?.targetBytes ?? layout.containerBytes), valueIdentifier: "APFS containerValue"),
                              LegendRow(m, swatch: nil, title: "Backing partition", value: Capacity.gb(plan?.after.backingBytes ?? layout.backingBytes), valueIdentifier: "Backing partitionValue"),
                              LegendRow(m, swatch: nil, title: "Unallocated space", value: Capacity.gb(plan?.after.allUnallocatedBytes ?? layout.allUnallocatedBytes), valueIdentifier: "Unallocated spaceValue")]
        if model.createLinux, let linux = plan?.after.partitions.last(where: { $0.kind == .linux }) {
            rows.append(LegendRow(m, swatch: nil, title: "Linux · unformatted", value: Capacity.gb(linux.blocks * layout.sectorSize)))
        }
        return Card(m, spacing: 12, rows)
    }
}
