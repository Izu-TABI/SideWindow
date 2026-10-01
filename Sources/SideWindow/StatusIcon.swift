import AppKit

/// メニューバーのアイコン。SF Symbols はアイコンに使えないのでコードで描く
enum StatusIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // 奥のウィンドウ（枠だけ）
            let back = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 2.75, width: 10.5, height: 8.5), xRadius: 1.8, yRadius: 1.8)
            back.lineWidth = 1.5
            back.stroke()

            // 手前に浮いたウィンドウ。周りを抜いて重なりを見せる
            let frontRect = NSRect(x: 6, y: 7, width: 11, height: 9)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: frontRect.insetBy(dx: -1.5, dy: -1.5), xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(roundedRect: frontRect, xRadius: 2, yRadius: 2).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
