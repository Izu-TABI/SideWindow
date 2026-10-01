import AppKit
import QuartzCore

/// キャプチャした映像を表示するビュー。
/// 移動・リサイズ・拡大範囲の選択といったマウス操作はすべてここで受ける
final class MirrorView: NSView {
    /// 元のウィンドウが画面に出ていないときの案内
    enum Notice: Equatable {
        case minimized
        /// 元に戻そうとしたが戻らなかった（アクセシビリティの許可があれば確実に戻せる）
        case minimizedNeedsAccessibility
        case appHidden
        case inactiveTab
        case unavailable

        var title: String {
            switch self {
            case .minimized, .minimizedNeedsAccessibility: "最小化されています"
            case .appHidden: "アプリが非表示になっています"
            case .inactiveTab: "別のタブが表示されています"
            case .unavailable: "映像を取得できません"
            }
        }

        var detail: String {
            switch self {
            case .minimized: "クリックで元に戻す"
            case .minimizedNeedsAccessibility: "アクセシビリティを許可すると、確実に元に戻せます"
            case .appHidden: "クリックで表示する"
            case .inactiveTab: "このタブに切り替えると、また映ります"
            case .unavailable: "クリックで元のウィンドウを開く"
            }
        }

        var actionTitle: String? {
            self == .minimizedNeedsAccessibility ? "許可する…" : nil
        }
    }

    var onOpenSource: (() -> Void)?
    var onClose: (() -> Void)?
    var onZoomButton: (() -> Void)?
    var onShowAll: (() -> Void)?
    /// 選んだ範囲（このビューの座標系）
    var onZoomSelected: ((NSRect) -> Void)?
    var onZoomCancelled: (() -> Void)?
    /// 拡大中の範囲選択で「全体から選ぶ」を押したとき
    var onSelectFromWhole: (() -> Void)?
    var onOpacityScroll: ((CGFloat) -> Void)?
    /// 拡大中のスクロール（パネル上のポイント）
    var onPan: ((CGVector) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    /// 移動・リサイズが終わったとき（置き場所を覚える）
    var onInteractionEnded: (() -> Void)?
    var onNoticeAction: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    /// 映している範囲の縦横比。リサイズ中はこれを保つ
    var aspect = CGSize(width: 4, height: 3)

    var title = "" {
        didSet {
            titleLabel.stringValue = title
            titleLabel.toolTip = title
        }
    }

    var appIcon: NSImage? {
        didSet { iconView.image = appIcon }
    }

    /// 拡大表示中か（「全体を表示」ボタンを出す）
    var isZoomed = false {
        didSet { updateButtonVisibility() }
    }

    var notice: Notice? {
        didSet {
            guard notice != oldValue else { return }
            imageLayer.opacity = notice == nil ? 1 : 0.35
            layer?.backgroundColor = NSColor.black.withAlphaComponent(notice == nil ? 0.25 : 0.85).cgColor
            noticeTitle.stringValue = notice?.title ?? ""
            noticeDetail.stringValue = notice?.detail ?? ""
            noticeButton.attributedTitle = NSAttributedString(string: notice?.actionTitle ?? "", attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            ])
            noticeButton.isHidden = notice?.actionTitle == nil
            noticeStack.isHidden = notice == nil
            needsLayout = true
        }
    }

    /// メニューバーの一覧でこのパネルを指しているとき、枠を目立たせる
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            layer?.borderColor = (isHighlighted ? NSColor.controlAccentColor : Self.borderColor).cgColor
            layer?.borderWidth = isHighlighted ? 3 : 1
        }
    }

    /// クリックを透過しているときの案内（マウスが上にある間だけ出す）
    var showsPassThroughHint = false {
        didSet { passThroughHint.isHidden = !showsPassThroughHint }
    }

    /// 自己テスト用：透過中の案内が隠れているか
    var showsPassThroughHintHidden: Bool { passThroughHint.isHidden }

    private(set) var isSelecting = false
    /// 操作バーが見えているか（見えていないボタンは押せない）
    private(set) var isChromeVisible = false
    private(set) var isHovering = false

    private static let borderColor = NSColor.white.withAlphaComponent(0.12)
    private static let barHeight: CGFloat = 32

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let gripLayer = CAShapeLayer()
    private let bar = BarView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let zoomButton = BarButton()
    private let showAllButton = BarButton()
    private let openButton = BarButton()
    private let moreButton = BarButton()
    private let hint = SelectionHint()
    private let passThroughHint = Pill(text: "クリック透過中 ・ ⌘ を押している間は操作できます")
    private let noticeTitle = NSTextField(labelWithString: "")
    private let noticeDetail = NSTextField(labelWithString: "")
    private let noticeButton = HintButton(title: "", target: nil, action: nil)
    private let noticeStack = NSStackView()
    private var trackingArea: NSTrackingArea?
    private var chromeTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        layer?.borderColor = Self.borderColor.cgColor
        layer?.borderWidth = 1

        imageLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(imageLayer)

        // 範囲選択中は選んだ範囲の外側を暗くする
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dimLayer.isHidden = true
        layer?.addSublayer(dimLayer)

        selectionLayer.fillColor = nil
        selectionLayer.strokeColor = NSColor.white.cgColor
        selectionLayer.lineWidth = 1.5
        layer?.addSublayer(selectionLayer)

        // 右下のリサイズつまみ（操作バーと一緒に見せる）
        gripLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        gripLayer.fillColor = nil
        gripLayer.lineWidth = 1.5
        gripLayer.lineCap = .round
        gripLayer.shadowColor = NSColor.black.cgColor
        gripLayer.shadowOpacity = 0.7
        gripLayer.shadowRadius = 1.5
        gripLayer.shadowOffset = .zero
        gripLayer.opacity = 0
        layer?.addSublayer(gripLayer)

        setUpBar()
        setUpNotice()
        hint.isHidden = true
        hint.wholeButton.target = self
        hint.wholeButton.action = #selector(selectFromWholeTapped)
        addSubview(hint)
        passThroughHint.isHidden = true
        addSubview(passThroughHint)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUpBar() {
        bar.alphaValue = 0

        let close = BarButton(symbol: "xmark", tip: "固定を解除", target: self, action: #selector(closeTapped))
        zoomButton.configure(symbol: "plus.magnifyingglass", tip: "範囲を選んで拡大", target: self, action: #selector(zoomTapped))
        showAllButton.configure(symbol: "arrow.up.left.and.arrow.down.right", tip: "全体を表示",
                                target: self, action: #selector(showAllTapped))
        openButton.configure(symbol: "arrow.up.forward.app", tip: "元のウィンドウを開く（ダブルクリックでも開けます）",
                             target: self, action: #selector(openTapped))
        moreButton.configure(symbol: "ellipsis", tip: "その他の操作", target: self, action: #selector(moreTapped(_:)))

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 2
        titleLabel.shadow = shadow

        // タイトルは左に寄せ、ボタンは右端にまとめる
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [close, iconView, titleLabel, spacer, zoomButton, showAllButton, openButton, moreButton])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.spacing = 5
        stack.setCustomSpacing(8, after: close)
        stack.setCustomSpacing(4, after: iconView)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        addSubview(bar)
        updateButtonVisibility()
    }

    private func setUpNotice() {
        noticeTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        noticeDetail.font = .systemFont(ofSize: 11)
        for label in [noticeTitle, noticeDetail] {
            label.textColor = .white
            label.alignment = .center
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
            let shadow = NSShadow()
            shadow.shadowColor = .black
            shadow.shadowBlurRadius = 3
            label.shadow = shadow
            noticeStack.addArrangedSubview(label)
        }
        // 前面にないパネルでは標準のボタンが灰色（非アクティブ）で描かれて押せるように見えないので、自前で塗る
        noticeButton.isBordered = false
        noticeButton.wantsLayer = true
        noticeButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        noticeButton.layer?.cornerRadius = 6
        noticeButton.padding = NSSize(width: 24, height: 10)
        noticeButton.target = self
        noticeButton.action = #selector(noticeActionTapped)
        noticeButton.isHidden = true
        noticeStack.addArrangedSubview(noticeButton)
        noticeStack.setCustomSpacing(8, after: noticeDetail)
        noticeStack.orientation = .vertical
        noticeStack.alignment = .centerX
        noticeStack.spacing = 2
        noticeStack.isHidden = true
        addSubview(noticeStack)
    }

    /// 狭いパネルでは、優先度の低いものから隠す（ダブルクリックやメニューからも同じことができる）
    private func updateButtonVisibility() {
        let width = bounds.width
        showAllButton.isHidden = !isZoomed
        openButton.isHidden = width < (isZoomed ? 190 : 165)
        titleLabel.isHidden = width < 215
        iconView.isHidden = width < 150
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func zoomTapped() { onZoomButton?() }
    @objc private func showAllTapped() { onShowAll?() }
    @objc private func openTapped() { onOpenSource?() }
    @objc private func noticeActionTapped() { onNoticeAction?() }

    @objc private func moreTapped(_ sender: NSButton) {
        guard let menu = menuProvider?() else { return }
        let point = convert(NSPoint(x: sender.frame.minX, y: sender.frame.minY - 4), from: sender.superview)
        menu.popUp(positioning: nil, at: point, in: self)
        refreshCursor()
    }

    @objc private func selectFromWholeTapped() {
        hint.showsWholeButton = false
        needsLayout = true
        updateDim(selection: nil)
        onSelectFromWhole?()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        dimLayer.frame = bounds
        selectionLayer.frame = bounds
        gripLayer.frame = bounds
        let grip = CGMutablePath()
        for length in [4.0, 8.0, 12.0] {
            grip.move(to: CGPoint(x: bounds.maxX - 4, y: 4 + length))
            grip.addLine(to: CGPoint(x: bounds.maxX - 4 - length, y: 4))
        }
        gripLayer.path = grip
        if isSelecting, selectionLayer.path == nil { updateDim(selection: nil) }
        CATransaction.commit()

        updateButtonVisibility()
        bar.frame = NSRect(x: 0, y: bounds.height - Self.barHeight, width: bounds.width, height: Self.barHeight)
        let hintSize = hint.fittingSize
        hint.frame = NSRect(x: (bounds.width - min(hintSize.width, bounds.width - 12)) / 2, y: 10,
                            width: min(hintSize.width, bounds.width - 12), height: hintSize.height)
        let passSize = passThroughHint.fittingSize
        passThroughHint.frame = NSRect(x: (bounds.width - min(passSize.width, bounds.width - 12)) / 2, y: 10,
                                       width: min(passSize.width, bounds.width - 12), height: passSize.height)
        noticeTitle.preferredMaxLayoutWidth = bounds.width - 24
        noticeDetail.preferredMaxLayoutWidth = bounds.width - 24
        let noticeSize = noticeStack.fittingSize
        noticeStack.frame = NSRect(x: 12, y: (bounds.height - noticeSize.height) / 2,
                                   width: bounds.width - 24, height: noticeSize.height)
    }

    /// 新しいフレームを表示する（メインスレッドで呼ぶ）。contentsRect は映す部分（割合・左上原点）
    func show(_ surface: IOSurface, crop: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = surface
        // CALayer の contentsRect は左下原点
        imageLayer.contentsRect = CGRect(x: crop.minX, y: 1 - crop.maxY, width: crop.width, height: crop.height)
        CATransaction.commit()
    }

    // MARK: - 操作バー

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        onHoverChanged?(true)
        showChrome(for: 2)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        onHoverChanged?(false)
        hideChrome()
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        // アプリが前面になくてもカーソルを変えられるよう、ここで直接設定する（BackgroundCursor も参照）
        cursor(at: convert(event.locationInWindow, from: nil)).set()
        showChrome(for: 2)
    }

    /// 操作バーを出し、seconds 秒マウスが止まっていたら消す（動画プレーヤーと同じ）。
    /// 読んでいる最中に資料の上端を隠し続けないため
    func showChrome(for seconds: TimeInterval) {
        guard !isSelecting else { return }
        setChrome(visible: true)
        chromeTimer?.invalidate()
        chromeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.chromeTimedOut()
        }
    }

    private func chromeTimedOut() {
        // 操作バーの上にポインタがあるあいだは消さない
        if isHovering, let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let barArea = NSRect(x: 0, y: bounds.height - Self.barHeight - 4, width: bounds.width, height: Self.barHeight + 4)
            if barArea.contains(point) {
                showChrome(for: 2)
                return
            }
        }
        hideChrome()
    }

    private func hideChrome() {
        chromeTimer?.invalidate()
        chromeTimer = nil
        setChrome(visible: false)
    }

    private func setChrome(visible: Bool) {
        let visible = visible && !isSelecting
        guard visible != isChromeVisible else { return }
        isChromeVisible = visible
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.12 : 0.3
            bar.animator().alphaValue = visible ? 1 : 0
        }
        gripLayer.opacity = visible ? 1 : 0
    }

    /// point（ビュー座標）でのポインタの形
    func cursor(at point: NSPoint) -> NSCursor {
        let hit = hitTest(convert(point, to: superview))
        // 押せるもの（ボタン・「クリックで元に戻す」の案内）の上では指の形
        if hit is BarButton || hit is HintButton { return .pointingHand }
        if isSelecting { return .crosshair }
        let edges = Geometry.edges(at: point, in: bounds.size)
        if !edges.isEmpty { return Self.resizeCursor(for: edges) }
        return notice != nil ? .pointingHand : .arrow
    }

    /// 操作が終わったあと、いまのマウス位置に合ったポインタに戻す
    private func refreshCursor() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        cursor(at: point).set()
    }

    // MARK: - 拡大範囲の選択

    /// 範囲選択を始める。拡大中なら「全体から選ぶ」ボタンも出す
    func beginSelecting(canSelectFromWhole: Bool) {
        isSelecting = true
        hideChrome()
        hint.showsWholeButton = canSelectFromWhole
        hint.isHidden = false
        needsLayout = true
        dimLayer.isHidden = false
        updateDim(selection: nil)
        NSCursor.crosshair.set()
    }

    /// 範囲を選んでいる途中の見た目にする（README 用の画像を撮るとき）
    func previewSelection(_ rect: NSRect) {
        beginSelecting(canSelectFromWhole: false)
        updateDim(selection: rect)
    }

    private func endSelecting() {
        isSelecting = false
        selectionLayer.path = nil
        dimLayer.isHidden = true
        hint.isHidden = true
        refreshCursor()
    }

    func cancelSelecting() {
        guard isSelecting else { return }
        endSelecting()
        onZoomCancelled?()
    }

    private func updateDim(selection: NSRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.addRect(bounds)
        if let selection {
            path.addRect(selection)
            selectionLayer.path = CGPath(rect: selection.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        } else {
            selectionLayer.path = nil
        }
        dimLayer.path = path
        dimLayer.fillColor = NSColor.black.withAlphaComponent(selection == nil ? 0.25 : 0.45).cgColor
        CATransaction.commit()
    }

    private func selectRange(from event: NSEvent) {
        guard let window else { return }
        let start = clampedPoint(viewLocation(of: event))
        var rect = NSRect(origin: start, size: .zero)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = clampedPoint(viewLocation(of: next))
            rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
            if next.type == .leftMouseUp { break }
            updateDim(selection: rect)
        }
        guard rect.width >= 12, rect.height >= 12 else {
            // クリックしただけ・小さすぎる範囲は無視して選び直してもらう
            updateDim(selection: nil)
            return
        }
        endSelecting()
        onZoomSelected?(rect)
    }

    private func clampedPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    // MARK: - マウス・キー

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// ボタン以外のクリックはすべてこのビューで受ける（操作バーの余白からもドラッグできるように）
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // 案内の中のボタン（「全体から選ぶ」「許可する…」）は見えていれば押せる
        if hit is HintButton { return hit }
        if isSelecting { return self }
        // 操作バーが見えていないときは、見えないボタンを押してしまわないようにする
        return hit is BarButton && isChromeVisible ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        if isSelecting {
            selectRange(from: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let edges = Geometry.edges(at: point, in: bounds.size)
        if !edges.isEmpty {
            resize(from: edges, event: event)
            onInteractionEnded?()
            return
        }
        if event.clickCount == 2 {
            onOpenSource?()
            return
        }
        let moved = move(from: event)
        if moved {
            onInteractionEnded?()
        } else if notice != nil {
            // 元のウィンドウが画面にないときは、クリックで元に戻す
            onOpenSource?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if isSelecting, event.keyCode == 53 { // Esc
            cancelSelecting()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        cancelSelecting()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if isSelecting {
            cancelSelecting()
            return nil
        }
        return menuProvider?()
    }

    override func scrollWheel(with event: NSEvent) {
        // マウスのホイールは 1 目盛りが小さいので、トラックパッド並みに動くよう大きくする
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        if event.modifierFlags.contains(.option) {
            // ⌥ + スクロールで不透明度
            onOpacityScroll?(event.scrollingDeltaY)
        } else if event.modifierFlags.contains(.command) {
            // ⌘ + スクロールでパネルの拡大縮小
            scale(by: 1 + event.scrollingDeltaY * factor * 0.005, around: convert(event.locationInWindow, from: nil))
        } else if isZoomed, !isSelecting {
            // 拡大中はスクロールで映す位置を動かす
            onPan?(CGVector(dx: event.scrollingDeltaX * factor, dy: event.scrollingDeltaY * factor))
        }
    }

    override func magnify(with event: NSEvent) {
        // トラックパッドのピンチでパネルの拡大縮小
        scale(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    // MARK: - 移動・リサイズ

    private func visibleFrame(at point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? window?.screen ?? NSScreen.main
        return screen?.visibleFrame ?? .infinite
    }

    /// イベントの位置（このビューの座標）
    private func viewLocation(of event: NSEvent) -> NSPoint {
        guard let window else { return .zero }
        return convert(window.convertPoint(fromScreen: screenLocation(of: event)), from: nil)
    }

    /// イベントの位置（画面座標）
    private func screenLocation(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    /// パネルを動かす。performDrag は前面にないパネルの 1 回目のクリックで効かないことがあるので自前で追う。
    /// 動かしたら true
    private func move(from event: NSEvent) -> Bool {
        guard let window else { return false }
        let start = window.frame
        let startMouse = screenLocation(of: event)
        var moved = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let mouse = screenLocation(of: next)
            let dx = mouse.x - startMouse.x
            let dy = mouse.y - startMouse.y
            // 手ぶれでクリックが移動にならないよう、少し動いてから動かし始める
            if !moved, hypot(dx, dy) < 3 { continue }
            if !moved {
                NSCursor.closedHand.push()
                hideChrome()
            }
            moved = true
            let frame = start.offsetBy(dx: dx, dy: dy)
            window.setFrameOrigin(Geometry.snapped(frame, to: visibleFrame(at: mouse)).origin)
        }
        if moved {
            NSCursor.pop()
            refreshCursor()
        }
        return moved
    }

    private func resize(from edges: Edges, event: NSEvent) {
        guard let window else { return }
        let start = window.frame
        let startMouse = screenLocation(of: event)
        let maxSize = visibleFrame(at: startMouse).size
        Self.resizeCursor(for: edges).push()
        defer { NSCursor.pop() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let mouse = screenLocation(of: next)
            let delta = CGVector(dx: mouse.x - startMouse.x, dy: mouse.y - startMouse.y)
            window.setFrame(Geometry.resized(start, edges: edges, by: delta, aspect: aspect, max: maxSize), display: true)
        }
    }

    /// point（ビュー座標）を中心に拡大縮小する
    func scale(by factor: CGFloat, around point: NSPoint) {
        guard let window, factor.isFinite, factor > 0, bounds.width > 0, bounds.height > 0 else { return }
        let anchor = CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
        window.setFrame(Geometry.scaled(window.frame, by: factor, anchor: anchor, aspect: aspect,
                                        max: visibleFrame(at: window.frame.center).size),
                        display: true)
    }

    private static func resizeCursor(for edges: Edges) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch (edges.contains(.left), edges.contains(.right), edges.contains(.top), edges.contains(.bottom)) {
        case (true, _, true, _): position = .topLeft
        case (true, _, _, true): position = .bottomLeft
        case (_, true, true, _): position = .topRight
        case (_, true, _, true): position = .bottomRight
        case (true, _, _, _): position = .left
        case (_, true, _, _): position = .right
        case (_, _, true, _): position = .top
        default: position = .bottom
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }
}

/// 操作バーの背景。すりガラスで後ろをぼかす
/// （映している元のウィンドウのタイトルバーが透けて、タイトルが二重に見えないように）
private final class BarView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 前面にないパネルでも 1 回目のクリックで反応する、丸い背景付きのボタン
final class BarButton: NSButton {
    convenience init(symbol: String, tip: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        configure(symbol: symbol, tip: tip, target: target, action: action)
    }

    func configure(symbol: String, tip: String, target: AnyObject, action: Selector) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        toolTip = tip
        setAccessibilityLabel(tip)
        self.target = target
        self.action = action
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 範囲選択中の案内。拡大中は「全体から選ぶ」ボタンも出す
private final class SelectionHint: NSView {
    let wholeButton = HintButton(title: "全体から選ぶ", target: nil, action: nil)
    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    var showsWholeButton = false {
        didSet {
            wholeButton.isHidden = !showsWholeButton
            label.stringValue = showsWholeButton
                ? "範囲をドラッグ ・ Esc で取り消し"
                : "拡大する範囲をドラッグ ・ Esc で取り消し"
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wholeButton.font = .systemFont(ofSize: 11, weight: .semibold)
        wholeButton.bezelStyle = .accessoryBarAction
        wholeButton.contentTintColor = .white
        wholeButton.appearance = NSAppearance(named: .darkAqua)
        stack.setViews([label, wholeButton], in: .leading)
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        showsWholeButton = false
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 角丸の背景付きの短い案内
private final class Pill: NSView {
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        layer?.cornerRadius = 6
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 前面にないパネルでも 1 回目のクリックで反応する、文字のボタン
final class HintButton: NSButton {
    /// 文字の周りの余白（枠なしで自前で塗るとき）
    var padding = NSSize.zero {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + padding.width, height: size.height + padding.height)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
