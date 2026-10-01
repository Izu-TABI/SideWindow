import AppKit

/// 常に最前面に浮かぶ枠なしパネル。フォーカスを奪わない
final class PinPanel: NSPanel {
    /// キー入力を受けるか。拡大範囲の選択中（Esc を受けたいとき）だけ true にする。
    /// 普段からキーウィンドウになると、クリックしただけで書いている文書の入力を奪ってしまう
    var acceptsKey = false

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}
