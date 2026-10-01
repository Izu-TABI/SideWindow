import CoreGraphics

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ connection: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

/// 前面にないアプリの NSCursor.set() は macOS に無視される。SideWindow はフォーカスを奪わないよう
/// 常に背面にいるので、これを有効にしないとパネル上でポインタの形を変えられない（実機で確認済み）。
/// 非公開の接続プロパティだが、背面で動くユーティリティアプリが広く使っている
enum BackgroundCursor {
    static func enable() {
        let connection = _CGSDefaultConnection()
        _ = CGSSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
