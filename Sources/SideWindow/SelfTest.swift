import AppKit
import ScreenCaptureKit

/// 実際のパネルを使った動作確認。`SideWindow --selftest <スクリーンショットの保存先>` で実行する。
///
/// 自分のプロセスのウィンドウは画面収録の許可なしで取り込めるので、
/// テスト用のウィンドウを作って本物の取り込み・マウス操作・最小化を順に試す。
@MainActor
final class SelfTest {
    private let outputDirectory: URL
    private var results: [(name: String, passed: Bool, detail: String)] = []
    /// 環境のせいで確かめられなかった項目（失敗には数えない）
    private var skipped: [(name: String, reason: String)] = []
    private var source: NSWindow!
    private var other: NSWindow!
    private var pin: PinController!
    private var pinClosed = false
    /// テスト開始時に前面だったアプリ（背面での動作を試すときに前面へ戻す）
    private var frontAppAtStart: NSRunningApplication?

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    func run() async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        // ファイルに書き出しているときも 1 行ずつ出す（途中で打ち切られても結果が残るように）
        setvbuf(stdout, nil, _IOLBF, 0)
        frontAppAtStart = NSWorkspace.shared.frontmostApplication
        // 本物の設定を汚さないよう、テスト用の保存先に差し替えて空にしておく
        let suite = "SideWindowSelfTest"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        Preferences.store = UserDefaults(suiteName: suite)!
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        makeWindows()
        await sleep(0.8)

        do {
            await testWelcomeWindow()
            try await pinSource()
            await testCapture()
            await testMove()
            await testResize()
            await testButtonsOnlyWhenHovering()
            await testChromeFadesWhenIdle()
            await testHoverMakesOpaque()
            await testZoom()
            await testPan()
            await testReselectAndCancel()
            await testShowAll()
            await testQuality()
            await testHideAllAndHighlight()
            await testStatusMenu()
            await testNoJapaneseInEnglish()
            await testClickThroughEscape()
            await testClickDoesNotStealKeyboard()
            await testAutoHide()
            await testMinimize()
            await testInactiveTab()
            await testCursorInBackground()
            await testSourceClosed()
        } catch {
            record("setup", false, "\(error)")
        }

        print("")
        for result in results {
            print("\(result.passed ? "✔" : "✘") \(result.name)\(result.detail.isEmpty ? "" : " — \(result.detail)")")
        }
        for item in skipped {
            print("– \(item.name)（確認できず：\(item.reason)）")
        }
        let failed = results.filter { !$0.passed }.count
        print("\n\(results.count - failed)/\(results.count) passed" + (skipped.isEmpty ? "" : "（確認できず \(skipped.count) 件）"))
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: - 準備

    private func makeWindows() {
        let visible = NSScreen.main!.visibleFrame
        source = NSWindow(contentRect: NSRect(x: visible.minX + 80, y: visible.minY + 120, width: 640, height: 400),
                          styleMask: [.titled, .miniaturizable, .closable, .resizable], backing: .buffered, defer: false)
        source.title = "テスト用の資料"
        source.isReleasedWhenClosed = false
        source.contentView = QuadrantView()
        source.makeKeyAndOrderFront(nil)

        other = NSWindow(contentRect: NSRect(x: visible.minX + 200, y: visible.minY + 60, width: 360, height: 240),
                         styleMask: [.titled], backing: .buffered, defer: false)
        other.title = "書いているレポート"
        other.isReleasedWhenClosed = false
        other.contentView = NSTextView()
        other.orderFront(nil)
    }

    private func pinSource() async throws {
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(source.windowNumber) }) else {
            throw NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "テスト用ウィンドウが見つからない"])
        }
        pin = PinController(filter: SCContentFilter(desktopIndependentWindow: window), index: 0)
        pin.onClose = { [weak self] _ in self?.pinClosed = true }
        pin.start()
        let startFrame = pin.panel.frame
        await sleep(1.0)
        record("パネルは元のウィンドウの場所から現れる", abs(startFrame.minX - source.frame.minX) < 1
                   && abs(startFrame.width - source.frame.width) < 1, "\(startFrame) / 元 \(source.frame)")
        let visible = pin.panel.screen!.visibleFrame
        record("飛んできて画面の右上に収まる", pin.panel.frame == pin.settledFrame
                   && abs(pin.panel.frame.maxX - (visible.maxX - 16)) < 1 && pin.panel.alphaValue > 0.99,
               "\(pin.panel.frame)")
        record("収まったら操作バーを少し見せる（ボタンの場所が分かるように）", pin.mirror.isChromeVisible, "")
    }

    private func testWelcomeWindow() async {
        let welcome = WelcomeWindowController()
        welcome.show()
        await sleep(0.6)
        let window = NSApp.windows.first { $0.title == L("SideWindow の使い方") }
        record("初回の案内ウィンドウが開く", window?.isVisible == true, "")
        if let window { await snapshot(window: window, name: "0-welcome") }
        window?.orderOut(nil)
    }

    // MARK: - テスト

    private func testCapture() async {
        let before = pin.framesShown
        await sleep(0.6)
        let after = pin.framesShown
        record("映像が届き続ける", pin.framesShown > 0 && after > before, "frames \(before) → \(after)")
        await snapshot("1-full")
        let colors = await quadrantColors()
        record("全体表示で四隅の色が正しい", colors == ["red", "green", "blue", "yellow"], "\(colors)")
    }

    private func testMove() async {
        let panel = pin.panel
        let start = panel.frame
        let from = NSPoint(x: start.midX, y: start.midY - 30)
        drag(from: from, to: NSPoint(x: from.x - 240, y: from.y - 120))
        await sleep(0.2)
        let moved = panel.frame.origin
        let expected = NSPoint(x: start.minX - 240, y: start.minY - 120)
        record("1 回目のクリックで移動できる", abs(moved.x - expected.x) < 1 && abs(moved.y - expected.y) < 1,
               "origin \(start.origin) → \(moved)")

        // 画面の端の近くで離すと吸い付く
        let visible = panel.screen!.visibleFrame
        let now = panel.frame
        let target = NSPoint(x: visible.maxX - 8 - now.width - 6, y: now.minY)
        drag(from: NSPoint(x: now.midX, y: now.midY - 30),
             to: NSPoint(x: now.midX + (target.x - now.minX), y: now.midY - 30))
        await sleep(0.2)
        record("画面の端に吸い付く", abs(panel.frame.maxX - (visible.maxX - 8)) < 1, "maxX \(panel.frame.maxX)")
        record("動かした場所を次のパネルの置き場所として覚える", Preferences.lastPanelFrame == panel.frame,
               "\(String(describing: Preferences.lastPanelFrame))")
        // 元の場所あたりに戻す
        panel.setFrame(start.offsetBy(dx: -300, dy: -150), display: true)
    }

    private func testResize() async {
        let panel = pin.panel
        let start = panel.frame
        let ratio = start.width / start.height
        drag(from: NSPoint(x: start.maxX - 3, y: start.minY + 3), to: NSPoint(x: start.maxX + 97, y: start.minY + 3))
        await sleep(0.2)
        let frame = panel.frame
        record("右下の角でリサイズできる", abs(frame.width - (start.width + 100)) < 1, "width \(start.width) → \(frame.width)")
        record("リサイズしても縦横比が保たれる", abs(frame.width / frame.height - ratio) < 0.01, "")
        record("リサイズ中は左上が動かない", abs(frame.minX - start.minX) < 1 && abs(frame.maxY - start.maxY) < 1, "")

        let before = panel.frame
        drag(from: NSPoint(x: before.minX + 2, y: before.midY), to: NSPoint(x: before.minX + 62, y: before.midY))
        await sleep(0.2)
        record("左辺でリサイズできる（右辺は固定）",
               abs(panel.frame.width - (before.width - 60)) < 1 && abs(panel.frame.maxX - before.maxX) < 1,
               "width \(before.width) → \(panel.frame.width)")
    }

    private func testButtonsOnlyWhenHovering() async {
        let mirror = pin.mirror
        let point = zoomButtonPoint()
        let local = mirror.convert(pin.panel.convertPoint(fromScreen: point), from: nil)
        mirror.mouseExited(with: mouseEvent(.mouseMoved, at: point))
        record("ホバーしていないとボタンは押せない（見えないボタンの誤操作防止）",
               !(mirror.hitTest(mirror.convert(local, to: mirror.superview)) is BarButton), "")
        mirror.mouseEntered(with: mouseEvent(.mouseMoved, at: point))
        await sleep(0.3)
        record("ホバー中はボタンを押せる", mirror.hitTest(mirror.convert(local, to: mirror.superview)) is BarButton, "")
        record("ボタンの上ではポインタが指の形になる", mirror.cursor(at: local) == .pointingHand, "")
        let body = NSPoint(x: mirror.bounds.midX, y: mirror.bounds.midY)
        record("パネルの中ほどでは普通の矢印", mirror.cursor(at: body) == .arrow, "")
        record("端ではリサイズの形", mirror.cursor(at: NSPoint(x: 2, y: mirror.bounds.midY)) != .arrow
                   && mirror.cursor(at: NSPoint(x: 2, y: mirror.bounds.midY)) != .pointingHand, "")
    }

    private func testChromeFadesWhenIdle() async {
        let mirror = pin.mirror
        mirror.mouseEntered(with: mouseEvent(.mouseMoved, at: .zero))
        record("マウスを乗せると操作バーが出る", mirror.isChromeVisible, "")
        await sleep(2.6)
        record("マウスを止めて 2 秒ほどたつと操作バーが消える（資料の上端を隠し続けない）", !mirror.isChromeVisible, "")
        mirror.mouseMoved(with: mouseEvent(.mouseMoved, at: NSPoint(x: pin.panel.frame.midX, y: pin.panel.frame.midY),
                                           window: pin.panel))
        record("動かすとまた出る", mirror.isChromeVisible, "")
        let titles = pin.makeMenu().items.map(\.title)
        record("「•••」ボタンからすべての操作を選べる", findButton(tip: L("その他の操作")) != nil
                   && ["元のウィンドウを開く", "範囲を選んで拡大", "サイズ", "不透明度", "クリックを透過", "固定を解除"]
                       .map(L).allSatisfy(titles.contains), "\(titles)")
    }

    private func testHoverMakesOpaque() async {
        let mirror = pin.mirror
        // 本物のマウスがパネルの上にあると「乗せた」扱いになるので、重ならない場所で試す
        if pin.panel.frame.insetBy(dx: -40, dy: -40).contains(NSEvent.mouseLocation) {
            let visible = pin.panel.screen!.visibleFrame
            let x = NSEvent.mouseLocation.x > visible.midX ? visible.minX + 20 : visible.maxX - pin.panel.frame.width - 20
            pin.panel.setFrameOrigin(NSPoint(x: x, y: pin.panel.frame.minY))
        }
        mirror.mouseExited(with: mouseEvent(.mouseMoved, at: .zero))
        pin.applyOpacity(0.5)
        await sleep(1.6)
        record("半透明にできる", abs(pin.panel.alphaValue - 0.5) < 0.02, "alpha \(pin.panel.alphaValue)")
        mirror.mouseEntered(with: mouseEvent(.mouseMoved, at: .zero))
        await sleep(0.4)
        record("半透明でも、マウスを乗せると不透明になる（読みやすく）", pin.panel.alphaValue > 0.98, "alpha \(pin.panel.alphaValue)")
        mirror.mouseExited(with: mouseEvent(.mouseMoved, at: .zero))
        await sleep(0.4)
        record("マウスを外すと半透明に戻る", abs(pin.panel.alphaValue - 0.5) < 0.02, "alpha \(pin.panel.alphaValue)")
        pin.applyOpacity(1)
        await sleep(1.4)
        mirror.mouseEntered(with: mouseEvent(.mouseMoved, at: .zero))
    }

    private func testPan() async {
        guard let before = pin.zoom else {
            record("拡大中はスクロールで位置を動かせる", false, "拡大されていない")
            return
        }
        // 右へスクロール（中身が右へ動く）→ 映す範囲は左へ。緑の左にある赤が見えてくる
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                             wheel1: 0, wheel2: Int32(pin.mirror.bounds.width * 0.5), wheel3: 0)!
        scroll.location = CGPoint(x: pin.panel.frame.midX, y: NSScreen.screens[0].frame.height - pin.panel.frame.midY)
        if let event = NSEvent(cgEvent: scroll) { pin.mirror.scrollWheel(with: event) }
        await sleep(0.1)
        let moved = pin.zoom ?? .zero
        record("拡大中はスクロールで映す位置が動く", moved.minX < before.minX - 50 && moved.size == before.size,
               "\(before) → \(moved)")
        await sleep(0.8)
        await snapshot("3b-panned")
        let colors = await quadrantColors()
        record("動かした先が正しく映る（左に赤・右に緑）", colors[0] == "red" && colors[1] == "green", "\(colors)")
        // 元の位置に戻しておく
        pin.pan(by: CGVector(dx: -(before.minX - moved.minX) * pin.mirror.bounds.width / before.width, dy: 0))
        await sleep(0.8)
    }

    private func testZoom() async {
        let panel = pin.panel
        let frameBefore = panel.frame
        await hoverAndClickZoom()
        await sleep(0.2)
        record("拡大ボタンで範囲選択が始まる", pin.mirror.isSelecting, "")
        await snapshot("2-selecting")

        // 右上 1/4（緑）を選ぶ
        let bounds = pin.mirror.bounds
        let from = panel.convertPoint(toScreen: NSPoint(x: bounds.width * 0.55, y: bounds.height * 0.95))
        let to = panel.convertPoint(toScreen: NSPoint(x: bounds.width * 0.95, y: bounds.height * 0.55))
        drag(from: from, to: to)
        await sleep(0.8)
        let zoom = pin.zoom ?? .zero
        record("選んだ範囲が拡大される", !pin.mirror.isSelecting && zoom.minX > 320 && zoom.maxY < 200, "zoom \(zoom)")
        let frame = panel.frame
        record("拡大してもパネルの大きさはほぼ変わらない",
               max(frame.width, frame.height) >= min(frameBefore.width, frameBefore.height) * 0.9, "\(frameBefore.size) → \(frame.size)")
        record("拡大後はキー入力を返す", !panel.isKeyWindow, "")
        await snapshot("3-zoomed")
        let colors = await quadrantColors()
        record("拡大後は緑の範囲だけが映る", Set(colors) == ["green"], "\(colors)")
    }

    private func testReselectAndCancel() async {
        let panel = pin.panel
        let zoomBefore = pin.zoom ?? .zero
        // 拡大後にパネルを小さくしておく（選び直しで元の大きさに戻らないことを確かめる）
        let shrunk = panel.frame
        panel.setFrame(NSRect(x: shrunk.minX, y: shrunk.maxY - shrunk.height * 0.6,
                              width: shrunk.width * 0.6, height: shrunk.height * 0.6), display: true)
        let frameBefore = panel.frame

        // 拡大中にもう一度押すと、いま映している範囲からさらに拡大する
        await hoverAndClickZoom()
        record("拡大中に押すと、いまの拡大のまま範囲選択が始まる", pin.zoom == zoomBefore && pin.mirror.isSelecting, "")
        record("拡大中は「全体から選ぶ」ボタンが出る", findHintButton()?.isHidden == false, "")
        if let button = findHintButton() {
            let point = pin.mirror.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
            record("「全体から選ぶ」の上では指の形、ほかは十字", pin.mirror.cursor(at: point) == .pointingHand
                       && pin.mirror.cursor(at: NSPoint(x: pin.mirror.bounds.midX, y: pin.mirror.bounds.midY)) == .crosshair, "")
        }
        await snapshot("4-nested-selecting")
        let bounds = pin.mirror.bounds
        drag(from: panel.convertPoint(toScreen: NSPoint(x: bounds.width * 0.05, y: bounds.height * 0.95)),
             to: panel.convertPoint(toScreen: NSPoint(x: bounds.width * 0.5, y: bounds.height * 0.4)))
        await sleep(0.8)
        let nested = pin.zoom ?? .zero
        record("拡大したところからさらに拡大できる",
               zoomBefore.contains(nested) && nested.width < zoomBefore.width * 0.6, "\(zoomBefore) → \(nested)")
        record("さらに拡大してもパネルの面積は変えない", sameArea(panel.frame, frameBefore),
               "\(frameBefore.size) → \(panel.frame.size)")

        pin.zoomBack()
        await sleep(0.8)
        record("「拡大をひとつ戻す」で前の拡大に戻る", pin.zoom == zoomBefore, "zoom \(String(describing: pin.zoom))")

        // 「全体から選ぶ」で、パネルの大きさはそのままで全体から選び直せる
        let frameBeforeWhole = panel.frame
        await hoverAndClickZoom()
        if let button = findHintButton() {
            click(at: button.window!.convertPoint(toScreen: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)))
        }
        await sleep(0.8)
        record("「全体から選ぶ」で全体が映る", pin.zoom == nil && pin.mirror.isSelecting, "zoom \(String(describing: pin.zoom))")
        record("「全体から選ぶ」でもパネルの面積を変えない", sameArea(panel.frame, frameBeforeWhole),
               "\(frameBeforeWhole.size) → \(panel.frame.size)")
        record("拡大・戻す・選び直しを繰り返してもパネルが縮まない", sameArea(panel.frame, frameBefore),
               "\(frameBefore.size) → \(panel.frame.size)")
        await snapshot("5-reselecting")
        let colors = await quadrantColors()
        record("選び直すときは全体が映る", colors == ["red", "green", "blue", "yellow"], "\(colors)")

        pin.mirror.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        await sleep(0.8)
        record("Esc で取り消すと直前の拡大に戻る", pin.zoom == zoomBefore && !pin.mirror.isSelecting, "")
        record("Esc で取り消すとパネルの位置と大きさも戻る",
               abs(panel.frame.width - frameBeforeWhole.width) < 1 && abs(panel.frame.minX - frameBeforeWhole.minX) < 1, "")
    }

    private func testQuality() async {
        let panel = pin.panel
        let scale = panel.backingScaleFactor
        // パネルが元より小さいときは、パネルの画素数で取り込む
        pin.showAll()
        await sleep(0.8)
        let small = pin.captureSize
        record("縮小表示ではパネルの画素数で取り込む（画面側で縮めない）",
               small.width <= panel.frame.width * scale + 1 && small.width < 640 * scale,
               "capture \(small) / panel \(panel.frame.size)")

        // 赤と緑の境目を 3.5 倍ほどに拡大して、境目のくっきり具合を比べる
        let region = CGRect(x: 280, y: 40, width: 80, height: 60)
        pin.zoom(to: region, previous: nil)
        await sleep(1.0)
        // 元のウィンドウがある画面の細かさが上限（Retina の画面なら 2 倍）
        let nativeScale = source.backingScaleFactor
        let expectedArea = Geometry.captureArea(for: region, windowSize: source.frame.size)
        record("拡大表示では元の画素数で取り込む（周りの余白込み）",
               abs(pin.captureSize.width - expectedArea.width * nativeScale) < 2,
               "capture \(pin.captureSize) / 範囲 \(expectedArea) × \(nativeScale)")
        pin.sharpensZoom = false
        await sleep(0.8)
        let plain = await edgeSteepness()
        await snapshot("6-zoom-plain")
        pin.sharpensZoom = true
        await sleep(0.8)
        let sharp = await edgeSteepness()
        await snapshot("6-zoom-sharpened")
        record("拡大表示がくっきりする（境目の傾き 補正なし→あり）", sharp > plain * 1.3,
               String(format: "%.3f → %.3f", plain, sharp))
        pin.showAll()
        await sleep(0.8)
    }

    private func testShowAll() async {
        pin.showAll()
        await sleep(0.8)
        let size = pin.panel.frame.size
        let expected = pin.fullViewSize ?? .zero
        record("「全体を表示」で拡大前の大きさに戻る",
               pin.zoom == nil && abs(size.width - expected.width) < 2 && abs(size.height - expected.height) < 2,
               "\(size) / 期待 \(expected)")
        let colors = await quadrantColors()
        record("「全体を表示」で全体が映る", colors == ["red", "green", "blue", "yellow"], "\(colors)")
    }

    private func testHideAllAndHighlight() async {
        pin.setHiddenByUser(true)
        await sleep(0.5)
        record("「すべて隠す」で隠れる", !pin.panel.isVisible, "")
        pin.setHighlighted(true)
        await sleep(0.3)
        record("隠していても、メニューで指したパネルは枠を光らせて見せる", pin.panel.isVisible && pin.mirror.isHighlighted
                   && pin.panel.alphaValue > 0.98, "")
        pin.setHighlighted(false)
        await sleep(0.3)
        record("指すのをやめると隠れたまま", !pin.panel.isVisible && !pin.mirror.isHighlighted, "")
        pin.setHiddenByUser(false)
        await sleep(0.5)
        record("「すべて表示」で戻る", pin.panel.isVisible && pin.panel.alphaValue > 0.98, "")
    }

    private func testStatusMenu() async {
        let delegate = AppDelegate()
        delegate.pins = [pin]
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let titles = menu.items.map(\.title)
        let expected = ["ウィンドウを固定…", "固定中", "すべて隠す", "すべての固定を解除", "ログイン時に起動", "使い方",
                        "SideWindow について", "SideWindow を終了"].map(L)
        record("メニューバーのメニューに必要な項目がそろっている", expected.allSatisfy(titles.contains), "\(titles)")
        let first = menu.items.first
        record("「ウィンドウを固定…」にショートカット ⌃⌥P が出る",
               first?.keyEquivalent == "p" && first?.keyEquivalentModifierMask == [.control, .option], "")
        let row = menu.items.first { ($0.representedObject as AnyObject?) === pin }
        record("固定中のウィンドウはアプリのアイコンと操作のサブメニュー付きで並ぶ",
               row?.image != nil && row?.submenu?.items.contains { $0.title == L("固定を解除") } == true, "")
        delegate.menu(menu, willHighlight: row)
        await sleep(0.2)
        record("メニューで指したパネルの枠が光る", pin.mirror.isHighlighted, "")
        delegate.menuDidClose(menu)
        record("メニューを閉じると元に戻る", !pin.mirror.isHighlighted, "")
    }

    /// 英語の環境で動かしたとき、画面に出る文字に日本語（訳し忘れ）が残っていないか
    private func testNoJapaneseInEnglish() async {
        guard !Localization.usesJapanese else { return }
        var texts: [String] = []
        func collect(_ menu: NSMenu) {
            for item in menu.items {
                texts.append(item.title)
                if let subtitle = item.subtitle { texts.append(subtitle) }
                if let submenu = item.submenu { collect(submenu) }
            }
        }
        func collect(_ view: NSView) {
            if let button = view as? NSButton { texts += [button.title, button.toolTip ?? ""] }
            if let field = view as? NSTextField { texts.append(field.stringValue) }
            view.subviews.forEach(collect)
        }
        collect(pin.makeMenu())
        let delegate = AppDelegate()
        delegate.pins = [pin]
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        collect(menu)
        collect(pin.mirror)
        for notice in [MirrorView.Notice.minimized, .minimizedNeedsAccessibility, .appHidden, .inactiveTab, .unavailable] {
            texts += [notice.title, notice.detail, notice.actionTitle ?? ""]
        }
        texts += ["範囲をドラッグ ・ Esc で取り消し", "全体から選び直す", "さらに拡大", "拡大をひとつ戻す", "全体を表示",
                  "すべて表示", "固定中のウィンドウはありません", "クリック透過中", "ウィンドウ %d"].map(L)
        let welcome = WelcomeWindowController()
        welcome.show()
        await sleep(0.4)
        if let window = NSApp.windows.first(where: { $0.title == L("SideWindow の使い方") }), let content = window.contentView {
            texts.append(window.title)
            collect(content)
            window.orderOut(nil)
        } else {
            texts.append("案内ウィンドウが見つからない")
        }
        // 案内を閉じたあと元のウィンドウが手前に来るとパネルが自動で隠れるので、書いているレポートを手前に戻す
        bringToFront(other)
        await sleep(0.6)
        // 固定したウィンドウ自身の題名（ここではテスト用ウィンドウの日本語の題名）は訳す対象ではない
        let sourceTitles: Set<String> = [pin.title, pin.mirror.title]
        let japanese = texts.filter { text in
            !sourceTitles.contains(text) && !text.contains(pin.mirror.title) && text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
        }
        record("英語の環境では画面の文字がすべて英語になる（訳し忘れがない）", japanese.isEmpty && texts.count > 40,
               japanese.isEmpty ? "\(texts.count) 件" : japanese.joined(separator: " / "))
    }

    private func testClickThroughEscape() async {
        var command = false
        var mouse = NSPoint(x: pin.panel.frame.midX, y: pin.panel.frame.midY)
        pin.modifierFlags = { command ? .command : [] }
        pin.mouseLocation = { mouse }
        pin.toggleClickThrough()
        await sleep(0.3)
        record("クリックを透過すると下のウィンドウを操作できる", pin.panel.ignoresMouseEvents, "")
        record("透過中はマウスを乗せると案内が出る", !pin.mirror.showsPassThroughHintHidden, "")
        command = true
        await sleep(0.3)
        record("透過中でも ⌘ を押しているあいだはパネルを操作できる（抜け出せなくならない）", !pin.panel.ignoresMouseEvents, "")
        command = false
        await sleep(0.3)
        record("⌘ を離すと透過に戻る", pin.panel.ignoresMouseEvents, "")
        mouse = NSPoint(x: pin.panel.frame.maxX + 200, y: pin.panel.frame.midY)
        await sleep(0.3)
        record("マウスが外に出たら案内を消す", pin.mirror.showsPassThroughHintHidden, "")
        pin.toggleClickThrough()
        pin.modifierFlags = { NSEvent.modifierFlags }
        pin.mouseLocation = { NSEvent.mouseLocation }
        record("透過をやめると普通に戻る", !pin.panel.ignoresMouseEvents, "")
    }

    private func testClickDoesNotStealKeyboard() async {
        bringToFront(other)
        await sleep(0.3)
        let keyBefore = NSApp.keyWindow
        let frame = pin.panel.frame
        click(at: NSPoint(x: frame.midX, y: frame.midY - 20))
        await sleep(0.2)
        record("パネルをクリックしても書いている文書のキー入力を奪わない",
               !pin.panel.isKeyWindow && NSApp.keyWindow === keyBefore,
               "key: \(keyBefore?.title ?? "nil") → \(NSApp.keyWindow?.title ?? "nil")")
    }

    private func testAutoHide() async {
        bringToFront(other)
        await sleep(0.8)
        record("ほかのウィンドウが手前のときは表示", pin.panel.alphaValue > 0.9, "alpha \(pin.panel.alphaValue)")
        bringToFront(source)
        await sleep(0.8)
        record("元のウィンドウが手前に来たら隠れる", pin.panel.alphaValue < 0.05 && pin.panel.ignoresMouseEvents,
               "alpha \(pin.panel.alphaValue) front=\(Self.frontWindowDescription()) source=\(source.windowNumber)")
        bringToFront(other)
        await sleep(0.8)
        record("ほかのウィンドウに戻ると再表示", pin.panel.alphaValue > 0.9 && !pin.panel.ignoresMouseEvents,
               "alpha \(pin.panel.alphaValue)")
    }

    private func testMinimize() async {
        source.miniaturize(nil)
        await sleep(2.0)
        record("最小化しても固定が外れない", !pinClosed, "")
        record("最小化中は案内を表示する", pin.mirror.notice == .minimized, "notice \(String(describing: pin.mirror.notice))")
        record("最小化中は「クリックで元に戻す」ので指の形",
               pin.mirror.cursor(at: NSPoint(x: pin.mirror.bounds.midX, y: pin.mirror.bounds.midY)) == .pointingHand, "")
        await snapshot("7-minimized")
        pin.openSource()
        await sleep(2.0)
        record("元に戻らなかったら、アクセシビリティの許可を案内する", pin.mirror.notice == .minimizedNeedsAccessibility,
               "notice \(String(describing: pin.mirror.notice))")
        if let button = findHintButton(title: L("許可する…")) {
            let point = pin.mirror.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
            record("案内から「許可する…」を押せる", !button.isHiddenOrHasHiddenAncestor
                       && pin.mirror.hitTest(pin.mirror.convert(point, to: pin.mirror.superview)) === button
                       && pin.mirror.cursor(at: point) == .pointingHand, "")
        } else {
            record("案内から「許可する…」を押せる", false, "ボタンが見つからない")
        }
        await snapshot("8-minimized-needs-access")

        source.deminiaturize(nil)
        bringToFront(other)
        await sleep(2.0)
        let before = pin.framesShown
        await sleep(1.0)
        record("元に戻すと案内が消える", pin.mirror.notice == nil, "notice \(String(describing: pin.mirror.notice))")
        record("元に戻すと映像が再開する", pin.framesShown > before, "frames \(before) → \(pin.framesShown)")
        await snapshot("9-restored")
    }

    /// 固定したウィンドウに別のタブを足して切り替える（Finder やプレビューのタブと同じ）
    private func testInactiveTab() async {
        source.tabbingMode = .preferred
        let partner = NSWindow(contentRect: source.contentLayoutRect, styleMask: source.styleMask, backing: .buffered, defer: false)
        partner.title = "別のタブ"
        partner.isReleasedWhenClosed = false
        partner.tabbingMode = .preferred
        source.addTabbedWindow(partner, ordered: .above)
        bringToFront(partner)
        await sleep(1.6)
        record("別のタブに切り替えても固定は外れない", !pinClosed, "")
        record("別のタブに切り替えたら「別のタブが表示されています」と案内する", pin.mirror.notice == .inactiveTab,
               "notice \(String(describing: pin.mirror.notice))")
        await snapshot("9b-inactive-tab")
        bringToFront(source)
        await sleep(1.0)
        let before = pin.framesShown
        await sleep(1.0)
        record("タブを戻すと案内が消えて映像が再開する", pin.mirror.notice == nil && pin.framesShown > before,
               "notice \(String(describing: pin.mirror.notice)) frames \(before) → \(pin.framesShown)")
        partner.close()
        bringToFront(other)
        await sleep(0.8)
    }

    /// 実際の SideWindow と同じく、アプリが背面にいる状態で画面のポインタが変わるか
    private func testCursorInBackground() async {
        guard let previous = frontAppAtStart, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let url = previous.bundleURL else {
            record("背面にいてもボタンの上でポインタが指の形になる", false, "前面に戻すアプリがない")
            return
        }
        let mirror = pin.mirror
        let button = findButton(tip: L("範囲を選んで拡大"))!
        // 実際の使い方と同じく「マウスがパネルの上にある」状態にしてから背面に回る。
        // （背面に回ったあとで、止まっているマウスの下にパネルを動かしても、macOS はマウスの下のウィンドウを更新しない）
        moveSoMouseIsOver(button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
        await sleep(0.3)
        NSApp.yieldActivation(to: previous)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        await sleep(1.0)
        guard !NSApp.isActive else {
            record("背面にいてもボタンの上でポインタが指の形になる", false, "テストアプリが背面に回らなかった")
            return
        }
        mirror.mouseEntered(with: mouseEvent(.mouseMoved, at: NSEvent.mouseLocation, window: pin.panel))
        mirror.showChrome(for: 5)
        // ボタンの上（本物のマウスの位置）→ パネルの中ほど の順に動きを送り、そのたびに画面のポインタを確かめる
        var onButton: NSPoint?
        var onBody: NSPoint?
        let body = pin.panel.convertPoint(toScreen: mirror.convert(NSPoint(x: mirror.bounds.midX, y: mirror.bounds.midY * 0.8), to: nil))
        for _ in 0..<3 {
            mirror.mouseMoved(with: mouseEvent(.mouseMoved, at: NSEvent.mouseLocation, window: pin.panel))
            await sleep(0.05)
            onButton = NSCursor.currentSystem?.hotSpot
            mirror.mouseMoved(with: mouseEvent(.mouseMoved, at: body, window: pin.panel))
            await sleep(0.05)
            onBody = NSCursor.currentSystem?.hotSpot
            if onButton == NSCursor.pointingHand.hotSpot && onBody == NSCursor.arrow.hotSpot { break }
            await sleep(0.3)
        }
        let state = "ignores=\(pin.panel.ignoresMouseEvents) alpha=\(pin.panel.alphaValue) hidden=\(pin.isHiddenForSource) "
            + "mouseInside=\(pin.panel.frame.contains(NSEvent.mouseLocation)) active=\(NSApp.isActive)"
        let passed = onButton == NSCursor.pointingHand.hotSpot && onBody == NSCursor.arrow.hotSpot
        // テスト中に本物のマウスがパネルの外へ動くと、画面のポインタはその下のアプリのものになるので確かめられない
        if !passed, !pin.panel.frame.contains(NSEvent.mouseLocation) {
            skipped.append(("背面にいてもボタンの上でポインタが指の形になる", "テスト中に本物のマウスがパネルの外へ動いた"))
            return
        }
        record("背面にいてもボタンの上でポインタが指の形になる（画面のポインタで確認）",
               passed,
               "ボタン上 \(String(describing: onButton)) / 中ほど \(String(describing: onBody)) / "
                   + "front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "") / \(state)")
    }

    /// パネルの windowPoint（ウィンドウ座標）が本物のマウスの真下に来るよう動かす
    private func moveSoMouseIsOver(_ windowPoint: NSPoint) {
        let mouse = NSEvent.mouseLocation
        let current = pin.panel.convertPoint(toScreen: windowPoint)
        pin.panel.setFrameOrigin(NSPoint(x: pin.panel.frame.minX + mouse.x - current.x,
                                         y: pin.panel.frame.minY + mouse.y - current.y))
        // 動かしただけでは、止まっているマウスの下のウィンドウが更新されないことがあるので、手前に出し直す
        pin.panel.orderFrontRegardless()
    }

    private func testSourceClosed() async {
        // 実際のアプリと同じように、閉じたウィンドウを破棄する
        let id = CGWindowID(source.windowNumber)
        source.close()
        source = nil
        // デスクトップ切り替え中の誤判定を避けるため、約 1.2 秒続いてから外す
        await sleep(2.0)
        record("元のウィンドウを閉じると固定が外れる", pinClosed,
               "presence \(SourceWindow.presence(of: id, processID: ProcessInfo.processInfo.processIdentifier))")
    }

    // MARK: - 操作の再現

    private func mouseEvent(_ type: NSEvent.EventType, at screenPoint: NSPoint, window: NSWindow? = nil,
                            clickCount: Int = 1) -> NSEvent {
        let location = window.map { $0.convertPoint(fromScreen: screenPoint) } ?? screenPoint
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                  clickCount: clickCount, pressure: 1)!
    }

    /// パネル上でマウスを押してドラッグし、離す。押すまえに移動・離すイベントを積んでおく
    private func drag(from: NSPoint, to: NSPoint, steps: Int = 8) {
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let point = NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            NSApp.postEvent(mouseEvent(.leftMouseDragged, at: point), atStart: false)
        }
        NSApp.postEvent(mouseEvent(.leftMouseUp, at: to), atStart: false)
        pin.panel.sendEvent(mouseEvent(.leftMouseDown, at: from, window: pin.panel))
    }

    private func click(at point: NSPoint) {
        NSApp.postEvent(mouseEvent(.leftMouseUp, at: point, window: pin.panel), atStart: false)
        pin.panel.sendEvent(mouseEvent(.leftMouseDown, at: point, window: pin.panel))
    }

    private func zoomButtonPoint() -> NSPoint {
        let button = findButton(tip: L("範囲を選んで拡大"))!
        return button.window!.convertPoint(toScreen: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
    }

    private func clickZoomButton() {
        click(at: zoomButtonPoint())
    }

    private func hoverAndClickZoom() async {
        pin.mirror.mouseEntered(with: mouseEvent(.mouseMoved, at: .zero))
        await sleep(0.3)
        clickZoomButton()
        await sleep(0.5)
    }

    private func sameArea(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.width * a.height - b.width * b.height) <= b.width * b.height * 0.03
    }

    private func findHintButton(title: String = L("全体から選ぶ")) -> HintButton? {
        func search(_ view: NSView) -> HintButton? {
            if let button = view as? HintButton, button.title == title { return button }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        return search(pin.mirror)
    }

    private func findButton(tip: String) -> BarButton? {
        func search(_ view: NSView) -> BarButton? {
            if let button = view as? BarButton, button.toolTip == tip { return button }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        return search(pin.mirror)
    }

    // MARK: - 見た目の確認

    private func capturePanel() async -> CGImage? {
        guard let content = try? await SCShareableContent.currentProcess,
              let window = content.windows.first(where: { $0.windowID == CGWindowID(pin.panel.windowNumber) })
        else { return nil }
        let config = SCStreamConfiguration()
        let scale = pin.panel.backingScaleFactor
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                           configuration: config)
    }

    private func snapshot(window: NSWindow, name: String) async {
        guard let content = try? await SCShareableContent.currentProcess,
              let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return }
        let config = SCStreamConfiguration()
        config.width = Int(scWindow.frame.width * window.backingScaleFactor)
        config.height = Int(scWindow.frame.height * window.backingScaleFactor)
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: config) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }

    private func snapshot(_ name: String) async {
        guard let image = await capturePanel() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }

    /// 隣り合う画素の赤の差の最大値（境目がくっきりしているほど大きい）。3 行で測って中央値を返す
    private func edgeSteepness() async -> Double {
        guard let image = await capturePanel() else { return 0 }
        let rep = NSBitmapImageRep(cgImage: image)
        let rows = [0.35, 0.55, 0.75].map { Int(Double(rep.pixelsHigh) * $0) }
        let values = rows.map { y -> Double in
            var previous: Double?
            var steepest = 0.0
            for x in 0..<rep.pixelsWide {
                guard let red = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.redComponent else { continue }
                if let previous { steepest = max(steepest, abs(Double(red) - previous)) }
                previous = Double(red)
            }
            return steepest
        }.sorted()
        return values[1]
    }

    /// パネルの四隅寄りの色（左上・右上・左下・右下）
    private func quadrantColors() async -> [String] {
        guard let image = await capturePanel() else { return ["capture failed"] }
        let rep = NSBitmapImageRep(cgImage: image)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        // 上端は操作バーがあるので少し内側を見る
        let points = [(0.2, 0.35), (0.8, 0.35), (0.2, 0.8), (0.8, 0.8)]
        return points.map { px, py in
            guard let color = rep.colorAt(x: Int(Double(w) * px), y: Int(Double(h) * py))?.usingColorSpace(.sRGB)
            else { return "?" }
            return QuadrantView.name(of: color)
        }
    }

    /// テスト用アプリを前面に出して、そのウィンドウをいちばん手前にする
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func frontWindowDescription() -> String {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.prefix(3).map { info in
            "\(info[kCGWindowOwnerName as String] ?? "?"):\(info[kCGWindowNumber as String] ?? "?")/L\(info[kCGWindowLayer as String] ?? "?")/a\(info[kCGWindowAlpha as String] ?? "?")"
        }.joined(separator: ", ")
    }

    // MARK: - 結果

    private func record(_ name: String, _ passed: Bool, _ detail: String) {
        results.append((name, passed, detail))
        print("\(passed ? "✔" : "✘") \(name)")
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// 四色に塗り分け、中央で数字が動き続けるテスト用の中身
private final class QuadrantView: NSView {
    private var counter = 0
    private var timer: Timer?

    static let colors: [(String, NSColor)] = [
        ("red", NSColor(srgbRed: 0.9, green: 0.15, blue: 0.15, alpha: 1)),
        ("green", NSColor(srgbRed: 0.15, green: 0.75, blue: 0.2, alpha: 1)),
        ("blue", NSColor(srgbRed: 0.15, green: 0.3, blue: 0.9, alpha: 1)),
        ("yellow", NSColor(srgbRed: 0.95, green: 0.85, blue: 0.1, alpha: 1)),
    ]

    static func name(of color: NSColor) -> String {
        colors.min { a, b in distance(a.1, color) < distance(b.1, color) }.map { distance($0.1, color) < 0.6 ? $0.0 : "other" } ?? "?"
    }

    private static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let a = a.usingColorSpace(.sRGB)!
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.counter += 1
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width / 2, h = bounds.height / 2
        let rects = [NSRect(x: 0, y: h, width: w, height: h), NSRect(x: w, y: h, width: w, height: h),
                     NSRect(x: 0, y: 0, width: w, height: h), NSRect(x: w, y: 0, width: w, height: h)]
        for (rect, (_, color)) in zip(rects, Self.colors) {
            color.setFill()
            rect.fill()
        }
        let text = "\(counter)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 28), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}
