import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SCContentSharingPickerObserver {
    private var statusItem: NSStatusItem!
    /// 固定中のパネル（自己テストからメニューの中身を確かめられるよう internal）
    var pins: [PinController] = []
    private var hotKeys: [HotKey] = []
    private let picker = SCContentSharingPicker.shared
    private let welcome = WelcomeWindowController()
    /// ウィンドウを選ぶ前に前面だったアプリ（選び終わったら、そのアプリに入力を返す）
    private var appBeforePicking: NSRunningApplication?
    /// メニューバーの「すべて隠す」
    private var pinsHidden = false {
        didSet { statusItem?.button?.appearsDisabled = pinsHidden }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.toolTip = "SideWindow"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // システムのウィンドウピッカーを使うので「画面収録」の許可は不要
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow]
        if let bundleID = Bundle.main.bundleIdentifier {
            config.excludedBundleIDs = [bundleID]
        }
        picker.defaultConfiguration = config
        picker.maximumStreamCount = nil
        picker.add(self)

        hotKeys = [
            // ⌃⌥P でウィンドウを選ぶ
            HotKey(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey) { [weak self] in self?.chooseWindow() },
            // ⌃⌥H で固定中のパネルをすべて隠す・表示する
            HotKey(keyCode: kVK_ANSI_H, modifiers: controlKey | optionKey) { [weak self] in self?.toggleHidden() },
        ]

        welcome.onChooseWindow = { [weak self] in self?.chooseWindow() }
        if !Preferences.didShowWelcome {
            Preferences.didShowWelcome = true
            welcome.show()
        }
    }

    /// Finder や Launchpad からもう一度開いたら、そのままウィンドウを選べるようにする
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        chooseWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        picker.isActive = false
    }

    @objc private func chooseWindow() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            appBeforePicking = front
        }
        if pinsHidden { setPinsHidden(false) }
        // ピッカーが有効な間はメニューバーに画面共有のアイコンが出るので、選ぶときだけ有効にする
        picker.isActive = true
        NSApp.activate()
        picker.present(using: .window)
    }

    /// 選び終わったら、直前まで使っていたアプリに入力を返す（SideWindow が前面に残らないように）
    private func returnFocus() {
        guard let app = appBeforePicking else { return }
        appBeforePicking = nil
        guard NSApp.isActive, !welcome.isVisible, !app.isTerminated else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    /// 固定中のウィンドウがなければピッカーを止めて、メニューバーのアイコンを消す
    private func deactivatePickerIfIdle() {
        if pins.isEmpty {
            picker.isActive = false
        }
    }

    // MARK: - SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async { [weak self] in self?.pin(filter) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { [weak self] in
            self?.returnFocus()
            self?.deactivatePickerIfIdle()
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = L("ウィンドウの選択を開始できませんでした")
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
            self.deactivatePickerIfIdle()
        }
    }

    private func pin(_ filter: SCContentFilter) {
        let controller = PinController(filter: filter, index: pins.count)
        controller.onClose = { [weak self] closed in
            self?.pins.removeAll { $0 === closed }
            self?.deactivatePickerIfIdle()
        }
        pins.append(controller)
        controller.start()
        returnFocus()
    }

    // MARK: - すべて隠す

    @objc private func toggleHidden() {
        guard !pins.isEmpty || pinsHidden else { return }
        setPinsHidden(!pinsHidden)
    }

    private func setPinsHidden(_ hidden: Bool) {
        pinsHidden = hidden
        pins.forEach { $0.setHiddenByUser(hidden) }
    }

    // MARK: - メニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(item(L("ウィンドウを固定…"), #selector(chooseWindow), key: "p"))
        menu.addItem(.separator())

        if pins.isEmpty {
            let empty = NSMenuItem(title: L("固定中のウィンドウはありません"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            menu.addItem(.sectionHeader(title: L("固定中")))
            for pin in pins {
                // 項目にマウスを合わせると、そのパネルの枠が光る（menu(_:willHighlight:)）
                let row = NSMenuItem(title: truncated(pin.title), action: nil, keyEquivalent: "")
                row.image = pin.appIcon.map(menuIcon)
                row.representedObject = pin
                row.submenu = pin.makeMenu()
                if pin.isClickThrough { row.subtitle = L("クリック透過中") }
                menu.addItem(row)
            }
            menu.addItem(.separator())
            menu.addItem(item(pinsHidden ? L("すべて表示") : L("すべて隠す"), #selector(toggleHidden), key: "h"))
            menu.addItem(item(L("すべての固定を解除"), #selector(unpinAll)))
        }

        menu.addItem(.separator())
        let login = item(L("ログイン時に起動"), #selector(toggleLoginItem))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        if !AXIsProcessTrusted() {
            let access = item(L("アクセシビリティを許可…"), #selector(requestAccessibility))
            access.subtitle = L("最小化したウィンドウを確実に元に戻せます")
            menu.addItem(access)
        }
        menu.addItem(item(L("使い方"), #selector(showWelcome)))
        menu.addItem(item(L("SideWindow について"), #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("SideWindow を終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let highlighted = item?.representedObject as? PinController
        pins.forEach { $0.setHighlighted($0 === highlighted) }
    }

    func menuDidClose(_ menu: NSMenu) {
        pins.forEach { $0.setHighlighted(false) }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = [.control, .option] }
        item.target = self
        return item
    }

    private func menuIcon(_ image: NSImage) -> NSImage {
        let icon = image.copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func requestAccessibility() {
        NSApp.activate()
        SourceWindow.requestAccessibility()
    }

    @objc private func showWelcome() {
        welcome.show()
    }

    @objc private func showAbout() {
        NSApp.activate()
        let credits = NSAttributedString(string: L("参照したいウィンドウを、いつも手前に。"), attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func unpinAll() {
        pins.forEach { $0.close() }
        pinsHidden = false
    }

    private func truncated(_ text: String) -> String {
        text.count > 44 ? String(text.prefix(43)) + "…" : text
    }
}
