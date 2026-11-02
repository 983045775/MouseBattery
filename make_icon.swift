// 生成应用图标：深色圆角底 + 鼠标轮廓 + ATK 字样
// 用法：swiftc make_icon.swift -o make_icon && ./make_icon AppIcon.iconset && iconutil -c icns AppIcon.iconset
import AppKit

func render(size px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // 背景：macOS 图标网格内的圆角方块（四周留 ~10% 边距）
    let inset = s * 0.1
    let bg = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bgPath = NSBezierPath(roundedRect: bg, xRadius: bg.width * 0.225, yRadius: bg.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.28, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 1)])!
        .draw(in: bgPath, angle: -90)

    // 鼠标主体
    let mw = bg.width * 0.47, mh = bg.width * 0.66
    let mouse = NSRect(x: bg.midX - mw / 2, y: bg.minY + bg.height * 0.17, width: mw, height: mh)
    let body = NSBezierPath(roundedRect: mouse, xRadius: mw / 2, yRadius: mw / 2)
    NSGradient(colors: [NSColor(calibratedWhite: 0.98, alpha: 1), NSColor(calibratedWhite: 0.78, alpha: 1)])!
        .draw(in: body, angle: -90)

    // 左右键分割线与滚轮
    let line = NSBezierPath()
    line.move(to: NSPoint(x: mouse.midX, y: mouse.maxY))
    line.line(to: NSPoint(x: mouse.midX, y: mouse.maxY - mh * 0.42))
    line.lineWidth = max(1, s * 0.012)
    NSColor(calibratedWhite: 0.35, alpha: 1).setStroke()
    line.stroke()

    let ww = mw * 0.13, wh = mh * 0.17
    let wheel = NSRect(x: mouse.midX - ww / 2, y: mouse.maxY - mh * 0.30, width: ww, height: wh)
    NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.10, alpha: 1).setFill()
    NSBezierPath(roundedRect: wheel, xRadius: ww / 2, yRadius: ww / 2).fill()

    // ATK 字样（压在鼠标下半部）
    let font = NSFont.systemFont(ofSize: mw * 0.40, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
        .kern: mw * 0.03,
    ]
    let text = NSAttributedString(string: "ATK", attributes: attrs)
    let ts = text.size()
    text.draw(at: NSPoint(x: mouse.midX - ts.width / 2, y: mouse.minY + mh * 0.20))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs {
    try! render(size: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
