import UIKit
import ResizeCore

// The components of designs/resize-apfs.pen ("Components" board).

func label(_ text: String = "", _ font: UIFont, _ color: UIColor = Theme.ink, lines: Int = 0, align: NSTextAlignment = .natural) -> UILabel {
    let label = UILabel()
    label.text = text; label.font = font; label.textColor = color
    label.numberOfLines = lines; label.textAlignment = align
    label.adjustsFontForContentSizeCategory = true
    return label
}

func stack(_ axis: NSLayoutConstraint.Axis, _ spacing: CGFloat, _ views: [UIView] = [], align: UIStackView.Alignment = .fill) -> UIStackView {
    let stack = UIStackView(arrangedSubviews: views)
    stack.axis = axis; stack.spacing = spacing; stack.alignment = align
    return stack
}

func spacer() -> UIView {
    let view = UIView()
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
}

func swatch(_ color: UIColor, size: CGFloat = 9) -> UIView {
    let view = UIView()
    view.backgroundColor = color
    view.layer.cornerRadius = 2
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: size), view.heightAnchor.constraint(equalToConstant: size)])
    return view
}

/// White rounded card with a vertical stack of content.
final class Card: UIView {
    let content: UIStackView
    init(_ metrics: Metrics, spacing: CGFloat = 12, _ views: [UIView] = []) {
        content = stack(.vertical, spacing, views)
        super.init(frame: .zero)
        backgroundColor = Theme.card
        layer.cornerRadius = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let p = metrics.cardPadding
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: p),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Swatch, label, value. No swatch with `indent` lines the label up with swatched rows.
final class LegendRow: UIStackView {
    let valueLabel: UILabel
    init(_ metrics: Metrics, swatch color: UIColor?, title: String, value: String, indent: Bool = false,
         titleColor: UIColor = Theme.muted, valueColor: UIColor = Theme.ink, valueIdentifier: String? = nil) {
        valueLabel = label(value, Theme.digits(metrics.row), valueColor, lines: 1, align: .right)
        let title = label(title, Theme.font(metrics.row), titleColor)
        let lead = stack(.horizontal, 8, [], align: .center)
        if let color { lead.addArrangedSubview(swatch(color)) }
        else if indent { let gap = UIView(); gap.widthAnchor.constraint(equalToConstant: 9).isActive = true; lead.addArrangedSubview(gap) }
        lead.addArrangedSubview(title)
        super.init(frame: .zero)
        axis = .horizontal; spacing = 12; alignment = .firstBaseline
        addArrangedSubview(lead); addArrangedSubview(valueLabel)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.accessibilityIdentifier = valueIdentifier
        isAccessibilityElement = true
        accessibilityLabel = title.text
        accessibilityValue = value
    }
    required init(coder: NSCoder) { fatalError() }
}

/// Swatch, label, "before → after".
final class ChangeRow: UIStackView {
    init(_ metrics: Metrics, swatch color: UIColor?, title: String, before: String, after: String) {
        super.init(frame: .zero)
        axis = .horizontal; spacing = 12; alignment = .center
        let lead = stack(.horizontal, 8, [], align: .center)
        if let color { lead.addArrangedSubview(swatch(color)) }
        lead.addArrangedSubview(label(title, Theme.font(metrics.row), Theme.muted))
        let values = stack(.horizontal, 6, [label(before, Theme.digits(metrics.row), Theme.muted, lines: 1),
                                            Icon.arrowRight.view(13, color: Theme.faint),
                                            label(after, Theme.digits(metrics.row, .semibold), Theme.ink, lines: 1)], align: .center)
        values.setContentCompressionResistancePriority(.required, for: .horizontal)
        addArrangedSubview(lead); addArrangedSubview(spacer()); addArrangedSubview(values)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityValue = "\(before) to \(after)"
    }
    required init(coder: NSCoder) { fatalError() }
}

/// Checkbox or radio option with title and optional detail.
final class OptionRow: UIControl {
    enum Kind { case checkbox, radio }
    init(_ metrics: Metrics, kind: Kind, selected: Bool, title: String, detail: String?, trailing: String? = nil, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        let icon: Icon = kind == .checkbox ? (selected ? .squareCheck : .square) : (selected ? .circleDot : .circle)
        let control = icon.view(20, color: selected ? Theme.blue : Theme.faint)
        let titleRow = stack(.horizontal, 8, [label(title, Theme.font(metrics.optionTitle, .medium))], align: .firstBaseline)
        if let trailing {
            let gain = label(trailing, Theme.digits(metrics.optionTitle - 1, .semibold), Theme.green, lines: 1)
            gain.setContentCompressionResistancePriority(.required, for: .horizontal)
            titleRow.addArrangedSubview(spacer()); titleRow.addArrangedSubview(gain)
        }
        let text = stack(.vertical, 3, [titleRow])
        if let detail { text.addArrangedSubview(label(detail, Theme.font(metrics.optionDetail), Theme.muted)) }
        let row = stack(.horizontal, 12, [control, text], align: .top)
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.topAnchor.constraint(equalTo: topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
                                     row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor)])
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityLabel = [title, detail].compactMap { $0 }.joined(separator: ". ")
        accessibilityTraits = selected ? [.button, .selected] : .button
    }
    required init?(coder: NSCoder) { fatalError() }
    private let action: () -> Void
    @objc private func tapped() { action() }
}

/// The bottom action button.
final class ActionButton: UIControl {
    enum Style { case primary, destructive }
    enum Arrow { case none, leading, trailing }
    private let action: () -> Void
    init(title: String, identifier: String, style: Style = .primary, arrow: Arrow = .none,
         disabled: Bool = false, busy: Bool = false, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        let enabled = !disabled && !busy
        layer.cornerRadius = 11
        backgroundColor = disabled ? Theme.disabledFill : (style == .destructive ? Theme.destructive : Theme.blue)
        let tint = disabled ? Theme.faint : UIColor.white
        let row = stack(.horizontal, 8, [], align: .center)
        if busy {
            let spinner = UIActivityIndicatorView(style: .white)
            spinner.startAnimating(); row.addArrangedSubview(spinner)
        } else if arrow == .leading { row.addArrangedSubview(Icon.arrowRight.view(17, color: tint)) }
        row.addArrangedSubview(label(title, Theme.font(15, .semibold, .headline), tint, lines: 1))
        if !busy && arrow == .trailing { row.addArrangedSubview(Icon.arrowRight.view(17, color: tint)) }
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.centerXAnchor.constraint(equalTo: centerXAnchor), row.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     heightAnchor.constraint(greaterThanOrEqualToConstant: 52)])
        isEnabled = enabled
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        accessibilityIdentifier = identifier
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tapped() { action() }
    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.8 : 1 } }
}

/// The yellow box: warnings and the snapshot offer share it. Amber fill and border,
/// a heading with icon, paragraphs, and optionally one action button.
final class WarningBox: UIView {
    init(_ metrics: Metrics, icon: Icon, title: String, paragraphs: [String],
         action: (title: String, identifier: String, run: () -> Void, enabled: Bool)? = nil) {
        super.init(frame: .zero)
        backgroundColor = Theme.warningFill
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.borderColor = Theme.warningBorder.cgColor
        let heading = stack(.horizontal, 8, [icon.view(16, color: Theme.warningInk),
                                             label(title, Theme.font(metrics.regular ? 16 : 15, .semibold, .headline), Theme.warningInk)], align: .center)
        let body = stack(.vertical, 8, [heading] + paragraphs.map { label($0, Theme.font(metrics.row), Theme.warningInk) })
        if let action {
            let button = UIButton(type: .system)
            button.setTitle(action.title, for: .normal)
            button.titleLabel?.font = Theme.font(metrics.row, .semibold)
            button.setTitleColor(Theme.destructive, for: .normal)
            button.setTitleColor(Theme.faint, for: .disabled)
            button.backgroundColor = .white
            button.layer.cornerRadius = 9
            button.layer.borderWidth = 1
            button.layer.borderColor = Theme.warningBorder.cgColor
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
            button.accessibilityIdentifier = action.identifier
            button.isEnabled = action.enabled
            button.addAction(action.run)
            body.addArrangedSubview(stack(.horizontal, 0, [button, spacer()]))
            body.setCustomSpacing(12, after: body.arrangedSubviews[body.arrangedSubviews.count - 2])
        }
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        let padding: CGFloat = metrics.regular ? 20 : 16
        NSLayoutConstraint.activate([body.topAnchor.constraint(equalTo: topAnchor, constant: padding), body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
                                     body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding), body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding)])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Red message under a field.
func fieldError(_ metrics: Metrics, _ text: String, identifier: String) -> UIView {
    let text = label(text, Theme.font(metrics.caption), Theme.destructive)
    text.accessibilityIdentifier = identifier
    return stack(.horizontal, 6, [Icon.alertCircle.view(14, color: Theme.destructive, lineWidth: 2.2), text], align: .top)
}

/// The disk's partitions in proportion, with unallocated gaps, as StorageMap drew them.
struct DiskSegment {
    enum Kind { case apfs, linux, other, unallocated }
    var kind: Kind
    var bytes: Int64
    var title: String
    /// The list's wording: GPT name, type and device node.
    var detail: String
    var color: UIColor {
        switch kind {
        case .apfs: return Theme.blue
        case .linux: return Theme.linux
        case .other: return Theme.other
        case .unallocated: return Theme.unallocated
        }
    }
    static func of(_ layout: StorageLayout) -> [DiskSegment] {
        var result: [DiskSegment] = []
        var cursor = layout.firstUsableLBA
        for part in layout.partitions.sorted(by: { $0.firstLBA < $1.firstLBA }) {
            if part.firstLBA > cursor {
                result.append(DiskSegment(kind: .unallocated, bytes: (part.firstLBA - cursor) * layout.sectorSize, title: "Unallocated", detail: "Unallocated"))
            }
            let kind: Kind = part.kind == .apfs ? .apfs : part.isLinux ? .linux : .other
            result.append(DiskSegment(kind: kind, bytes: part.blocks * layout.sectorSize, title: part.typeName,
                                      detail: "\(part.label) · \(part.bsdName)"))
            cursor = part.lastLBA + 1
        }
        if cursor <= layout.lastUsableLBA {
            result.append(DiskSegment(kind: .unallocated, bytes: (layout.lastUsableLBA - cursor + 1) * layout.sectorSize, title: "Unallocated", detail: "Unallocated"))
        }
        return result
    }
}

/// The partitions under a disk bar: colour, kind and size.
func diskLegend(_ m: Metrics, _ layout: StorageLayout) -> UIView {
    func sum(_ match: (Partition) -> Bool) -> Int64 { layout.partitions.filter(match).reduce(0) { $0 + $1.blocks * layout.sectorSize } }
    var items: [(UIColor, String)] = [(Theme.blue, "APFS  \(Capacity.gb(layout.backingBytes))")]
    let linux = sum(\.isLinux), other = sum { $0.kind != .apfs && !$0.isLinux }
    if linux > 0 { items.append((Theme.linux, "Linux  \(Capacity.gb(linux))")) }
    if other > 0 { items.append((Theme.other, "Other partitions  \(Capacity.gb(other))")) }
    if layout.allUnallocatedBytes > 0 { items.append((Theme.unallocated, "Unallocated  \(Capacity.gb(layout.allUnallocatedBytes))")) }
    let perRow = m.regular ? 4 : 2
    let rows = stride(from: 0, to: items.count, by: perRow).map { start -> UIView in
        let row = stack(.horizontal, 16, items[start..<min(start + perRow, items.count)].map { item in
            stack(.horizontal, 7, [swatch(item.0, size: 8), label(item.1, Theme.font(m.caption), Theme.muted, lines: 1)], align: .center)
        }, align: .center)
        row.addArrangedSubview(spacer())
        return row
    }
    return stack(.vertical, 8, rows)
}

/// Every partition and gap in disk order, as the bar shows them, with its size.
func partitionList(_ m: Metrics, _ layout: StorageLayout) -> UIView {
    // Alignment gaps that round to 0 GB would only read as noise.
    stack(.vertical, 8, DiskSegment.of(layout).filter { $0.kind != .unallocated || $0.bytes >= 50_000_000 }.map { segment in
        LegendRow(m, swatch: segment.color, title: segment.detail, value: Capacity.gb(segment.bytes))
    })
}

/// Proportional bar. Labels go inside wide segments when `labels` is set.
/// With `boundary`, the APFS segment's end is a drag handle (the editor's slider).
final class PartitionBar: UIView, UIGestureRecognizerDelegate {
    private var segments: [DiskSegment]
    private let showLabels: Bool
    private let apfsTitle: String
    private let metrics: Metrics
    struct Boundary {
        var range: ClosedRange<Double>   // GB
        var value: Double                // GB
        var changed: (Double, Bool) -> Void   // value, finished
    }
    private var boundary: Boundary?
    private var views: [UIView] = []
    private let handle = UIView()

    init(_ metrics: Metrics, layout: StorageLayout, labels: Bool, apfsTitle: String = "APFS", boundary: Boundary? = nil) {
        segments = DiskSegment.of(layout); showLabels = labels; self.apfsTitle = apfsTitle; self.metrics = metrics; self.boundary = boundary
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: labels ? metrics.barHeight : 38).isActive = true
        layer.cornerRadius = labels ? 10 : 8
        clipsToBounds = true
        makeSegmentViews()
        configureBoundary()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The drag handle and its gesture exist once a range is known; the editor
    /// passes the range only in its first update, after building the bar.
    private func configureBoundary() {
        guard let boundary else {
            isAccessibilityElement = true
            accessibilityTraits = .none
            accessibilityLabel = segments.map { "\($0.title), \(Capacity.gb($0.bytes))" }.joined(separator: "; ")
            return
        }
        if handle.superview == nil {
            handle.backgroundColor = UIColor(hex: 0x1D4ED8)
            let grip = GripView()
            grip.frame = CGRect(x: 7, y: 0, width: 8, height: 14)
            grip.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin]
            handle.addSubview(grip)
            handle.isUserInteractionEnabled = false
            addSubview(handle)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
            pan.delegate = self
            addGestureRecognizer(pan)
            // A tap moves the boundary too, as a slider's track does.
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dragged(_:))))
        }
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityIdentifier = "sizeSlider"
        accessibilityLabel = "APFS size in gigabytes"
        accessibilityValue = String(format: "%.1f GB", boundary.value)
    }

    private func makeSegmentViews() {
        views.forEach { $0.removeFromSuperview() }
        views = segments.map { segment in
            let view = UIView()
            view.backgroundColor = segment.color
            insertSubview(view, at: 0)
            return view
        }
    }

    /// Keeps the same view (and its drag gesture) while the plan changes underneath.
    func update(layout: StorageLayout, boundary: Boundary?) {
        segments = DiskSegment.of(layout)
        self.boundary = boundary
        makeSegmentViews()
        configureBoundary()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let total = Double(max(1, segments.reduce(0) { $0 + $1.bytes }))
        let gap: CGFloat = 3
        let usable = max(0, bounds.width - CGFloat(max(0, segments.count - 1)) * gap)
        var x: CGFloat = 0
        for (segment, view) in zip(segments, views) {
            let width = max(segment.kind == .other ? 3 : 0, usable * CGFloat(Double(segment.bytes) / total))
            view.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            view.subviews.forEach { $0.removeFromSuperview() }
            if showLabels, width > 72 {
                let dark = segment.kind == .unallocated || segment.kind == .other
                let title = label(segment.kind == .apfs ? apfsTitle : segment.title, Theme.font(metrics.caption, .semibold), dark ? Theme.muted : .white, lines: 1)
                let size = label(Capacity.gb(segment.bytes), Theme.digits(metrics.caption - 1), dark ? Theme.muted : UIColor(white: 1, alpha: 0.85), lines: 1)
                let text = stack(.vertical, 3, [title, size])
                let inner = width - 24 - (segment.kind == .apfs && boundary != nil ? 22 : 0)
                let fitted = text.systemLayoutSizeFitting(CGSize(width: inner, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
                text.frame = CGRect(x: 12, y: (bounds.height - fitted.height) / 2, width: inner, height: fitted.height)
                view.addSubview(text)
            }
            x += width + gap
        }
        if let apfs = zip(segments, views).first(where: { $0.0.kind == .apfs })?.1, boundary != nil {
            handle.frame = CGRect(x: apfs.frame.maxX - 22, y: 0, width: 22, height: bounds.height)
        }
    }

    @objc private func dragged(_ pan: UIGestureRecognizer) {
        guard let boundary else { return }
        let point = pan.location(in: self)
        let fraction = Double(min(max(0, point.x / max(1, bounds.width)), 1))
        let total = Double(segments.reduce(0) { $0 + $1.bytes }) / 1e9
        let start = Double(segments.prefix { $0.kind != .apfs }.reduce(0) { $0 + $1.bytes }) / 1e9
        let value = min(max(fraction * total - start, boundary.range.lowerBound), boundary.range.upperBound)
        boundary.changed((value * 10).rounded() / 10, pan is UITapGestureRecognizer || pan.state == .ended || pan.state == .cancelled)
    }
    /// Only a sideways drag moves the boundary; vertical swipes scroll the page.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, gesture.view === self else { return super.gestureRecognizerShouldBegin(gesture) }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }
    override func accessibilityIncrement() { step(0.1) }
    override func accessibilityDecrement() { step(-0.1) }
    private func step(_ delta: Double) {
        guard let boundary else { return }
        boundary.changed(min(max(boundary.value + delta, boundary.range.lowerBound), boundary.range.upperBound), true)
    }
}

/// Two columns of three dots: the drag handle's grip.
private final class GripView: UIView {
    override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); center.y = superview.map { $0.bounds.midY } ?? center.y }
    override func draw(_ rect: CGRect) {
        UIColor.white.setFill()
        for column in 0..<2 { for row in 0..<3 {
            UIBezierPath(ovalIn: CGRect(x: CGFloat(column) * 5, y: CGFloat(row) * 5, width: 3, height: 3)).fill()
        } }
    }
}

/// The APFS container's usage: allocated, the part a removable snapshot holds, free.
final class UsageBar: UIView {
    private let parts: [(Double, UIColor)]
    private var views: [UIView] = []
    init(total: Int64, parts: [(Int64, UIColor)]) {
        self.parts = parts.map { (Double($0.0) / Double(max(1, total)), $0.1) }
        super.init(frame: .zero)
        backgroundColor = Theme.track
        layer.cornerRadius = 4; clipsToBounds = true
        heightAnchor.constraint(equalToConstant: 7).isActive = true
        for part in self.parts { let view = UIView(); view.backgroundColor = part.1; addSubview(view); views.append(view) }
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        for (part, view) in zip(parts, views) {
            let width = bounds.width * CGFloat(min(max(part.0, 0), 1))
            view.frame = CGRect(x: x, y: 0, width: width, height: bounds.height); x += width
        }
    }
}

/// "New APFS size" / "Free space after" input with clear button and unit.
final class SizeField: UIView, UITextFieldDelegate {
    let field = UITextField()
    private let onChange: (String) -> Void
    private let frameView = UIView()
    init(_ metrics: Metrics, title: String, identifier: String, text: String, error: Bool, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        let titleLabel = label(title, Theme.font(metrics.caption), Theme.muted)
        field.text = text
        field.font = Theme.digits(17, .medium)
        field.textColor = Theme.ink
        field.keyboardType = .decimalPad
        field.clearButtonMode = .never
        field.accessibilityLabel = title
        field.accessibilityIdentifier = identifier
        field.addTarget(self, action: #selector(edited), for: .editingChanged)
        field.delegate = self
        let clear = UIButton(type: .custom)
        clear.setImage(Icon.xCircle.image(16), for: .normal)
        clear.tintColor = Theme.faint.withAlphaComponent(0.6)
        clear.accessibilityLabel = "Clear \(title)"
        clear.accessibilityIdentifier = identifier + "Clear"
        clear.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        clear.isHidden = text.isEmpty
        self.clear = clear
        let unit = label("GB", Theme.font(15), Theme.muted, lines: 1)
        unit.setContentHuggingPriority(.required, for: .horizontal)
        let row = stack(.horizontal, 8, [field, clear, unit], align: .center)
        row.translatesAutoresizingMaskIntoConstraints = false
        frameView.addSubview(row)
        frameView.layer.cornerRadius = 9
        frameView.layer.borderWidth = 1
        frameView.layer.borderColor = (error ? Theme.destructive : Theme.blue.withAlphaComponent(0.6)).cgColor
        frameView.backgroundColor = .white
        NSLayoutConstraint.activate([frameView.heightAnchor.constraint(equalToConstant: 44),
                                     row.leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: 12),
                                     row.trailingAnchor.constraint(equalTo: frameView.trailingAnchor, constant: -12),
                                     row.centerYAnchor.constraint(equalTo: frameView.centerYAnchor)])
        let column = stack(.vertical, 6, [titleLabel, frameView])
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    private var clear: UIButton!
    /// Updates the text unless it already matches, so the cursor stays where the user is typing.
    func update(text: String, error: Bool) {
        if field.text != text { field.text = text }
        clear.isHidden = text.isEmpty
        frameView.layer.borderColor = (error ? Theme.destructive : Theme.blue.withAlphaComponent(0.6)).cgColor
    }
    /// Digits and one decimal at most, the precision every size is shown with.
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let current = textField.text ?? ""
        guard let swap = Range(range, in: current) else { return false }
        let text = current.replacingCharacters(in: swap, with: string)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
        guard text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }), parts.count <= 2 else { return false }
        return parts[0].count <= 5 && (parts.count == 1 || parts[1].count <= 1)
    }
    @objc private func edited() { clear.isHidden = (field.text ?? "").isEmpty; onChange(field.text ?? "") }
    @objc private func clearTapped() { field.text = ""; edited() }
}
