import AppKit
import ServiceManagement

/// ログイン時に起動するか（システム設定の「ログイン項目」に登録する）
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = enabled ? "ログイン時に起動するよう設定できませんでした" : "ログイン時の起動をやめられませんでした"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

/// 初回起動時と「使い方」で出す案内。
/// メニューバーだけのアプリは起動しても何も見えないので、何をすればいいかをここで伝える
final class WelcomeWindowController: NSObject {
    var onChooseWindow: (() -> Void)?
    private var window: NSWindow?
    private var loginCheckbox: NSButton?

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        loginCheckbox?.state = LoginItem.isEnabled ? .on : .off
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func chooseTapped() {
        window?.orderOut(nil)
        onChooseWindow?()
    }

    @objc private func loginToggled(_ sender: NSButton) {
        LoginItem.setEnabled(sender.state == .on)
        sender.state = LoginItem.isEnabled ? .on : .off
    }

    private func makeWindow() -> NSWindow {
        let width: CGFloat = 440
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "SideWindow の使い方"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 84),
            icon.heightAnchor.constraint(equalToConstant: 84),
        ])
        let title = Self.label("SideWindow", font: .systemFont(ofSize: 24, weight: .bold))
        let subtitle = Self.label("参照したいウィンドウを、いつも手前に。", font: .systemFont(ofSize: 13),
                                  color: .secondaryLabelColor)

        let bodyWidth = width - 64 - 46
        let steps = NSStackView(views: [
            Self.step(symbol: "cursorarrow.click", title: "ウィンドウを選ぶ",
                      body: Self.menuBarText(), width: bodyWidth),
            Self.step(symbol: "arrow.up.and.down.and.arrow.left.and.right", title: "好きな場所・大きさに",
                      body: NSAttributedString(string: "ドラッグで移動、端や角をドラッグでサイズを変えられます。画面の端に近づけると吸い付きます。"),
                      width: bodyWidth),
            Self.step(symbol: "plus.magnifyingglass", title: "見たいところを拡大",
                      body: NSAttributedString(string: "マウスを乗せると出るボタンの 🔍 で範囲を選ぶと拡大します。拡大中はスクロールで位置を動かせます。"),
                      width: bodyWidth),
            Self.step(symbol: "arrow.up.forward.app", title: "元のウィンドウへ",
                      body: NSAttributedString(string: "ダブルクリックで元のウィンドウを開けます。元のウィンドウを見ているあいだ、パネルは自動で隠れます。"),
                      width: bodyWidth),
        ])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 16

        let checkbox = NSButton(checkboxWithTitle: "ログイン時に起動する", target: self, action: #selector(loginToggled(_:)))
        checkbox.state = LoginItem.isEnabled ? .on : .off
        loginCheckbox = checkbox

        let choose = NSButton(title: "ウィンドウを選ぶ", target: self, action: #selector(chooseTapped))
        choose.bezelStyle = .push
        choose.controlSize = .large
        choose.keyEquivalent = "\r"
        choose.translatesAutoresizingMaskIntoConstraints = false
        choose.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let footer = Self.label("この案内は、メニューバーのアイコンの「使い方」からいつでも開けます。",
                                font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)

        let stack = NSStackView(views: [icon, title, subtitle, steps, checkbox, choose, footer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(10, after: icon)
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(22, after: steps)
        stack.setCustomSpacing(14, after: checkbox)
        stack.setCustomSpacing(12, after: choose)
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 32, bottom: 22, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: width),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        return window
    }

    /// 「メニューバーの [アイコン] をクリックするか ⌃⌥P を押して…」（アイコンは文字の中に入れる）
    private static func menuBarText() -> NSAttributedString {
        let text = NSMutableAttributedString(string: "メニューバーの ")
        let attachment = NSTextAttachment()
        attachment.image = tinted(StatusIcon.make(), color: .labelColor)
        attachment.bounds = CGRect(x: 0, y: -3, width: 15, height: 15)
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: " をクリックするか ⌃⌥P を押して、手前に置きたいウィンドウをクリックします。"))
        return text
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let result = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return result
    }

    private static func step(symbol: String, title: String, body: NSAttributedString, width: CGFloat) -> NSView {
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 15
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(image)
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 30),
            badge.heightAnchor.constraint(equalToConstant: 30),
            image.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])

        let titleLabel = label(title, font: .systemFont(ofSize: 13, weight: .semibold))
        let bodyLabel = NSTextField(wrappingLabelWithString: "")
        let styled = NSMutableAttributedString(attributedString: body)
        styled.addAttributes([.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor],
                             range: NSRange(location: 0, length: styled.length))
        bodyLabel.attributedStringValue = styled
        bodyLabel.preferredMaxLayoutWidth = width
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.widthAnchor.constraint(equalToConstant: width).isActive = true

        let texts = NSStackView(views: [titleLabel, bodyLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        let row = NSStackView(views: [badge, texts])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        return row
    }

    private static func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.alignment = .center
        return label
    }
}
