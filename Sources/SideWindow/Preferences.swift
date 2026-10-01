import Foundation

/// 次に固定するウィンドウにも引き継ぐ設定
enum Preferences {
    /// 自己テストでは本物の設定を汚さないよう差し替える
    static var store = UserDefaults.standard

    /// 元のウィンドウがいちばん手前にあるときはパネルを隠す
    static var hidesWhenSourceIsFront: Bool {
        get { store.object(forKey: "hidesWhenSourceIsFront") as? Bool ?? true }
        set { store.set(newValue, forKey: "hidesWhenSourceIsFront") }
    }

    /// 拡大表示を高品質に引き伸ばす
    static var sharpensZoom: Bool {
        get { store.object(forKey: "sharpensZoom") as? Bool ?? true }
        set { store.set(newValue, forKey: "sharpensZoom") }
    }

    /// 最後にユーザーが動かしたパネルの場所（新しいパネルもそこに出す）
    static var lastPanelFrame: NSRect? {
        get { store.string(forKey: "lastPanelFrame").map(NSRectFromString) }
        set { store.set(newValue.map(NSStringFromRect), forKey: "lastPanelFrame") }
    }

    /// 初回の使い方を表示したか
    static var didShowWelcome: Bool {
        get { store.bool(forKey: "didShowWelcome") }
        set { store.set(newValue, forKey: "didShowWelcome") }
    }
}
