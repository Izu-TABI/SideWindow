// AppIcon.icns を生成する
// 使い方: swift scripts/make-icon.swift [出力先 .icns] [--preview <out.png>]
//
// 「大きなウィンドウの右側に、小さなウィンドウが浮いている」絵。
// SF Symbols はアプリアイコンに使えない（Apple の利用規約）ので、図形はすべてここで描く。
import AppKit

var arguments = Array(CommandLine.arguments.dropFirst())
var previewPath: String?
if let index = arguments.firstIndex(of: "--preview"), index + 1 < arguments.count {
    previewPath = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
}
let output = arguments.first ?? "Resources/AppIcon.icns"

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// タイトルバー付きのウィンドウ
func drawWindow(_ rect: NSRect, radius: CGFloat, fill: NSColor, titleBar: NSColor, barHeight: CGFloat,
                dotRadius: CGFloat, dotColors: [NSColor], shadowAlpha: CGFloat, lines: [CGFloat], lineColor: NSColor) {
    let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x0A1240, alpha: shadowAlpha)
    shadow.shadowBlurRadius = 48
    shadow.shadowOffset = NSSize(width: 0, height: -20)
    shadow.set()
    fill.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    // タイトルバー
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    titleBar.setFill()
    NSRect(x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight).fill()
    NSGraphicsContext.restoreGraphicsState()

    // 信号機ボタン
    for (i, dotColor) in dotColors.enumerated() {
        let cx = rect.minX + barHeight * 0.55 + CGFloat(i) * dotRadius * 3
        let cy = rect.maxY - barHeight / 2
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - dotRadius, y: cy - dotRadius, width: dotRadius * 2, height: dotRadius * 2)).fill()
    }

    // 本文の線
    lineColor.setFill()
    let left = rect.minX + barHeight * 0.55 - dotRadius
    let lineHeight = dotRadius * 1.6
    var y = rect.maxY - barHeight - lineHeight * 2.2
    for fraction in lines {
        let width = (rect.width - (left - rect.minX) * 2) * fraction
        NSBezierPath(roundedRect: NSRect(x: left, y: y, width: width, height: lineHeight),
                     xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
        y -= lineHeight * 2.1
    }
}

func drawIcon() {
    // macOS のアイコングリッド（824pt の角丸四角）
    let bodyRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let body = NSBezierPath(roundedRect: bodyRect, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: color(0x7B6CF6), ending: color(0x2B3FC9))!.draw(in: body, angle: -90)
    NSGradient(starting: color(0xFFFFFF, alpha: 0.18), ending: color(0xFFFFFF, alpha: 0))!
        .draw(in: body, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    body.addClip()

    // 奥の大きなウィンドウ（書いているドキュメント）
    drawWindow(NSRect(x: 190, y: 250, width: 520, height: 470), radius: 44,
               fill: color(0xFFFFFF, alpha: 0.9), titleBar: color(0xE6E9F7), barHeight: 70,
               dotRadius: 13, dotColors: [color(0xFF5F57), color(0xFEBC2E), color(0x28C840)], shadowAlpha: 0.25,
               lines: [0.85, 0.85, 0.6, 0.85, 0.4], lineColor: color(0x2B3FC9, alpha: 0.18))

    // 右側に浮いている小さなウィンドウ（参照資料）
    drawWindow(NSRect(x: 520, y: 320, width: 320, height: 300), radius: 36,
               fill: color(0xFFFFFF), titleBar: color(0xFFC94D), barHeight: 60,
               dotRadius: 11, dotColors: Array(repeating: color(0xFFFFFF, alpha: 0.85), count: 3), shadowAlpha: 0.45,
               lines: [0.9, 0.9, 0.55], lineColor: color(0x7B6CF6, alpha: 0.45))

    NSGraphicsContext.restoreGraphicsState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    // 1024pt の座標系で描いて各サイズに縮小する
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if let previewPath {
    try render(pixels: 1024).write(to: URL(fileURLWithPath: previewPath))
    print("✓ \(previewPath)")
    exit(0)
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "✓ \(output)" : "iconutil failed")
