import Foundation

/// 画面に出す文字の英語訳。日本語の文をそのまま鍵にする。
/// Mac の言語設定で日本語が英語より上にあれば日本語、それ以外は英語で表示する
enum Localization {
    static let usesJapanese: Bool = {
        for language in Locale.preferredLanguages {
            if language.hasPrefix("ja") { return true }
            if language.hasPrefix("en") { return false }
        }
        return false
    }()

    static func text(_ japanese: String) -> String {
        usesJapanese ? japanese : (english[japanese] ?? japanese)
    }

    static let english: [String: String] = [
        // メニューバー
        "ウィンドウを固定…": "Pin a Window…",
        "固定中のウィンドウはありません": "No Pinned Windows",
        "固定中": "Pinned",
        "クリック透過中": "Click-through is on",
        "すべて表示": "Show All",
        "すべて隠す": "Hide All",
        "すべての固定を解除": "Unpin All",
        "ログイン時に起動": "Open at Login",
        "アクセシビリティを許可…": "Allow Accessibility Access…",
        "最小化したウィンドウを確実に元に戻せます": "Reliably restores minimized windows",
        "使い方": "How to Use",
        "SideWindow について": "About SideWindow",
        "SideWindow を終了": "Quit SideWindow",
        "ウィンドウの選択を開始できませんでした": "Couldn’t start choosing a window",
        "参照したいウィンドウを、いつも手前に。": "Keep the window you’re referring to always on top.",

        // パネルの案内
        "最小化されています": "Minimized",
        "アプリが非表示になっています": "The app is hidden",
        "別のタブが表示されています": "Another tab is showing",
        "映像を取得できません": "Can’t capture this window",
        "クリックで元に戻す": "Click to restore",
        "アクセシビリティを許可すると、確実に元に戻せます": "Allow accessibility access to restore it reliably",
        "クリックで表示する": "Click to show",
        "このタブに切り替えると、また映ります": "Switch back to this tab to see it again",
        "クリックで元のウィンドウを開く": "Click to open the original window",
        "許可する…": "Allow…",
        "クリック透過中 ・ ⌘ を押している間は操作できます": "Click-through · Hold ⌘ to use the panel",
        "全体から選ぶ": "Choose from Whole Window",
        "範囲をドラッグ ・ Esc で取り消し": "Drag an area · Esc to cancel",
        "拡大する範囲をドラッグ ・ Esc で取り消し": "Drag the area to zoom · Esc to cancel",

        // パネルのボタンとメニュー
        "固定を解除": "Unpin",
        "範囲を選んで拡大": "Zoom Into an Area",
        "全体を表示": "Show Whole Window",
        "元のウィンドウを開く（ダブルクリックでも開けます）": "Open the original window (or double-click)",
        "その他の操作": "More",
        "ウィンドウ %d": "Window %d",
        "元のウィンドウを開く": "Open Original Window",
        "さらに拡大": "Zoom In Further",
        "全体から選び直す": "Choose Again from Whole Window",
        "拡大をひとつ戻す": "Back to Previous Zoom",
        "サイズ": "Size",
        "等倍": "Actual Size",
        "不透明度": "Opacity",
        "元のウィンドウが手前にあるときは隠す": "Hide While Original Window Is in Front",
        "拡大表示をくっきりさせる": "Sharpen Zoomed View",
        "クリックを透過": "Click Through",
        "下のウィンドウを操作できます。⌘ を押しているあいだはパネルを操作できます":
            "Clicks go to the window below. Hold ⌘ to use the panel.",

        // 初回の案内
        "SideWindow の使い方": "How to Use SideWindow",
        "ウィンドウを選ぶ": "Choose a Window",
        "固定するウィンドウを選ぶ": "Choose a window to pin",
        "メニューバーの ": "Click ",
        " をクリックするか ⌃⌥P を押して、手前に置きたいウィンドウをクリックします。":
            " in the menu bar or press ⌃⌥P, then click the window you want to keep on top.",
        "好きな場所・大きさに": "Put it anywhere, any size",
        "ドラッグで移動、端や角をドラッグでサイズを変えられます。画面の端に近づけると吸い付きます。":
            "Drag to move it, or drag an edge or corner to resize. It snaps to the edges of the screen.",
        "見たいところを拡大": "Zoom into what you need",
        "マウスを乗せると出るボタンの 🔍 で範囲を選ぶと拡大します。拡大中はスクロールで位置を動かせます。":
            "Hover over the panel, click 🔍, and drag an area to zoom in. While zoomed, scroll to move around.",
        "元のウィンドウへ": "Jump to the original",
        "ダブルクリックで元のウィンドウを開けます。元のウィンドウを見ているあいだ、パネルは自動で隠れます。":
            "Double-click the panel to open the original window. The panel hides itself while the original is in front.",
        "ログイン時に起動する": "Open at login",
        "この案内は、メニューバーのアイコンの「使い方」からいつでも開けます。":
            "You can open this guide anytime from “How to Use” in the menu bar icon.",
        "ログイン時に起動するよう設定できませんでした": "Couldn’t set SideWindow to open at login",
        "ログイン時の起動をやめられませんでした": "Couldn’t stop SideWindow from opening at login",
    ]
}

/// 画面に出す文字（英語の環境では英語にする）
func L(_ japanese: String) -> String {
    Localization.text(japanese)
}
