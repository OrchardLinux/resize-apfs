import UIKit

/// Design tokens from designs/resize-apfs.pen. iOS 12 has no dynamic system
/// colors or SF Symbols, so colors are fixed and icons are drawn here.
enum Theme {
    static let background = UIColor(hex: 0xF3F5F8)
    static let card = UIColor.white
    static let ink = UIColor(hex: 0x182230)
    static let muted = UIColor(hex: 0x687485)
    static let faint = UIColor(hex: 0x8793A3)
    static let line = UIColor(hex: 0xE3E7ED)
    static let blue = UIColor(hex: 0x2563EB)
    static let blueTint = UIColor(hex: 0xEFF5FF)
    static let track = UIColor(hex: 0xE5EDFA)
    static let green = UIColor(hex: 0x318369)
    static let greenTint = UIColor(hex: 0xE0F1EB)
    static let destructive = UIColor(hex: 0xC84038)
    static let destructiveTint = UIColor(hex: 0xFBE9E7)
    static let linux = UIColor(hex: 0x6B57B8)
    static let other = UIColor(hex: 0xCBD5E1)
    static let unallocated = UIColor(hex: 0xE9EEF5)
    static let disabledFill = UIColor(hex: 0xE2E7EE)
    static let warningFill = UIColor(hex: 0xFFF4DF)
    static let warningInk = UIColor(hex: 0x805012)
    /// The part of APFS held by a removable snapshot: the allocated blue, half strength.
    static let snapshot = UIColor(hex: 0x2563EB).withAlphaComponent(0.45)

    /// System font at the design size, scaled with Dynamic Type.
    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular, _ style: UIFont.TextStyle = .body) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }
    static func digits(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedDigitSystemFont(ofSize: size, weight: weight))
    }
    /// Menlo: iOS 12 has no monospaced system font.
    static func mono(_ size: CGFloat) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "Menlo", size: size) ?? .systemFont(ofSize: size))
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
    var cardPadding: CGFloat { regular ? 24 : 16 }
    var sectionGap: CGFloat { regular ? 24 : 18 }
    var title: CGFloat { regular ? 30 : (narrow ? 24 : 28) }
    var appName: CGFloat { regular ? 22 : (narrow ? 24 : 28) }
    var heading: CGFloat { regular ? 18 : 16 }
    var row: CGFloat { regular ? 14 : 13 }
    var caption: CGFloat { regular ? 13 : 12 }
    var optionTitle: CGFloat { regular ? 15 : 14 }
    var optionDetail: CGFloat { regular ? 13 : 12 }
    var description: CGFloat { regular ? 15 : 14 }
    var big: CGFloat { regular ? 27 : 24 }
    var barHeight: CGFloat { regular ? 72 : (narrow ? 56 : 64) }
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
    case warning, alertCircle, plug, drive, layers, flask, info, lock, xCircle

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
