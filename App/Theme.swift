import UIKit

/// Design tokens from the Tokyo Night set in designs/resize-apfs.pen, which takes
/// its colours from Omarchy's Tokyo Night theme and the shell's Settings window
/// (background, foreground at 4 % for boxes, 12 % for their lines, 7 % between
/// rows). iOS 12 has no dynamic colours or SF Symbols: colours are fixed and
/// icons are drawn here. Type is JetBrains Mono, bundled in App/Fonts.
enum Theme {
    static let background = UIColor(hex: 0x1A1B26)
    static let foreground = UIColor(hex: 0xA9B1D6)
    /// Main text: the theme's foreground, as Settings uses it.
    static let ink = foreground
    /// Secondary text: foreground at 60 %.
    static let muted = foreground.withAlphaComponent(0.6)
    /// Captions and placeholders: foreground at 40 %.
    static let faint = foreground.withAlphaComponent(0.4)
    static let card = foreground.withAlphaComponent(0.04)
    static let cardBorder = foreground.withAlphaComponent(0.12)
    static let separator = foreground.withAlphaComponent(0.07)
    static let line = cardBorder
    static let blue = UIColor(hex: 0x7AA2F7)
    static let blueTint = UIColor(hex: 0x7AA2F7, alpha: 0.12)
    static let blueBorder = UIColor(hex: 0x7AA2F7, alpha: 0.35)
    /// Text and icons on a blue or coloured fill.
    static let onAccent = UIColor(hex: 0x16161E)
    static let green = UIColor(hex: 0x9ECE6A)
    static let greenTint = UIColor(hex: 0x9ECE6A, alpha: 0.10)
    static let greenBorder = UIColor(hex: 0x9ECE6A, alpha: 0.35)
    static let destructive = UIColor(hex: 0xF7768E)
    static let destructiveTint = UIColor(hex: 0xF7768E, alpha: 0.08)
    static let destructiveBorder = UIColor(hex: 0xF7768E, alpha: 0.35)
    static let linux = UIColor(hex: 0xBB9AF7)
    static let other = UIColor(hex: 0x414868)
    static let unallocated = UIColor(hex: 0x292E42)
    static let track = UIColor(hex: 0x292E42)
    static let disabledFill = UIColor(hex: 0x292E42)
    static let warningFill = UIColor(hex: 0xE0AF68, alpha: 0.07)
    static let warningInk = UIColor(hex: 0xE0AF68)
    static let warningBorder = UIColor(hex: 0xE0AF68, alpha: 0.32)
    /// The drag handle, as on the installer's split slider.
    static let handle = UIColor(hex: 0xC0CAF5)
    /// Dialogs over the dimmed page, as the installer's.
    static let dialog = UIColor(hex: 0x1A1B26)
    static let dialogBorder = UIColor(hex: 0x2F334D)
    static let scrim = UIColor(hex: 0x0D0E14, alpha: 0.7)
    /// The part of APFS held by a removable snapshot: the allocated blue at 40 %.
    static let snapshot = UIColor(hex: 0x7AA2F7, alpha: 0.4)
    /// The part of the progress bar the running step will fill.
    static let stepRunning = UIColor(hex: 0x7AA2F7, alpha: 0.35)
    /// The line around a quiet button.
    static let quietBorder = foreground.withAlphaComponent(0.4)

    /// JetBrains Mono at the design size, scaled with Dynamic Type.
    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular, _ style: UIFont.TextStyle = .body) -> UIFont {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "JetBrainsMono-Bold"
        case .semibold: name = "JetBrainsMono-SemiBold"
        case .medium: name = "JetBrainsMono-Medium"
        default: name = "JetBrainsMono-Regular"
        }
        let base = UIFont(name: name, size: size) ?? .monospacedDigitSystemFont(ofSize: size, weight: weight)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }
    /// Figures: the same monospaced face, so columns of sizes line up.
    static func digits(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont { font(size, weight) }
    static func mono(_ size: CGFloat) -> UIFont { font(size) }

    /// An uppercase section caption above a box, as Settings draws them.
    static func caption(_ text: String, size: CGFloat = 10) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [.kern: 1.5, .font: font(size), .foregroundColor: faint])
    }
}

/// Sizes that differ between iPad (regular width), phones and the 320-pt iPod touch.
struct Metrics {
    let regular: Bool
    let narrow: Bool
    init(traits: UITraitCollection, width: CGFloat) {
        regular = traits.horizontalSizeClass == .regular
        narrow = !regular && width <= 330
    }
    var side: CGFloat { regular ? 32 : (narrow ? 12 : 16) }
    /// Space between the status bar and the header.
    var headerTop: CGFloat { regular ? 20 : 14 }
    var cardPadding: CGFloat { regular ? 20 : 14 }
    /// Between sections of a page.
    var sectionGap: CGFloat { regular ? 32 : (narrow ? 22 : 26) }
    /// Between a section's caption and its box.
    var captionGap: CGFloat { 8 }
    var title: CGFloat { regular ? 24 : 22 }
    var appName: CGFloat { regular ? 18 : (narrow ? 17 : 18) }
    var heading: CGFloat { regular ? 15 : 14 }
    var row: CGFloat { regular ? 13 : 12 }
    var caption: CGFloat { regular ? 12 : 11 }
    var optionTitle: CGFloat { regular ? 14 : 13 }
    var optionDetail: CGFloat { regular ? 12 : 11 }
    var description: CGFloat { regular ? 13 : 12 }
    var big: CGFloat { regular ? 22 : 19 }
    /// The badge above a status page: one size for the spinner and the result symbols.
    var badge: CGFloat { regular ? 68 : 64 }
    var barHeight: CGFloat { regular ? 64 : (narrow ? 52 : 56) }
    /// A bar without labels (review and result).
    var plainBarHeight: CGFloat { regular ? 44 : 32 }
    var rowPadding: UIEdgeInsets { UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14) }
    var contentWidth: CGFloat { 920 }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Line icons on a 24-point grid, drawn as template images.
enum Icon {
    case chevronLeft, chevronRight, arrowRight, check, checkCircle, circle, circleDot, square, squareCheck
    case warning, alertCircle, plug, drive, layers, flask, info, lock, xCircle, circleStop, history, key, timer
    /// The app icon's drive with its two arrows, filled: the whole icon without its background.
    case appDrive

    func image(_ size: CGFloat = 20, lineWidth: CGFloat = 2) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            let cg = context.cgContext
            cg.scaleBy(x: size / 24, y: size / 24)
            UIColor.black.setStroke(); UIColor.black.setFill()
            let path = UIBezierPath()
            path.lineWidth = lineWidth; path.lineCapStyle = .round; path.lineJoinStyle = .round
            func circle(_ c: CGPoint, _ r: CGFloat) -> UIBezierPath { UIBezierPath(arcCenter: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: true) }
            func line(_ points: [CGPoint]) { path.move(to: points[0]); points.dropFirst().forEach { path.addLine(to: $0) } }
            func stroke(_ p: UIBezierPath) { p.lineWidth = lineWidth; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke() }
            switch self {
            case .chevronLeft: line([CGPoint(x: 15, y: 18), CGPoint(x: 9, y: 12), CGPoint(x: 15, y: 6)])
            case .chevronRight: line([CGPoint(x: 9, y: 18), CGPoint(x: 15, y: 12), CGPoint(x: 9, y: 6)])
            case .arrowRight: line([CGPoint(x: 5, y: 12), CGPoint(x: 19, y: 12)]); line([CGPoint(x: 12, y: 5), CGPoint(x: 19, y: 12), CGPoint(x: 12, y: 19)])
            case .check: line([CGPoint(x: 5, y: 12.5), CGPoint(x: 10, y: 17.5), CGPoint(x: 19, y: 7)])
            case .checkCircle:
                stroke(circle(CGPoint(x: 12, y: 12), 10)); line([CGPoint(x: 8, y: 12), CGPoint(x: 11, y: 15), CGPoint(x: 16, y: 9)])
            case .circle: stroke(circle(CGPoint(x: 12, y: 12), 10))
            case .circleDot: stroke(circle(CGPoint(x: 12, y: 12), 10)); circle(CGPoint(x: 12, y: 12), 4.5).fill()
            case .circleStop:
                stroke(circle(CGPoint(x: 12, y: 12), 10)); stroke(UIBezierPath(roundedRect: CGRect(x: 9, y: 9, width: 6, height: 6), cornerRadius: 1))
            case .square: stroke(UIBezierPath(roundedRect: CGRect(x: 3, y: 3, width: 18, height: 18), cornerRadius: 3))
            case .squareCheck:
                UIBezierPath(roundedRect: CGRect(x: 2, y: 2, width: 20, height: 20), cornerRadius: 4).fill()
                cg.setBlendMode(.clear)
                let tick = UIBezierPath(); tick.move(to: CGPoint(x: 7, y: 12)); tick.addLine(to: CGPoint(x: 10.5, y: 15.5)); tick.addLine(to: CGPoint(x: 17, y: 8.5))
                stroke(tick)
                cg.setBlendMode(.normal)
            case .warning:
                line([CGPoint(x: 12, y: 3), CGPoint(x: 22, y: 20), CGPoint(x: 2, y: 20)]); path.close()
                line([CGPoint(x: 12, y: 9), CGPoint(x: 12, y: 13)]); circle(CGPoint(x: 12, y: 16.6), 1.1).fill()
            case .alertCircle:
                stroke(circle(CGPoint(x: 12, y: 12), 10)); line([CGPoint(x: 12, y: 7.5), CGPoint(x: 12, y: 12.5)]); circle(CGPoint(x: 12, y: 16.2), 1.1).fill()
            case .appDrive:
                // The app icon's shapes (App/Assets.xcassets, 1024 points) on this 24-point grid.
                let unit: CGFloat = 24.0 / 1024
                func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
                func polygon(_ points: [(CGFloat, CGFloat)]) -> UIBezierPath {
                    let shape = UIBezierPath()
                    shape.move(to: at(points[0].0, points[0].1)); points.dropFirst().forEach { shape.addLine(to: at($0.0, $0.1)) }
                    shape.close()
                    return shape
                }
                let body = UIBezierPath()
                body.move(to: at(128, 608)); body.addLine(to: at(168, 352))
                body.addQuadCurve(to: at(256, 278), controlPoint: at(180, 278)); body.addLine(to: at(768, 278))
                body.addQuadCurve(to: at(856, 352), controlPoint: at(844, 278)); body.addLine(to: at(896, 608))
                body.close(); body.fill()
                let base = UIBezierPath()
                base.move(to: at(128, 628)); base.addLine(to: at(896, 628)); base.addLine(to: at(896, 673))
                base.addQuadCurve(to: at(824, 745), controlPoint: at(896, 745)); base.addLine(to: at(200, 745))
                base.addQuadCurve(to: at(128, 673), controlPoint: at(128, 745))
                base.close(); base.fill()
                cg.setBlendMode(.clear)
                polygon([(293, 456), (373, 397), (373, 438), (480, 438), (480, 474), (373, 474), (373, 516)]).fill()
                polygon([(731, 456), (651, 397), (651, 438), (544, 438), (544, 474), (651, 474), (651, 516)]).fill()
                circle(at(804, 680), 25 * unit).fill()
                cg.setBlendMode(.normal)
            case .key:
                stroke(circle(CGPoint(x: 7.5, y: 16.5), 5.5))
                line([CGPoint(x: 11.4, y: 12.6), CGPoint(x: 21, y: 3)]); line([CGPoint(x: 17, y: 7), CGPoint(x: 20, y: 10)])
            case .timer:
                stroke(circle(CGPoint(x: 12, y: 14), 8))
                line([CGPoint(x: 10, y: 2), CGPoint(x: 14, y: 2)]); line([CGPoint(x: 12, y: 14), CGPoint(x: 15, y: 11)])
            case .plug:
                line([CGPoint(x: 9, y: 2), CGPoint(x: 9, y: 7)]); line([CGPoint(x: 15, y: 2), CGPoint(x: 15, y: 7)])
                stroke(UIBezierPath(roundedRect: CGRect(x: 6, y: 7, width: 12, height: 7), cornerRadius: 3))
                line([CGPoint(x: 12, y: 14), CGPoint(x: 12, y: 18), CGPoint(x: 10, y: 22)])
            case .drive:
                stroke(UIBezierPath(roundedRect: CGRect(x: 2, y: 13, width: 20, height: 8), cornerRadius: 2))
                line([CGPoint(x: 2, y: 15), CGPoint(x: 5.5, y: 5), CGPoint(x: 18.5, y: 5), CGPoint(x: 22, y: 15)])
                circle(CGPoint(x: 17.5, y: 17), 1.1).fill()
            case .layers:
                line([CGPoint(x: 12, y: 3), CGPoint(x: 22, y: 8), CGPoint(x: 12, y: 13), CGPoint(x: 2, y: 8)]); path.close()
                line([CGPoint(x: 2, y: 12), CGPoint(x: 12, y: 17), CGPoint(x: 22, y: 12)])
                line([CGPoint(x: 2, y: 16), CGPoint(x: 12, y: 21), CGPoint(x: 22, y: 16)])
            case .flask:
                line([CGPoint(x: 9, y: 3), CGPoint(x: 15, y: 3)]); line([CGPoint(x: 10, y: 3), CGPoint(x: 10, y: 9), CGPoint(x: 4, y: 20), CGPoint(x: 20, y: 20), CGPoint(x: 14, y: 9), CGPoint(x: 14, y: 3)])
                line([CGPoint(x: 7, y: 15), CGPoint(x: 17, y: 15)])
            case .info:
                stroke(circle(CGPoint(x: 12, y: 12), 10)); line([CGPoint(x: 12, y: 11), CGPoint(x: 12, y: 16.5)]); circle(CGPoint(x: 12, y: 7.8), 1.1).fill()
            case .lock:
                stroke(UIBezierPath(roundedRect: CGRect(x: 4, y: 11, width: 16, height: 10), cornerRadius: 2))
                let shackle = UIBezierPath(); shackle.move(to: CGPoint(x: 8, y: 11)); shackle.addLine(to: CGPoint(x: 8, y: 7))
                shackle.addArc(withCenter: CGPoint(x: 12, y: 7), radius: 4, startAngle: .pi, endAngle: 0, clockwise: true); shackle.addLine(to: CGPoint(x: 16, y: 11))
                stroke(shackle)
            case .history:
                let arc = UIBezierPath(arcCenter: CGPoint(x: 12, y: 12), radius: 9, startAngle: .pi * 1.1, endAngle: .pi * 0.9, clockwise: true)
                stroke(arc)
                line([CGPoint(x: 3, y: 4), CGPoint(x: 3, y: 9.5), CGPoint(x: 8.5, y: 9.5)])
                line([CGPoint(x: 12, y: 7), CGPoint(x: 12, y: 12), CGPoint(x: 15.5, y: 14)])
            case .xCircle:
                circle(CGPoint(x: 12, y: 12), 10).fill()
                cg.setBlendMode(.clear)
                let cross = UIBezierPath(); cross.move(to: CGPoint(x: 9, y: 9)); cross.addLine(to: CGPoint(x: 15, y: 15)); cross.move(to: CGPoint(x: 15, y: 9)); cross.addLine(to: CGPoint(x: 9, y: 15))
                stroke(cross)
                cg.setBlendMode(.normal)
            }
            path.stroke()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    func view(_ size: CGFloat = 20, color: UIColor, lineWidth: CGFloat = 2) -> UIImageView {
        let view = UIImageView(image: image(size, lineWidth: lineWidth))
        view.tintColor = color
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: size), view.heightAnchor.constraint(equalToConstant: size)])
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }
}
