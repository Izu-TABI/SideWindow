import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 言語に合わせた文（英語の環境で撮ると英語版の画像になる）
private func t(_ japanese: String, _ english: String) -> String {
    Localization.usesJapanese ? japanese : english
}

/// README 用の画像を作る。`SideWindow --demo <保存先>` で実行する（scripts/screenshots.sh）。
///
/// 架空の資料とレポートのウィンドウを並べて実際に固定し、自分のウィンドウだけを撮って壁紙の上に合成する。
/// 画面全体は撮らないので、ほかのアプリや個人の情報は写らない
@MainActor
final class DemoScene {
    private let output: URL
    private var reference: NSWindow!
    /// 固定する前に撮った資料のウィンドウ（固定すると、元のウィンドウに画面共有中の印が付くため）
    private var referenceBeforePin: CGImage?
    private var report: NSWindow!
    private var slide: SlideView!
    private var pin: PinController!
    /// 合成する範囲（画面座標）。上の 28 ポイントは作り物のメニューバー
    private var region = NSRect.zero
    private var scale: CGFloat = 2
    private static let menuBarHeight: CGFloat = 28
    /// 英語版の画像はファイル名の末尾に -en を付ける
    private var suffix: String { Localization.usesJapanese ? "" : "-en" }

    init(output: URL) {
        self.output = output
    }

    func run() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "SideWindowDemo"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        Preferences.store = UserDefaults(suiteName: suite)!
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        // いちばん細かい画面（Retina）に並べて撮る
        let screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.main!
        scale = screen.backingScaleFactor
        let visible = screen.visibleFrame
        region = NSRect(x: visible.midX - 640, y: visible.midY - 400, width: 1280, height: 800)
        makeWindows()
        await sleep(1.0)

        do {
            referenceBeforePin = try await capture(reference)
            try await pinReference()
            try await makeHero()
            if Localization.usesJapanese {
                // ソーシャルプレビューは日英のキャッチコピーを両方入れた 1 枚だけ作る
                try await makeSocialPreview()
            }
            try await makeAnimation()
            try await makeZoomSteps()
            print("✓ \(output.path)")
            exit(0)
        } catch {
            print("✘ \(error)")
            exit(1)
        }
    }

    // MARK: - 場面

    private func makeWindows() {
        let top = region.maxY - Self.menuBarHeight
        reference = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
        reference.title = t("学習時間の資料.pdf", "Study Hours.pdf")
        slide = SlideView()
        reference.contentView = slide
        reference.setFrame(NSRect(x: region.minX + 56, y: top - 44 - 470, width: 720, height: 470), display: true)
        reference.orderFront(nil)

        report = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        report.title = t("レポート草稿", "Report Draft")
        report.contentView = Self.reportView()
        report.setFrame(NSRect(x: region.minX + 300, y: region.minY + 44, width: 720, height: 500), display: true)
        report.makeKeyAndOrderFront(nil)
    }

    private func pinReference() async throws {
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(reference.windowNumber) }) else {
            throw NSError(domain: "Demo", code: 1, userInfo: [NSLocalizedDescriptionKey: "資料のウィンドウが見つからない"])
        }
        pin = PinController(filter: SCContentFilter(desktopIndependentWindow: window), index: 0)
        // 資料は PDF という設定なので、操作バーのアイコンも PDF の書類にする
        pin.mirror.appIcon = NSWorkspace.shared.icon(for: .pdf)
        pin.start()
        await sleep(1.5)
        // 画面の右上に置く
        let width: CGFloat = 430
        let height = width * reference.frame.height / reference.frame.width
        pin.panel.setFrame(NSRect(x: region.maxX - 28 - width, y: region.maxY - Self.menuBarHeight - 28 - height,
                                  width: width, height: height), display: true)
        report.makeKeyAndOrderFront(nil)
        await sleep(1.0)
    }

    /// 資料（奥）をパネルに映しながらレポートを書いている場面
    private func makeHero() async throws {
        pin.mirror.showChrome(for: 60)
        await sleep(0.5)
        let image = try await composite(windows: [reference, report, pin.panel])
        try write(image, name: "hero\(suffix).png")
    }

    /// 拡大の流れ：範囲を選ぶ → 拡大 → スクロールで移動
    private func makeZoomSteps() async throws {
        let mirror = pin.mirror
        mirror.showChrome(for: 0.01)
        await sleep(0.5)

        // グラフのあたりを選んでいるところ
        let chart = slide.convert(slide.chartRect, to: nil)
        let windowSize = reference.frame.size
        let selection = NSRect(x: chart.minX / windowSize.width * mirror.bounds.width,
                               y: chart.minY / windowSize.height * mirror.bounds.height,
                               width: chart.width / windowSize.width * mirror.bounds.width,
                               height: chart.height / windowSize.height * mirror.bounds.height)
        mirror.previewSelection(selection)
        await sleep(0.4)
        let selecting = try await capture(pin.panel)
        mirror.cancelSelecting()

        // 選んだところを拡大
        let source = CGRect(x: chart.minX, y: windowSize.height - chart.maxY, width: chart.width, height: chart.height)
        pin.zoom(to: source, previous: nil)
        await sleep(1.2)
        let zoomed = try await capture(pin.panel)

        // スクロールで右へ動かす
        pin.pan(by: CGVector(dx: -mirror.bounds.width * 0.55, dy: 0))
        await sleep(1.2)
        let panned = try await capture(pin.panel)

        let image = storyboard([
            (selecting, t("① 🔍 で範囲を選ぶ", "① Click 🔍 and pick an area")),
            (zoomed, t("② 選んだところを拡大", "② It’s zoomed in")),
            (panned, t("③ スクロールで位置を移動", "③ Scroll to move around")),
        ])
        try write(image, name: "zoom\(suffix).png")
    }

    // MARK: - 撮影と合成

    private func capture(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw NSError(domain: "Demo", code: 2, userInfo: [NSLocalizedDescriptionKey: "ウィンドウを撮れない: \(window.title)"])
        }
        let config = SCStreamConfiguration()
        config.width = Int(scWindow.frame.width * scale)
        config.height = Int(scWindow.frame.height * scale)
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
                                                          configuration: config)
    }

    /// 壁紙の上に、ウィンドウを後ろから順に影付きで重ねる
    private func composite(windows: [NSWindow]) async throws -> NSBitmapImageRep {
        var shots: [(CGImage, NSRect)] = []
        for window in windows {
            shots.append((try await capture(window), window.frame.offsetBy(dx: -region.minX, dy: -region.minY)))
        }
        return draw(size: region.size) { canvas in
            Self.drawWallpaper(in: canvas)
            Self.drawMenuBar(in: canvas)
            for (image, frame) in shots {
                Self.drawWindow(image, in: frame)
            }
        }
    }

    private func storyboard(_ steps: [(CGImage, String)]) -> NSBitmapImageRep {
        let height: CGFloat = 300
        let gap: CGFloat = 64
        let margin: CGFloat = 44
        let captionHeight: CGFloat = 44
        let widths = steps.map { CGFloat($0.0.width) / CGFloat($0.0.height) * height }
        let size = NSSize(width: widths.reduce(0, +) + gap * CGFloat(steps.count - 1) + margin * 2,
                          height: height + captionHeight + margin * 2)
        return draw(size: size) { canvas in
            Self.drawWallpaper(in: canvas)
            var x = margin
            for (index, (image, caption)) in steps.enumerated() {
                let frame = NSRect(x: x, y: margin + captionHeight, width: widths[index], height: height)
                Self.drawWindow(image, in: frame)
                Self.drawText(caption, size: 17, weight: .semibold,
                              centeredIn: NSRect(x: frame.minX - 20, y: margin - 2, width: frame.width + 40, height: 28))
                if index < steps.count - 1 {
                    Self.drawArrow(at: NSPoint(x: frame.maxX + gap / 2, y: frame.midY))
                }
                x = frame.maxX + gap
            }
        }
    }

    private func draw(size: NSSize, pixelScale: CGFloat? = nil, _ body: (NSRect) -> Void) -> NSBitmapImageRep {
        let scale = pixelScale ?? self.scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        body(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func write(_ rep: NSBitmapImageRep, name: String) throws {
        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: output.appendingPathComponent(name))
        print("  \(name) \(rep.pixelsWide)×\(rep.pixelsHigh)")
    }

    private static func drawWallpaper(in rect: NSRect) {
        NSGradient(colors: [color(0x7B6CF6), color(0x4B5BE0), color(0x2B3FC9)])!.draw(in: rect, angle: -60)
        // やわらかい光
        for (center, radius, alpha) in [(NSPoint(x: rect.width * 0.2, y: rect.height * 0.85), rect.width * 0.45, 0.28),
                                        (NSPoint(x: rect.width * 0.85, y: rect.height * 0.15), rect.width * 0.4, 0.18)] {
            NSGradient(starting: NSColor.white.withAlphaComponent(alpha), ending: NSColor.white.withAlphaComponent(0))!
                .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
        }
    }

    /// 作り物のメニューバー（右端に SideWindow のアイコン）
    private static func drawMenuBar(in rect: NSRect) {
        let bar = NSRect(x: 0, y: rect.height - menuBarHeight, width: rect.width, height: menuBarHeight)
        NSColor.white.withAlphaComponent(0.35).setFill()
        bar.fill()
        let iconSize: CGFloat = 17
        let template = StatusIcon.make()
        // テンプレート画像なので、別の画像の上で黒く塗ってから置く
        let icon = NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            NSColor.black.withAlphaComponent(0.85).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        icon.draw(in: NSRect(x: rect.width - 84, y: bar.midY - iconSize / 2, width: iconSize, height: iconSize))
        drawText("10:30", size: 13, weight: .medium, color: NSColor.black.withAlphaComponent(0.85),
                 centeredIn: NSRect(x: rect.width - 56, y: bar.minY + 5, width: 44, height: 18))
    }

    private static func drawWindow(_ image: CGImage, in frame: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        NSImage(cgImage: image, size: frame.size).draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawArrow(at center: NSPoint) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x - 10, y: center.y + 16))
        path.line(to: NSPoint(x: center.x + 8, y: center.y))
        path.line(to: NSPoint(x: center.x - 10, y: center.y - 16))
        path.lineWidth = 5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    private static func drawText(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor = .white,
                                 centeredIn rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(color == .white ? 0.35 : 0)
        shadow.shadowBlurRadius = 4
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ])
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    // MARK: - ウィンドウの中身（架空のもの）

    private static func reportView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        let text = NSTextView()
        text.textContainerInset = NSSize(width: 44, height: 36)
        text.isEditable = false
        text.backgroundColor = .white
        let japanese = Localization.usesJapanese
        let body = NSFont(name: japanese ? "HiraMinProN-W3" : "Georgia", size: 14.5) ?? .systemFont(ofSize: 14.5)
        let heading = NSFont(name: japanese ? "HiraKakuProN-W6" : "HelveticaNeue-Bold", size: 19) ?? .boldSystemFont(ofSize: 19)
        let section = NSFont(name: japanese ? "HiraKakuProN-W6" : "HelveticaNeue-Bold", size: 14.5) ?? .boldSystemFont(ofSize: 14.5)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        paragraph.paragraphSpacing = 10
        let content = NSMutableAttributedString()
        func add(_ string: String, _ font: NSFont, _ color: NSColor = NSColor(white: 0.12, alpha: 1)) {
            content.append(NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]))
        }
        add(t("学習時間の変化についての考察\n", "How Study Time Has Changed\n"), heading)
        add(t("1. はじめに\n", "1. Introduction\n"), section)
        add(t("本レポートでは、2021年度から2025年度にかけての週あたりの学習時間の変化を取り上げ、その背景にある要因を考察する。\n",
              "This report looks at how weekly study time changed from FY2021 to FY2025 and considers the reasons behind it.\n"), body)
        add(t("2. 結果\n", "2. Results\n"), section)
        add(t("図3に示すように、学習時間は5年間で約1.7倍に増加した。特に2023年度の伸びが大きく、オンライン教材の利用が広がった時期と重なっている。\n",
              "As Figure 3 shows, study time grew about 1.7× over five years. The jump in FY2023 was especially large, matching the period when online materials became widespread.\n"), body)
        add(t("3. 考察\n", "3. Discussion\n"), section)
        add(t("増加の要因として、", "One reason for the increase is"), body)
        text.textStorage?.setAttributedString(content)
        scroll.documentView = text
        return scroll
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// 架空の資料（スライド）。グラフと要点
private final class SlideView: NSView {
    /// グラフの範囲（このビューの座標）
    private(set) var chartRect = NSRect.zero

    private let values: [(String, CGFloat)] = [("2021", 6.2), ("2022", 7.0), ("2023", 8.6), ("2024", 9.3), ("2025", 10.5)]

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let ink = NSColor(white: 0.13, alpha: 1)
        let gray = NSColor(white: 0.45, alpha: 1)
        let accent = NSColor(srgbRed: 0.33, green: 0.36, blue: 0.9, alpha: 1)

        text(t("週あたりの学習時間の推移", "Weekly Study Hours"), size: 24, weight: .bold, color: ink,
             at: NSPoint(x: 36, y: bounds.height - 58))
        text(t("2021〜2025年度のアンケート調査（デモ用の架空のデータ）", "Survey, FY2021–2025 (fictional data for this demo)"),
             size: 12, weight: .regular, color: gray, at: NSPoint(x: 37, y: bounds.height - 82))

        // 棒グラフ
        let chart = NSRect(x: 36, y: 56, width: bounds.width * 0.56, height: bounds.height - 170)
        chartRect = chart.insetBy(dx: -14, dy: -16)
        let plot = NSRect(x: chart.minX + 30, y: chart.minY + 26, width: chart.width - 40, height: chart.height - 44)
        for step in 0...4 {
            let y = plot.minY + plot.height * CGFloat(step) / 4
            NSColor(white: 0.9, alpha: 1).setFill()
            NSRect(x: plot.minX, y: y, width: plot.width, height: 1).fill()
            text("\(step * 3)", size: 10, weight: .regular, color: gray, at: NSPoint(x: plot.minX - 22, y: y - 6))
        }
        let slot = plot.width / CGFloat(values.count)
        for (index, (label, value)) in values.enumerated() {
            let barHeight = plot.height * value / 12
            let bar = NSRect(x: plot.minX + slot * CGFloat(index) + slot * 0.22, y: plot.minY,
                             width: slot * 0.56, height: barHeight)
            let shade = accent.blended(withFraction: CGFloat(values.count - 1 - index) * 0.12, of: .white) ?? accent
            shade.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
            text(String(format: "%.1f", value), size: 11, weight: .semibold, color: ink,
                 at: NSPoint(x: bar.midX - 10, y: bar.maxY + 4))
            text(label, size: 11, weight: .regular, color: gray, at: NSPoint(x: bar.midX - 14, y: chart.minY + 6))
        }
        text(t("図3　週あたりの学習時間（時間）", "Figure 3  Study hours per week"), size: 11, weight: .medium, color: gray,
             at: NSPoint(x: chart.minX, y: 26))

        // 要点
        let left = bounds.width * 0.66
        text(t("ポイント", "Key points"), size: 16, weight: .bold, color: ink, at: NSPoint(x: left, y: bounds.height - 140))
        let points = Localization.usesJapanese
            ? ["5年間で約1.7倍に増加", "2023年度に大きく伸びた", "オンライン教材の利用が増加", "平日の夜に学ぶ人が多い"]
            : ["Up about 1.7× in 5 years", "Big jump in FY2023", "More online materials", "Most study on weeknights"]
        for (index, point) in points.enumerated() {
            let y = bounds.height - 176 - CGFloat(index) * 34
            accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: left, y: y + 5, width: 7, height: 7)).fill()
            text(point, size: 13, weight: .regular, color: ink, at: NSPoint(x: left + 16, y: y))
        }
    }

    private func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at point: NSPoint) {
        (string as NSString).draw(at: point, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ])
    }
}


// MARK: - 動くデモ（GIF）とソーシャルプレビュー

extension DemoScene {
    /// パネルを撮った 1 コマ（frame は合成する範囲の中の位置）
    private struct PanelShot {
        let image: CGImage
        let frame: NSRect
    }

    private func panelShot() async throws -> PanelShot {
        PanelShot(image: try await capture(pin.panel), frame: pin.panel.frame.offsetBy(dx: -region.minX, dy: -region.minY))
    }

    /// 操作バーのボタンの中心（合成する範囲の中の位置）
    private func buttonCenter(tip: String) -> NSPoint? {
        func search(_ view: NSView) -> BarButton? {
            if let button = view as? BarButton, button.toolTip == tip { return button }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        guard let button = search(pin.mirror), let window = button.window else { return nil }
        let point = window.convertPoint(toScreen: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
        return NSPoint(x: point.x - region.minX, y: point.y - region.minY)
    }

    /// 選ぶ → 飛んできて収まる → 🔍 で拡大 → スクロール → 全体に戻る、を 1 コマずつ撮ってつなぐ
    func makeAnimation() async throws {
        let mirror = pin.mirror
        let referenceImage = try await capture(reference)
        let referenceUnpinned = referenceBeforePin ?? referenceImage
        let reportImage = try await capture(report)
        let referenceFrame = reference.frame.offsetBy(dx: -region.minX, dy: -region.minY)
        let reportFrame = report.frame.offsetBy(dx: -region.minX, dy: -region.minY)

        // パネルの場面を順に撮る
        mirror.showChrome(for: 0.01)
        await sleep(0.5)
        let plain = try await panelShot()
        mirror.showChrome(for: 60)
        await sleep(0.4)
        let withChrome = try await panelShot()
        guard let zoomButton = buttonCenter(tip: L("範囲を選んで拡大")) else {
            throw NSError(domain: "Demo", code: 3, userInfo: [NSLocalizedDescriptionKey: "拡大ボタンが見つからない"])
        }

        let chart = slide.convert(slide.chartRect, to: nil)
        let windowSize = reference.frame.size
        let selection = NSRect(x: chart.minX / windowSize.width * mirror.bounds.width,
                               y: chart.minY / windowSize.height * mirror.bounds.height,
                               width: chart.width / windowSize.width * mirror.bounds.width,
                               height: chart.height / windowSize.height * mirror.bounds.height)
        var selecting: [(PanelShot, NSPoint)] = []
        for step in 0...6 {
            let t = CGFloat(step) / 6
            let rect = NSRect(x: selection.minX, y: selection.maxY - selection.height * t,
                              width: selection.width * t, height: selection.height * t)
            mirror.previewSelection(rect)
            await sleep(0.15)
            let shot = try await panelShot()
            selecting.append((shot, NSPoint(x: shot.frame.minX + rect.maxX, y: shot.frame.minY + rect.minY)))
        }
        mirror.cancelSelecting()

        let source = CGRect(x: chart.minX, y: windowSize.height - chart.maxY, width: chart.width, height: chart.height)
        pin.zoom(to: source, previous: nil)
        mirror.showChrome(for: 0.01)
        await sleep(1.2)
        let zoomed = try await panelShot()

        var panning: [PanelShot] = []
        for _ in 0..<8 {
            pin.pan(by: CGVector(dx: -mirror.bounds.width * 0.07, dy: 0))
            await sleep(0.3)
            panning.append(try await panelShot())
        }
        mirror.showChrome(for: 60)
        await sleep(0.4)
        let pannedWithChrome = try await panelShot()
        guard let showAllButton = buttonCenter(tip: L("全体を表示")) else {
            throw NSError(domain: "Demo", code: 3, userInfo: [NSLocalizedDescriptionKey: "全体表示のボタンが見つからない"])
        }
        pin.showAll()
        await sleep(1.2)
        let back = try await panelShot()
        mirror.showChrome(for: 0.01)

        // コマを組み立てる
        let captions = (
            intro: t("資料のウィンドウを、いつも手前に", "Keep the window you’re referring to on top"),
            pick: t("⌃⌥P で、手前に置きたいウィンドウを選ぶ", "Press ⌃⌥P and pick the window"),
            float: t("ほかのどのウィンドウよりも手前に浮かぶ", "It floats above every other window"),
            zoom: t("🔍 で見たいところを拡大", "Click 🔍 and pick an area to zoom"),
            pan: t("スクロールで位置を移動", "Scroll to move around"),
            back: t("⤢ で全体に戻る", "Click ⤢ to see it all")
        )
        var frames: [(NSBitmapImageRep, Double)] = []
        func add(_ panel: PanelShot?, rect: NSRect? = nil, highlight: Bool = false,
                 cursor: (NSCursor, NSPoint)?, caption: String, delay: Double) {
            let image = draw(size: region.size, pixelScale: 0.75) { canvas in
                Self.drawFlatWallpaper(in: canvas)
                Self.drawMenuBar(in: canvas)
                // 固定する前の場面では、元のウィンドウに画面共有中の印はまだ付いていない
                Self.drawWindow(panel == nil ? referenceUnpinned : referenceImage, in: referenceFrame)
                if highlight { Self.drawPickHighlight(referenceFrame) }
                Self.drawWindow(reportImage, in: reportFrame)
                if let panel { Self.drawWindow(panel.image, in: rect ?? panel.frame) }
                if let cursor { Self.drawCursor(cursor.0, at: cursor.1) }
                Self.drawCaption(caption, in: canvas)
            }
            frames.append((image, delay))
        }
        func moves(from start: NSPoint, to end: NSPoint, steps: Int) -> [NSPoint] {
            (1...steps).map { step in
                let t = CGFloat(step) / CGFloat(steps)
                let eased = t * t * (3 - 2 * t)
                return NSPoint(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased)
            }
        }

        let restPoint = NSPoint(x: reportFrame.minX + 380, y: reportFrame.minY + 150)
        let pickPoint = NSPoint(x: referenceFrame.minX + 150, y: referenceFrame.maxY - 160)
        add(nil, cursor: (.arrow, restPoint), caption: captions.intro, delay: 1.6)
        for point in moves(from: restPoint, to: pickPoint, steps: 4) {
            add(nil, highlight: true, cursor: (.arrow, point), caption: captions.pick, delay: 0.06)
        }
        add(nil, highlight: true, cursor: (.arrow, pickPoint), caption: captions.pick, delay: 0.7)
        // 元のウィンドウの場所から飛んできて収まる
        for step in 1...10 {
            let t = CGFloat(step) / 10
            let eased = 1 - pow(1 - t, 3)
            let rect = NSRect(x: referenceFrame.minX + (plain.frame.minX - referenceFrame.minX) * eased,
                              y: referenceFrame.minY + (plain.frame.minY - referenceFrame.minY) * eased,
                              width: referenceFrame.width + (plain.frame.width - referenceFrame.width) * eased,
                              height: referenceFrame.height + (plain.frame.height - referenceFrame.height) * eased)
            add(plain, rect: rect, cursor: (.arrow, pickPoint), caption: captions.pick, delay: 0.04)
        }
        add(withChrome, cursor: (.arrow, pickPoint), caption: captions.float, delay: 1.6)
        // 🔍 を押して範囲を選ぶ
        for point in moves(from: pickPoint, to: zoomButton, steps: 4) {
            add(withChrome, cursor: (.arrow, point), caption: captions.zoom, delay: 0.06)
        }
        add(withChrome, cursor: (.pointingHand, zoomButton), caption: captions.zoom, delay: 0.5)
        for (index, (shot, corner)) in selecting.enumerated() {
            add(shot, cursor: (.crosshair, corner), caption: captions.zoom, delay: index == 0 ? 0.5 : 0.08)
        }
        add(selecting.last!.0, cursor: (.crosshair, selecting.last!.1), caption: captions.zoom, delay: 0.4)
        let inside = NSPoint(x: zoomed.frame.midX, y: zoomed.frame.midY - 20)
        add(zoomed, cursor: (.arrow, inside), caption: captions.zoom, delay: 1.5)
        // スクロールで動かす
        for shot in panning {
            add(shot, cursor: (.arrow, NSPoint(x: shot.frame.midX, y: shot.frame.midY - 20)), caption: captions.pan, delay: 0.09)
        }
        add(panning.last!, cursor: (.arrow, NSPoint(x: panning.last!.frame.midX, y: panning.last!.frame.midY - 20)),
            caption: captions.pan, delay: 1.0)
        // ⤢ で全体に戻る
        for point in moves(from: NSPoint(x: pannedWithChrome.frame.midX, y: pannedWithChrome.frame.midY - 20), to: showAllButton, steps: 3) {
            add(pannedWithChrome, cursor: (.arrow, point), caption: captions.back, delay: 0.06)
        }
        add(pannedWithChrome, cursor: (.pointingHand, showAllButton), caption: captions.back, delay: 0.5)
        add(back, cursor: (.arrow, NSPoint(x: back.frame.midX, y: back.frame.minY - 30)), caption: captions.back, delay: 1.8)

        try writeGIF(frames, name: "demo\(suffix).gif")
    }

    private func writeGIF(_ frames: [(NSBitmapImageRep, Double)], name: String) throws {
        let url = output.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw NSError(domain: "Demo", code: 4, userInfo: [NSLocalizedDescriptionKey: "GIF を作れない"])
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for (rep, delay) in frames {
            guard let image = rep.cgImage else { continue }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Demo", code: 4, userInfo: [NSLocalizedDescriptionKey: "GIF を書き出せない"])
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("  \(name) \(frames.count) コマ \(size / 1024) KB")
    }

    /// GitHub のソーシャルプレビュー（1280×640）。リンクを貼ったときのカードに出る
    func makeSocialPreview() async throws {
        pin.mirror.showChrome(for: 60)
        await sleep(0.4)
        let panel = try await capture(pin.panel)
        let reportImage = try await capture(report)
        let icon = NSImage(contentsOf: output.appendingPathComponent("icon-1024.png"))
        let size = NSSize(width: 1280, height: 640)
        let rep = draw(size: size, pixelScale: 1) { canvas in
            Self.drawWallpaper(in: canvas)
            // 右側：作業中のウィンドウの上に、パネルが浮いている
            let reportWidth: CGFloat = 560
            let reportHeight = reportWidth * CGFloat(reportImage.height) / CGFloat(reportImage.width)
            Self.drawWindow(reportImage, in: NSRect(x: 700, y: -130, width: reportWidth, height: reportHeight))
            let panelWidth: CGFloat = 430
            let panelHeight = panelWidth * CGFloat(panel.height) / CGFloat(panel.width)
            Self.drawWindow(panel, in: NSRect(x: 806, y: 640 - 52 - panelHeight, width: panelWidth, height: panelHeight))
            // 左側：名前とキャッチコピー
            icon?.draw(in: NSRect(x: 64, y: 368, width: 196, height: 196))
            Self.drawLeft("SideWindow", size: 84, weight: .bold, at: NSPoint(x: 84, y: 262))
            Self.drawLeft("参照したいウィンドウを、いつも手前に。", size: 32, weight: .semibold, at: NSPoint(x: 88, y: 204))
            Self.drawLeft("Keep the window you’re referring to always on top.", size: 23, weight: .medium, at: NSPoint(x: 88, y: 160))
            Self.drawLeft("macOS ・ 無料 ・ オープンソース  /  Free & open source", size: 19, weight: .regular,
                          at: NSPoint(x: 88, y: 96), alpha: 0.8)
        }
        try write(rep, name: "social-preview.png")
    }

    private static func drawFlatWallpaper(in rect: NSRect) {
        color(0x5A5FD8).setFill()
        rect.fill()
    }

    /// ウィンドウを選ぶときの強調（どのウィンドウを選んでいるか分かるように）
    private static func drawPickHighlight(_ frame: NSRect) {
        let path = NSBezierPath(roundedRect: frame.insetBy(dx: -3, dy: -3), xRadius: 14, yRadius: 14)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        path.fill()
        path.lineWidth = 5
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private static func drawCursor(_ cursor: NSCursor, at point: NSPoint, scale: CGFloat = 1.3) {
        let image = cursor.image
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let hot = NSPoint(x: cursor.hotSpot.x * scale, y: cursor.hotSpot.y * scale)
        image.draw(in: NSRect(x: point.x - hot.x, y: point.y - (size.height - hot.y), width: size.width, height: size.height))
    }

    private static func drawCaption(_ text: String, in canvas: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let pill = NSRect(x: canvas.midX - textSize.width / 2 - 24, y: 30, width: textSize.width + 48, height: textSize.height + 20)
        NSColor.black.withAlphaComponent(0.66).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + 24, y: pill.minY + 10), withAttributes: attributes)
    }

    private static func drawLeft(_ text: String, size: CGFloat, weight: NSFont.Weight, at point: NSPoint, alpha: CGFloat = 1) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 6
        (text as NSString).draw(at: point, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .shadow: shadow,
        ])
    }
}
