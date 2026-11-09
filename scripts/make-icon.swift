// アプリアイコン（仮）を描いて PNG に書き出す。
//   swift scripts/make-icon.swift <出力.png>
// 座標は左下が原点、1024×1024。
import AppKit

guard CommandLine.arguments.count == 2 else {
    print("使い方: swift scripts/make-icon.swift <出力.png>")
    exit(1)
}

let size = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

func color(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

/// 中心・大きさ・傾きで楕円を作る。
func oval(_ cx: CGFloat, _ cy: CGFloat, _ width: CGFloat, _ height: CGFloat, rotate degrees: CGFloat = 0) -> NSBezierPath {
    let path = NSBezierPath(ovalIn: NSRect(x: -width / 2, y: -height / 2, width: width, height: height))
    var transform = AffineTransform(translationByX: cx, byY: cy)
    transform.rotate(byDegrees: degrees)
    path.transform(using: transform)
    return path
}

func polygon(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: points[0].0, y: points[0].1))
    for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
    path.close()
    return path
}

/// clip の内側にだけ描く。
func clipped(to clip: NSBezierPath, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

let cream = color(0xF4E8D0)
let brown = color(0x7A5233)
let darkBrown = color(0x553722)
let chestnut = color(0xAD6A33)

// 台紙（macOS のアイコンの角丸四角）
let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 24
shadow.set()
color(0x7FAE9C).setFill()
plate.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [color(0xA9CFC0), color(0x6E9F8D)])!.draw(in: plate, angle: -90)

clipped(to: plate) {
    // 枝
    let branch = NSBezierPath()
    branch.move(to: NSPoint(x: 150, y: 262))
    branch.curve(to: NSPoint(x: 880, y: 250), controlPoint1: NSPoint(x: 380, y: 290), controlPoint2: NSPoint(x: 650, y: 232))
    branch.lineWidth = 30
    branch.lineCapStyle = .round
    color(0x4C3A2C).setStroke()
    branch.stroke()

    // 足
    for x in [470.0, 545.0] as [CGFloat] {
        let leg = NSBezierPath()
        leg.move(to: NSPoint(x: x, y: 350))
        leg.line(to: NSPoint(x: x + 8, y: 272))
        leg.lineWidth = 13
        leg.lineCapStyle = .round
        color(0x8C6239).setStroke()
        leg.stroke()
    }

    // 尾
    darkBrown.setFill()
    polygon([(330, 470), (165, 318), (222, 282), (395, 400)]).fill()

    // 体と頭
    let body = oval(480, 478, 450, 330, rotate: 24)
    let head = oval(652, 652, 246, 240)
    brown.setFill()
    body.fill()
    head.fill()

    // 腹から喉にかけての淡い色
    let figure = NSBezierPath()
    figure.append(body)
    figure.append(head)
    figure.windingRule = .nonZero
    clipped(to: figure) {
        cream.setFill()
        oval(560, 415, 360, 250, rotate: 24).fill()
        oval(700, 585, 190, 150, rotate: 10).fill()

        // 胸の斑点（ツグミの目印）
        darkBrown.setFill()
        let spots: [(CGFloat, CGFloat)] = [
            (598, 505), (660, 478), (560, 448), (625, 425), (690, 420),
            (520, 392), (588, 370), (652, 365), (545, 330), (610, 318),
        ]
        for (x, y) in spots { oval(x, y, 30, 22, rotate: 24).fill() }
    }

    // 翼
    chestnut.setFill()
    oval(405, 500, 318, 176, rotate: 24).fill()
    let feather = NSBezierPath()
    feather.move(to: NSPoint(x: 300, y: 432))
    feather.curve(to: NSPoint(x: 520, y: 548), controlPoint1: NSPoint(x: 380, y: 452), controlPoint2: NSPoint(x: 470, y: 500))
    feather.lineWidth = 12
    feather.lineCapStyle = .round
    color(0x7E4A22).setStroke()
    feather.stroke()

    // 眉の白い線
    let brow = NSBezierPath()
    brow.move(to: NSPoint(x: 590, y: 700))
    brow.curve(to: NSPoint(x: 742, y: 694), controlPoint1: NSPoint(x: 640, y: 732), controlPoint2: NSPoint(x: 705, y: 728))
    brow.lineWidth = 24
    brow.lineCapStyle = .round
    cream.setStroke()
    brow.stroke()

    // くちばし
    color(0xE2A93B).setFill()
    polygon([(762, 668), (862, 640), (764, 612)]).fill()

    // 目
    color(0x24170E).setFill()
    oval(690, 652, 44, 44).fill()
    NSColor.white.setFill()
    oval(698, 661, 13, 13).fill()
}

NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
