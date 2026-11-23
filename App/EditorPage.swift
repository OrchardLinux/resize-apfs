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
    private let legendSlot = UIStackView()
    private let freeCaption: UILabel
    /// Builds the yellow snapshot offer (Pages.snapshotOffer), set by the root controller.
    var snapshotOffer: ((StorageLayout) -> UIView?)?

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
        addArrangedSubview(stack(.vertical, 6, [titleLabel, label("APFS container · \(layout.apfs.bsdName)", Theme.font(m.description), Theme.muted)]))

        let fields = stack(.horizontal, m.regular ? 24 : 12, [target, free], align: .top)
        fields.distribution = .fillEqually
        let use = TouchButton(type: .system)
        use.setTitle("Use available space", for: .normal)
        use.titleLabel?.font = Theme.font(m.caption, .semibold)
        use.tintColor = Theme.blue
        use.contentHorizontalAlignment = .leading
        use.contentEdgeInsets = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 12)
        use.accessibilityIdentifier = "useAvailable"
        use.addAction { [model] in model.useAvailable() }
        use.setContentHuggingPriority(.required, for: .horizontal)
        let captionRow = m.regular ? stack(.horizontal, 16, [freeCaption, use], align: .firstBaseline)
                                   : stack(.vertical, 6, [freeCaption, use], align: .leading)
        messageSlot.axis = .vertical
        legendSlot.axis = .vertical
        addArrangedSubview(Card(metrics, spacing: 14, [fields, messageSlot, bar, legendSlot, captionRow]))
        dynamic.axis = .vertical; dynamic.spacing = metrics.sectionGap
        addArrangedSubview(dynamic)
        update()
    }
    required init(coder: NSCoder) { fatalError() }

    /// The size the bar shows, clamped to its range, as the slider did.
    private var range: ClosedRange<Double> {
        guard let layout = model.editingLayout else { return 0...0 }
        let low = Double(layout.minimumContainerBytes ?? layout.containerBytes) / 1e9
        let high = Double(model.maximumBytes ?? layout.maximumBytes) / 1e9
        return min(low, high)...high
    }

    func update() {
        guard let layout = model.layout, let editing = model.editingLayout else { return }
        let outOfRange = model.editorMessage != nil && !model.unchanged
        target.update(text: model.targetText, error: outOfRange)
        free.update(text: model.freeText, error: false)
        let current = Double(model.targetBytes ?? layout.containerBytes) / 1e9
        updateList(model.localPlan?.after ?? editing)
        bar.update(layout: model.localPlan?.after ?? editing, boundary: barBoundary(current))
        freeCaption.text = "\(Capacity.gb(layout.freeInsideBytes)) free within APFS. Supported resize limits are checked separately."

        messageSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if outOfRange, let message = message(editing) {
            messageSlot.addArrangedSubview(fieldError(m, message, identifier: "sizeValidation"))
        }
        messageSlot.isHidden = messageSlot.arrangedSubviews.isEmpty

        dynamic.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let offer = snapshotOffer?(layout) { dynamic.addArrangedSubview(offer) }
        let following = model.followingPartitions
        if model.canEraseFollowing && layout.growthSupported {
            // The partitions themselves, under the option's title.
            let rows = following.map { part in
                LegendRow(m, swatch: Theme.linux, title: "\(part.label) · \(part.bsdName)", value: Capacity.gb(part.blocks * layout.sectorSize))
            }
            let option = OptionRow(m, kind: .checkbox, selected: model.eraseFollowing,
                                   title: following.count == 1 ? "Erase the Linux partition after APFS" : "Erase the Linux partitions after APFS",
                                   detail: nil, below: stack(.vertical, 6, rows)) { [model] in model.setEraseFollowing(!model.eraseFollowing) }
            option.accessibilityIdentifier = "eraseFollowing"
            dynamic.addArrangedSubview(Card(m, spacing: 0, [option]))
        }
        dynamic.addArrangedSubview(resultingLayout(layout))
        if model.canCreateLinuxPartition {
            let plan = model.localPlan
            let shrinking = (plan?.targetBytes ?? layout.containerBytes) < layout.backingBytes
            let leave = OptionRow(m, kind: .radio, selected: !model.createLinux, title: "Leave unallocated", detail: nil) { [model] in model.setCreateLinux(false) }
            let create = OptionRow(m, kind: .radio, selected: model.createLinux, title: "Create Linux partition",
                                   detail: "Unformatted; format later in Linux.") { [model] in model.setCreateLinux(true) }
            create.accessibilityIdentifier = "createLinux"
            dynamic.addArrangedSubview(section(m, shrinking ? "Space you free" : "Unallocated space", ListCard(m, [leave, create])))
        }
    }

    /// During a drag only the fields, the bar and the list follow; the cards
    /// below update once when the finger lifts.
    private func preview(_ value: Double) {
        model.previewTarget(value)
        guard let editing = model.editingLayout else { return }
        let shown = model.localPlan?.after ?? editing
        target.update(text: model.targetText, error: false)
        free.update(text: model.freeText, error: false)
        updateList(shown)
        bar.update(layout: shown, boundary: barBoundary(value))
    }
    /// The bar's range and callback for `value`, shared by update and preview.
    private func barBoundary(_ value: Double) -> PartitionBar.Boundary {
        let range = self.range
        return PartitionBar.Boundary(range: range, value: min(max(value, range.lowerBound), range.upperBound),
            changed: { [weak self, model] value, finished in
                guard finished else { self?.preview(value); return }
                if value >= range.upperBound - 0.001 { model.useAvailable() }
                else { model.setTarget(String(format: "%.0f", value)) }
            })
    }

    /// The partition list keeps its rows while only the sizes change.
    private var listKey = ""
    private var listRows: [LegendRow] = []
    private func updateList(_ layout: StorageLayout) {
        let segments = DiskSegment.of(layout)
        let key = segments.map(\.detail).joined(separator: "|")
        if key == listKey, listRows.count == segments.count {
            for (row, segment) in zip(listRows, segments) { row.valueLabel.text = Capacity.gb(segment.bytes) }
            return
        }
        listKey = key
        legendSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        listRows = segments.map { LegendRow(m, swatch: $0.color, title: $0.detail, value: Capacity.gb($0.bytes)) }
        listRows.forEach { legendSlot.addArrangedSubview($0) }
        legendSlot.spacing = 8
    }

    /// Why the typed size can't be reviewed, in the user's terms where possible.
    private func message(_ layout: StorageLayout) -> String? {
        guard let bytes = model.targetBytes else { return model.editorMessage }
        if let minimum = layout.minimumContainerBytes, bytes < minimum, bytes < layout.containerBytes {
            // The snapshot offer, when there is one, sits right below the size card.
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
        var rows: [UIView] = [LegendRow(m, swatch: nil, title: "APFS container", value: Capacity.gb(plan?.targetBytes ?? layout.containerBytes), valueIdentifier: "APFS containerValue"),
                              LegendRow(m, swatch: nil, title: "Backing partition", value: Capacity.gb(plan?.after.backingBytes ?? layout.backingBytes), valueIdentifier: "Backing partitionValue"),
                              LegendRow(m, swatch: nil, title: "Unallocated space", value: Capacity.gb(plan?.after.allUnallocatedBytes ?? layout.allUnallocatedBytes), valueIdentifier: "Unallocated spaceValue")]
        if model.createLinux, let linux = plan?.after.partitions.last(where: { $0.kind == .linux }) {
            rows.append(LegendRow(m, swatch: nil, title: "Linux · unformatted", value: Capacity.gb(linux.blocks * layout.sectorSize)))
        }
        return section(m, "Resulting layout", ListCard(m, rows))
    }
}
