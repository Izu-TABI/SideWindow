import AppKit
import ScreenCaptureKit

/// 固定したウィンドウ 1 つ分。キャプチャを流して最前面パネルに映す
final class PinController: NSObject, SCStreamOutput, SCStreamDelegate {
    static let opacityLevels: [CGFloat] = [1, 0.85, 0.7, 0.5, 0.3]
    static let sizeLevels: [CGFloat] = [0.25, 0.5, 0.75, 1]

    let title: String
    let appIcon: NSImage?
    var onClose: ((PinController) -> Void)?

    private let filter: SCContentFilter
    private let windowID: CGWindowID?
    private let processID: pid_t?
    let panel: PinPanel
    let mirror: MirrorView
    /// 表示したフレーム数（自己テスト用）
    private(set) var framesShown = 0
    private var stream: SCStream?
    private var watchTimer: Timer?
    private let frameQueue = DispatchQueue(label: "SideWindow.frames", qos: .userInteractive)

    /// 元ウィンドウの大きさ（ポイント）
    private var windowSize: CGSize
    private let pixelScale: CGFloat
    /// 拡大している範囲（元ウィンドウ内のポイント座標、左上原点）。nil なら全体
    private(set) var zoom: CGRect?
    /// 全体を表示していたときのパネルの大きさ（「全体を表示」で戻す大きさ）
    private(set) var fullViewSize: CGSize?
    /// 範囲選択を取り消したときに戻す状態
    private var zoomUndo: (zoom: CGRect?, frame: NSRect)?
    /// 「拡大をひとつ戻す」で戻る先（nil は全体表示）
    private(set) var zoomHistory: [CGRect?] = []

    // MARK: 描画
    // 取り込んだ最後のフレームを手元に持ち、映す範囲（target）だけを切り出して表示する。
    // 拡大・スクロール・リサイズは取り込み直しを待たずにすぐ見た目に反映される

    private struct RenderState {
        var target: CGRect
        var display: CGSize
        var sharpen: Bool
    }

    private var renderState: RenderState
    private let renderLock = NSLock()
    /// 届いているフレームが元ウィンドウのどこを映したものか（frameQueue でだけ触る）
    private var frameArea: CGRect
    /// 最後に届いたフレーム（frameQueue でだけ触る）
    private var lastBuffer: CVPixelBuffer?
    private let scaler = FrameScaler()
    /// いま取り込んでいる範囲と大きさ（拡大中は周りに余白を付ける）
    private(set) var captureArea: CGRect
    private(set) var captureSize = CGSize.zero
    private var reconfigureWork: DispatchWorkItem?
    private var lastReconfigure = Date.distantPast

    /// 拡大表示を高品質に引き伸ばす
    var sharpensZoom: Bool {
        didSet { updateRenderState() }
    }

    // MARK: 表示状態

    private(set) var isClickThrough = false
    /// クリック透過中に ⌘ を押していて、一時的に操作できる状態
    private var isPassThroughSuspended = false
    private var passThroughTimer: Timer?
    /// 元のウィンドウがいちばん手前にあるときはパネルを隠す
    private(set) var hidesWhenSourceIsFront: Bool
    private(set) var isHiddenForSource = false
    /// 固定した直後は元のウィンドウが手前にあることが多いので、一度ほかのウィンドウが手前に来るまでは隠さない
    private var sourceHasLeftFront = false
    /// メニューバーの「すべて隠す」で隠している
    private(set) var isHiddenByUser = false
    private var isHighlighted = false
    private var isHovering = false
    private(set) var opacity: CGFloat = 1
    /// 不透明度を調整した直後は、マウスを乗せていてもその不透明度で見せる（変化が分かるように）
    private var opacityPreviewUntil = Date.distantPast
    /// 自己テストでは修飾キーの状態とマウスの位置を差し替える
    var modifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }

    /// 画面から外された状態が続いた回数（一瞬だけのことがあるので、続いたら閉じられたとみなす）
    private var orderedOutTicks = 0
    private var failedStarts = 0
    private var lastStartAttempt = Date.distantPast
    private var restoreCheck: DispatchWorkItem?
    private(set) var hasAppeared = false
    /// 飛んできたパネルが収まる場所
    private(set) var settledFrame: NSRect
    private var isClosed = false
    /// 背面にいても見張りのタイマーが間引かれないようにする（App Nap の対象から外す）
    private var activity: NSObjectProtocol?

    /// いま映している範囲
    private var shownArea: CGRect {
        zoom ?? CGRect(origin: .zero, size: windowSize)
    }

    private var visibleFrame: NSRect {
        panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
    }

    /// 隠れているあいだは取り込みの頻度を下げる（電池のため）
    private var wantsLowFrameRate: Bool {
        isHiddenForSource || isHiddenByUser
    }

    init(filter: SCContentFilter, index: Int) {
        self.filter = filter
        let window = filter.includedWindows.first
        windowID = window?.windowID
        processID = window?.owningApplication?.processID
        let appName = window?.owningApplication?.applicationName ?? ""
        let windowTitle = window?.title ?? ""
        switch (appName.isEmpty, windowTitle.isEmpty) {
        case (false, false): title = "\(appName) — \(windowTitle)"
        case (false, true): title = appName
        case (true, false): title = windowTitle
        case (true, true): title = "ウィンドウ \(index + 1)"
        }
        appIcon = processID.flatMap { NSRunningApplication(processIdentifier: $0)?.icon }
        windowSize = filter.contentRect.size
        pixelScale = CGFloat(filter.pointPixelScale)
        sharpensZoom = Preferences.sharpensZoom
        hidesWhenSourceIsFront = Preferences.hidesWhenSourceIsFront

        settledFrame = PinController.placement(for: filter.contentRect.size, index: index)
        panel = PinPanel(contentRect: settledFrame)
        mirror = MirrorView(frame: NSRect(origin: .zero, size: settledFrame.size))
        let whole = CGRect(origin: .zero, size: filter.contentRect.size)
        renderState = RenderState(target: whole, display: .zero, sharpen: Preferences.sharpensZoom)
        frameArea = whole
        captureArea = whole
        super.init()

        mirror.aspect = windowSize
        mirror.title = windowTitle.isEmpty ? appName : windowTitle
        mirror.appIcon = appIcon
        panel.contentView = mirror
        mirror.onOpenSource = { [weak self] in self?.openSource() }
        mirror.onClose = { [weak self] in self?.close() }
        mirror.onZoomButton = { [weak self] in self?.beginZoom() }
        mirror.onShowAll = { [weak self] in self?.showAll() }
        mirror.onZoomSelected = { [weak self] rect in self?.applyZoom(rect) }
        mirror.onZoomCancelled = { [weak self] in self?.cancelZoom() }
        mirror.onSelectFromWhole = { [weak self] in self?.showWholeWindow(keepingSize: true) }
        mirror.onOpacityScroll = { [weak self] delta in self?.scrollOpacity(delta) }
        mirror.onPan = { [weak self] delta in self?.pan(by: delta) }
        mirror.onHoverChanged = { [weak self] hovering in
            self?.isHovering = hovering
            self?.updateAppearance()
        }
        mirror.onInteractionEnded = { [weak self] in self?.rememberPlacement() }
        mirror.onNoticeAction = {
            NSApp.activate()
            SourceWindow.requestAccessibility()
        }
        mirror.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }

        updateRenderState()
        NotificationCenter.default.addObserver(self, selector: #selector(panelDidResize),
                                               name: NSWindow.didResizeNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(panelDidResize),
                                               name: NSWindow.didChangeBackingPropertiesNotification, object: panel)
    }

    /// 前にユーザーが置いた場所（なければマウスのある画面の右上）に置く
    private static func placement(for size: CGSize, index: Int) -> NSRect {
        let remembered = Preferences.lastPanelFrame
        // 覚えている場所が今もどれかの画面の中にあればそこへ（画面構成が変わっていたら使わない）
        let rememberedScreen = remembered.flatMap { frame in
            NSScreen.screens.first { $0.visibleFrame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
        }
        let mouse = NSEvent.mouseLocation
        let screen = rememberedScreen ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return Geometry.placement(for: size, remembered: rememberedScreen == nil ? nil : remembered,
                                  visible: visible, index: index)
    }

    // MARK: - 開始・表示

    func start() {
        // SideWindow はいつも背面にいるので、そのままだと App Nap でタイマーが遅れ、
        // 自動で隠す・最小化の検知が鈍くなる。固定しているあいだだけ外してもらう
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                          reason: "固定したウィンドウを映し続けるため")
        // 元のウィンドウの場所から飛んできて収まる（どのウィンドウが固定されたか分かるように）
        if let windowID, case .shown(let bounds) = SourceWindow.presence(of: windowID, processID: processID) {
            panel.setFrame(SourceWindow.appKitFrame(fromWindowBounds: bounds), display: false)
            panel.alphaValue = 0
        }
        startStream()
        panel.orderFrontRegardless()
        // 最初のフレームが届いたら飛ばす。届かなくても少し待ったら飛ばす
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.appear() }
        // 元ウィンドウのサイズ変更・最小化・閉じられたこと・手前に来たことを見張る
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.watchSource()
        }
    }

    private func appear() {
        guard !hasAppeared, !isClosed else { return }
        hasAppeared = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(settledFrame, display: true)
            panel.animator().alphaValue = targetAlpha
        }, completionHandler: { [weak self] in
            // 操作ボタンの場所が分かるよう、収まったら少しのあいだ操作バーを見せる
            self?.mirror.showChrome(for: 2.5)
        })
    }

    // MARK: - キャプチャ

    private func startStream() {
        lastStartAttempt = Date()
        let config = makeConfiguration()
        let area = captureArea
        frameQueue.async { [weak self] in self?.frameArea = area }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        } catch {
            failedStarts += 1
            return
        }
        self.stream = stream
        stream.startCapture { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async { self?.streamStopped() }
        }
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let area = Geometry.captureArea(for: zoom, windowSize: windowSize)
        let density = Geometry.captureDensity(nativeScale: pixelScale, shownWidth: shownArea.width,
                                              displayWidth: displayPixels.width)
        let size = Geometry.captureSize(area: area.size, density: density)
        captureArea = area
        captureSize = size
        if area != CGRect(origin: .zero, size: windowSize) {
            config.sourceRect = area
        }
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: wantsLowFrameRate ? 4 : 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 5
        config.ignoreShadowsSingleWindow = true
        return config
    }

    private func reconfigure() {
        reconfigureWork?.cancel()
        reconfigureWork = nil
        lastReconfigure = Date()
        let config = makeConfiguration()
        let area = captureArea
        stream?.updateConfiguration(config) { [weak self] error in
            guard error == nil, let self else { return }
            // これ以降に届くフレームは新しい範囲のもの
            self.frameQueue.async { self.frameArea = area }
        }
    }

    private func scheduleReconfigure(after delay: TimeInterval) {
        reconfigureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconfigure() }
        reconfigureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// パネルの画素数
    private var displayPixels: CGSize {
        let scale = panel.backingScaleFactor
        return CGSize(width: panel.frame.width * scale, height: panel.frame.height * scale)
    }

    /// 映す範囲・パネルの大きさ・画質の設定を描画側に伝え、手元の最後のフレームで描き直す
    private func updateRenderState() {
        let state = RenderState(target: shownArea, display: displayPixels, sharpen: sharpensZoom)
        renderLock.lock()
        renderState = state
        renderLock.unlock()
        frameQueue.async { [weak self] in
            guard let self, let buffer = self.lastBuffer else { return }
            self.render(buffer, isNewFrame: false)
        }
    }

    /// パネルの大きさが変わったら描き直し、必要なら取り込む大きさも合わせる（リサイズ中は少し待ってまとめて）
    @objc private func panelDidResize() {
        updateRenderState()
        let density = Geometry.captureDensity(nativeScale: pixelScale, shownWidth: shownArea.width,
                                              displayWidth: displayPixels.width)
        if Geometry.captureSize(area: captureArea.size, density: density) != captureSize {
            scheduleReconfigure(after: 0.2)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        lastBuffer = pixelBuffer
        render(pixelBuffer, isNewFrame: true)
    }

    /// frameQueue で呼ぶ。フレームから映す範囲を切り出して表示する
    private func render(_ buffer: CVPixelBuffer, isNewFrame: Bool) {
        renderLock.lock()
        let state = renderState
        renderLock.unlock()
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let crop = Geometry.normalizedCrop(state.target, in: frameArea)
        var surface: IOSurface?
        var shownCrop = crop ?? unit
        // パネルの方が細かい（拡大表示）ときは、高品質に引き伸ばしてから表示する
        if let crop, state.sharpen,
           let upscaled = scaler.upscale(buffer, crop: crop, to: state.display, sharpen: true) {
            surface = upscaled
            shownCrop = unit
        }
        if surface == nil, let raw = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
            surface = unsafeBitCast(raw, to: IOSurface.self)
        }
        guard let surface else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isNewFrame {
                self.failedStarts = 0
                self.framesShown += 1
                if !self.hasAppeared { self.appear() }
            }
            self.mirror.show(surface, crop: shownCrop)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.streamStopped() }
    }

    /// 取り込みが止まったとき。ウィンドウが画面に戻れば watchSource が再開する
    private func streamStopped() {
        stream = nil
        failedStarts += 1
    }

    // MARK: - 元ウィンドウの見張り

    private func watchSource() {
        guard !isClosed, let windowID else { return }
        let presence = SourceWindow.presence(of: windowID, processID: processID)
        if case .orderedOut = presence {
            orderedOutTicks += 1
        } else {
            orderedOutTicks = 0
        }
        switch presence {
        case .gone:
            close()
            return
        case .orderedOut:
            // デスクトップの切り替え中などに一瞬この状態になることがあるので、1 秒続いたら閉じる
            if orderedOutTicks >= 4 {
                close()
                return
            }
        case .minimized:
            // 「元に戻らなかった」案内を出しているあいだは上書きしない
            if mirror.notice != .minimizedNeedsAccessibility {
                mirror.notice = .minimized
            }
        case .appHidden:
            mirror.notice = .appHidden
        case .inactiveTab:
            mirror.notice = .inactiveTab
        case .shown(let bounds):
            if stream == nil, Date().timeIntervalSince(lastStartAttempt) > 1 {
                startStream()
            }
            mirror.notice = failedStarts >= 3 ? .unavailable : nil
            sourceResized(to: bounds.size)
        }

        let isFront: Bool
        if case .shown = presence {
            isFront = SourceWindow.isFrontmost(windowID)
        } else {
            isFront = false
        }
        if !isFront { sourceHasLeftFront = true }
        setHiddenForSource(hidesWhenSourceIsFront && sourceHasLeftFront && isFront && !mirror.isSelecting)
    }

    private func sourceResized(to size: CGSize) {
        guard size.width >= 1, size.height >= 1, size != windowSize else { return }
        windowSize = size
        let before = shownArea.size
        if let zoom {
            let clipped = zoom.intersection(CGRect(origin: .zero, size: windowSize))
            self.zoom = clipped.width >= 8 && clipped.height >= 8 ? clipped : nil
            mirror.isZoomed = self.zoom != nil
        }
        reconfigure()
        updateRenderState()
        guard shownArea.size != before else { return }
        // 幅を保ったまま、映している範囲の縦横比に合わせる（上端は固定）
        let area = shownArea
        mirror.aspect = area.size
        var frame = panel.frame
        let height = frame.width * area.height / area.width
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(Geometry.clamp(frame, aspect: area.size, into: visibleFrame), display: true)
    }

    // MARK: - 見え方

    /// いまあるべき不透明度
    private var targetAlpha: CGFloat {
        if isHighlighted { return 1 }
        if isHiddenForSource { return 0 }
        if opacityPreviewUntil > Date() { return opacity }
        // 半透明にしていても、マウスを乗せているあいだは読みやすいよう不透明にする
        if isHovering || isPassThroughSuspended { return 1 }
        return opacity
    }

    private func updateAppearance(animated: Bool = true) {
        panel.ignoresMouseEvents = isHiddenForSource || (isClickThrough && !isPassThroughSuspended)
        guard hasAppeared else { return }
        let alpha = targetAlpha
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = alpha
            }
        } else {
            panel.alphaValue = alpha
        }
    }

    private func setHiddenForSource(_ hidden: Bool) {
        guard hidden != isHiddenForSource else { return }
        isHiddenForSource = hidden
        updateAppearance()
        reconfigure()
    }

    /// メニューバーの「すべて隠す」
    func setHiddenByUser(_ hidden: Bool) {
        guard hidden != isHiddenByUser, !isClosed else { return }
        isHiddenByUser = hidden
        if hidden {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.isHiddenByUser else { return }
                self.panel.orderOut(nil)
            })
        } else {
            panel.orderFrontRegardless()
            updateAppearance()
        }
        reconfigure()
    }

    /// メニューバーの一覧でこのパネルを指しているあいだ、枠を目立たせて手前に出す
    func setHighlighted(_ highlighted: Bool) {
        guard highlighted != isHighlighted, !isClosed else { return }
        isHighlighted = highlighted
        mirror.isHighlighted = highlighted
        if highlighted {
            panel.orderFrontRegardless()
        } else if isHiddenByUser {
            panel.orderOut(nil)
        }
        updateAppearance()
    }

    // MARK: - 拡大

    /// 範囲を選んで拡大する。拡大中なら、いま映している範囲の中からさらに拡大する
    @objc func beginZoom() {
        guard !mirror.isSelecting else { return }
        if isClickThrough { toggleClickThrough() }
        zoomUndo = (zoom, panel.frame)
        panel.acceptsKey = true
        panel.makeKey()
        panel.makeFirstResponder(mirror)
        mirror.beginSelecting(canSelectFromWhole: zoom != nil)
    }

    /// 拡大中に、パネルの大きさはそのままで全体を映して選び直す
    @objc func beginZoomFromWhole() {
        beginZoom()
        if zoom != nil {
            showWholeWindow(keepingSize: true)
            mirror.beginSelecting(canSelectFromWhole: false)
        }
    }

    /// ひとつ前の拡大（または全体表示）に戻る
    @objc func zoomBack() {
        guard let previous = zoomHistory.popLast() else { return }
        guard let previous else {
            showAll()
            return
        }
        setZoom(previous, frame: Geometry.zoomedFrame(current: panel.frame, contentAspect: previous.size, visible: visibleFrame))
    }

    private func applyZoom(_ selection: NSRect) {
        releaseKey()
        guard let rect = Geometry.sourceRect(for: selection, viewSize: mirror.bounds.size,
                                             shownArea: shownArea, windowSize: windowSize) else {
            cancelZoom()
            return
        }
        zoom(to: rect, previous: zoomUndo?.zoom)
    }

    /// rect（元ウィンドウ内のポイント座標）を拡大表示する。previous は「ひとつ戻す」の戻り先
    func zoom(to rect: CGRect, previous: CGRect?) {
        // 「全体を表示」で戻す大きさは、最初に拡大したときの全体表示の大きさのままにする
        if previous == nil {
            fullViewSize = panel.frame.size
        }
        zoomHistory.append(previous)
        zoomUndo = nil
        setZoom(rect, frame: Geometry.zoomedFrame(current: panel.frame, contentAspect: rect.size, visible: visibleFrame))
    }

    /// 映す範囲を変え、パネルをその縦横比の frame にする
    private func setZoom(_ rect: CGRect?, frame: NSRect) {
        zoom = rect
        let area = shownArea
        mirror.aspect = area.size
        mirror.isZoomed = rect != nil
        // 先に見た目を切り替え（手元のフレームから切り出す）、それから取り込み直す
        updateRenderState()
        panel.setFrame(frame, display: true, animate: true)
        reconfigure()
    }

    private func cancelZoom() {
        releaseKey()
        guard let undo = zoomUndo else { return }
        zoomUndo = nil
        // 選択中にパネルの大きさを変えていないので、映す範囲だけ元に戻す
        guard let previous = undo.zoom, previous != zoom else { return }
        setZoom(previous, frame: undo.frame)
    }

    /// 拡大をやめて全体を表示する
    @objc func showAll() {
        zoomHistory.removeAll()
        showWholeWindow(keepingSize: false)
    }

    /// keepingSize が true なら今のパネルの大きさに収め、false なら拡大前の大きさに戻す
    private func showWholeWindow(keepingSize: Bool) {
        guard zoom != nil else { return }
        let frame = keepingSize
            ? Geometry.zoomedFrame(current: panel.frame, contentAspect: windowSize, visible: visibleFrame)
            : Geometry.fullFrame(current: panel.frame, previousSize: fullViewSize,
                                 windowSize: windowSize, visible: visibleFrame)
        setZoom(nil, frame: frame)
    }

    /// 拡大中のスクロールで、映す位置を動かす
    func pan(by delta: CGVector) {
        guard let current = zoom else { return }
        let moved = Geometry.panned(current, by: delta, viewWidth: mirror.bounds.width, windowSize: windowSize)
        guard moved != current else { return }
        zoom = moved
        updateRenderState()
        // 余白込みで取り込んでいる範囲からはみ出したら、すぐ取り込み直す。
        // そうでなければ間隔をあけて取り込み直し、止まったら余白を付け直す
        if !captureArea.contains(moved) || Date().timeIntervalSince(lastReconfigure) > 0.12 {
            reconfigure()
        } else {
            scheduleReconfigure(after: 0.12)
        }
    }

    /// 範囲選択が終わったら、書いている文書にキー入力を返す
    private func releaseKey() {
        panel.acceptsKey = false
        guard panel.isKeyWindow else { return }
        let behavior = panel.animationBehavior
        panel.animationBehavior = .none
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        panel.animationBehavior = behavior
    }

    // MARK: - 操作

    @objc func openSource() {
        guard let processID else { return }
        SourceWindow.bringToFront(windowID: windowID, processID: processID)
        // 最小化から戻らなかったら（同じアプリに別のウィンドウがあると戻らないことがある）、
        // アクセシビリティの許可を案内する
        guard mirror.notice == .minimized, !AXIsProcessTrusted() else { return }
        restoreCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mirror.notice == .minimized else { return }
            self.mirror.notice = .minimizedNeedsAccessibility
        }
        restoreCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    @objc private func toggleSharpensZoom() {
        sharpensZoom.toggle()
        Preferences.sharpensZoom = sharpensZoom
    }

    /// クリックを透過する（パネルの下のウィンドウを操作できる）。⌘ を押しているあいだは一時的に操作できる
    @objc func toggleClickThrough() {
        isClickThrough.toggle()
        passThroughTimer?.invalidate()
        passThroughTimer = nil
        isPassThroughSuspended = false
        mirror.showsPassThroughHint = false
        if isClickThrough {
            // 透過中はマウスのイベントが来ないので、ポインタの位置と ⌘ を見張る
            passThroughTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.checkPassThrough()
            }
        }
        updateAppearance()
    }

    func checkPassThrough() {
        guard isClickThrough else { return }
        let inside = panel.isVisible && panel.frame.contains(mouseLocation())
        let command = modifierFlags().contains(.command)
        let suspended = inside && command
        if suspended != isPassThroughSuspended {
            isPassThroughSuspended = suspended
            updateAppearance()
        }
        mirror.showsPassThroughHint = inside && !command && !isHiddenForSource
    }

    @objc private func toggleHidesWhenSourceIsFront() {
        hidesWhenSourceIsFront.toggle()
        Preferences.hidesWhenSourceIsFront = hidesWhenSourceIsFront
        if !hidesWhenSourceIsFront { setHiddenForSource(false) }
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? CGFloat else { return }
        applyOpacity(value)
    }

    private func scrollOpacity(_ delta: CGFloat) {
        applyOpacity(min(1, max(0.15, opacity + delta * 0.01)), animated: false)
    }

    func applyOpacity(_ value: CGFloat, animated: Bool = true) {
        opacity = value
        opacityPreviewUntil = Date().addingTimeInterval(1.2)
        updateAppearance(animated: animated)
        // 見せ終わったら、ホバー中なら不透明に戻す
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in self?.updateAppearance() }
    }

    /// 元の大きさに対する倍率で表示する（中心は固定）
    @objc private func setSize(_ sender: NSMenuItem) {
        guard let scale = sender.representedObject as? CGFloat else { return }
        let area = shownArea
        let size = Geometry.clampSize(CGSize(width: area.width * scale, height: area.height * scale),
                                      aspect: area.size, max: visibleFrame.size)
        let current = panel.frame
        let frame = CGRect(x: current.midX - size.width / 2, y: current.midY - size.height / 2,
                           width: size.width, height: size.height)
        panel.setFrame(Geometry.clamp(frame, aspect: area.size, into: visibleFrame), display: true, animate: true)
        rememberPlacement()
    }

    /// 次に固定するパネルも、ユーザーが置いたこの場所・大きさに出す
    private func rememberPlacement() {
        Preferences.lastPanelFrame = panel.frame
    }

    @objc func close() {
        guard !isClosed else { return }
        isClosed = true
        watchTimer?.invalidate()
        passThroughTimer?.invalidate()
        restoreCheck?.cancel()
        reconfigureWork?.cancel()
        stream?.stopCapture { _ in }
        stream = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        // 消えかけのパネルがクリックを横取りしないよう、すぐに透過させる。
        // このあと自分が解放されても、パネルは確実に画面から外す
        let panel = self.panel
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        onClose?(self)
    }

    // MARK: - メニュー

    /// 右クリック・「•••」ボタン・メニューバーのサブメニューで共用する
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("元のウィンドウを開く", #selector(openSource)))
        menu.addItem(.separator())

        menu.addItem(item(zoom == nil ? "範囲を選んで拡大" : "さらに拡大", #selector(beginZoom)))
        if zoom != nil {
            menu.addItem(item("全体から選び直す", #selector(beginZoomFromWhole)))
            if !zoomHistory.isEmpty {
                menu.addItem(item("拡大をひとつ戻す", #selector(zoomBack)))
            }
            menu.addItem(item("全体を表示", #selector(showAll)))
        }
        menu.addItem(.separator())

        let size = NSMenuItem(title: "サイズ", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for scale in PinController.sizeLevels {
            let sizeItem = item(scale == 1 ? "等倍" : "\(Int(scale * 100))%", #selector(setSize(_:)))
            sizeItem.representedObject = scale
            sizeMenu.addItem(sizeItem)
        }
        size.submenu = sizeMenu
        menu.addItem(size)

        let opacityItem = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for level in PinController.opacityLevels {
            let levelItem = item("\(Int(level * 100))%", #selector(setOpacity(_:)))
            levelItem.representedObject = level
            levelItem.state = abs(opacity - level) < 0.01 ? .on : .off
            opacityMenu.addItem(levelItem)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        menu.addItem(.separator())

        let autoHide = item("元のウィンドウが手前にあるときは隠す", #selector(toggleHidesWhenSourceIsFront))
        autoHide.state = hidesWhenSourceIsFront ? .on : .off
        menu.addItem(autoHide)
        let sharpen = item("拡大表示をくっきりさせる", #selector(toggleSharpensZoom))
        sharpen.state = sharpensZoom ? .on : .off
        menu.addItem(sharpen)
        let clickThrough = item("クリックを透過", #selector(toggleClickThrough))
        clickThrough.subtitle = "下のウィンドウを操作できます。⌘ を押しているあいだはパネルを操作できます"
        clickThrough.state = isClickThrough ? .on : .off
        menu.addItem(clickThrough)
        menu.addItem(.separator())
        menu.addItem(item("固定を解除", #selector(close)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}
