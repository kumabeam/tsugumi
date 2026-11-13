import AppKit

/// メニューバーに出す鳥のシルエット。アプリアイコンと同じ形
enum MenuBarIcon {
    /// 元の図の大きさ。描くときにメニューバー向けの大きさへ縮める
    private static let canvas = NSSize(width: 572, height: 578)
    static let size = NSSize(width: 14, height: 14)

    /// tint が nil ならテンプレート画像（メニューバーの色に合わせて白黒が切り替わる）
    static func image(tint: NSColor? = nil) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let scale = rect.height / canvas.height
            var transform = AffineTransform(translationByX: (rect.width - canvas.width * scale) / 2, byY: 0)
            transform.scale(scale)
            let path = outline()
            path.transform(using: transform)
            (tint ?? .black).setFill()
            path.fill()
            return true
        }
        image.isTemplate = tint == nil
        image.accessibilityDescription = "Tsugumi"
        return image
    }

    private static func outline() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 98.6, y: 325.8))
        path.line(to: NSPoint(x: 98.6, y: 433.1))
        path.line(to: NSPoint(x: 98.6, y: 433.2))
        path.line(to: NSPoint(x: 0.0, y: 486.9))
        path.line(to: NSPoint(x: 98.6, y: 486.9))
        path.line(to: NSPoint(x: 98.6, y: 539.9))
        path.curve(to: NSPoint(x: 219.7, y: 575.9), controlPoint1: NSPoint(x: 113.5, y: 556.7), controlPoint2: NSPoint(x: 157.3, y: 586.2))
        path.curve(to: NSPoint(x: 308.3, y: 470.4), controlPoint1: NSPoint(x: 298.9, y: 562.8), controlPoint2: NSPoint(x: 309.6, y: 504.7))
        path.curve(to: NSPoint(x: 308.3, y: 445.1), controlPoint1: NSPoint(x: 308.3, y: 459.0), controlPoint2: NSPoint(x: 308.3, y: 450.9))
        path.line(to: NSPoint(x: 308.3, y: 445.1))
        path.curve(to: NSPoint(x: 308.3, y: 433.1), controlPoint1: NSPoint(x: 308.3, y: 437.5), controlPoint2: NSPoint(x: 308.3, y: 434.1))
        path.line(to: NSPoint(x: 315.9, y: 433.1))
        path.curve(to: NSPoint(x: 366.5, y: 405.0), controlPoint1: NSPoint(x: 339.8, y: 433.8), controlPoint2: NSPoint(x: 350.8, y: 427.8))
        path.line(to: NSPoint(x: 522.4, y: 141.0))
        path.line(to: NSPoint(x: 555.6, y: 84.8))
        path.curve(to: NSPoint(x: 546.2, y: 83.1), controlPoint1: NSPoint(x: 552.4, y: 84.2), controlPoint2: NSPoint(x: 549.3, y: 83.6))
        path.line(to: NSPoint(x: 571.9, y: 38.7))
        path.line(to: NSPoint(x: 505.4, y: 0.3))
        path.line(to: NSPoint(x: 459.7, y: 79.5))
        path.curve(to: NSPoint(x: 430.7, y: 86.5), controlPoint1: NSPoint(x: 449.6, y: 80.9), controlPoint2: NSPoint(x: 440.0, y: 83.2))
        path.curve(to: NSPoint(x: 350.9, y: 73.6), controlPoint1: NSPoint(x: 405.6, y: 78.1), controlPoint2: NSPoint(x: 378.8, y: 73.6))
        path.curve(to: NSPoint(x: 98.6, y: 325.8), controlPoint1: NSPoint(x: 211.8, y: 73.6), controlPoint2: NSPoint(x: 99.0, y: 186.4))
        path.close()
        return path
    }
}
