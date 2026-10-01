import AppKit
import ApplicationServices

// どれも非公開 API だが、Rectangle や yabai などのウィンドウ管理アプリが長年使っている安定したもの
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windowIDs: CFArray) -> Unmanaged<CFArray>?
@_silgen_name("CGSGetWindowTags")
private func CGSGetWindowTags(_ connection: Int32, _ windowID: CGWindowID, _ tags: UnsafeMutablePointer<UInt64>, _ count: Int32) -> Int32

/// 固定元のウィンドウの状態確認と前面表示
enum SourceWindow {
    enum Presence: Equatable {
        /// 表示されている（別のデスクトップにある場合も含む）
        case shown(CGRect)
        case minimized
        /// アプリごと隠されている（⌘H）
        case appHidden
        /// ネイティブのタブ（Finder・プレビューなど）で、別のタブが選ばれている
        case inactiveTab
        /// 画面から外された（閉じられた可能性が高い）。AppKit は閉じたウィンドウを再利用のため残すことがある
        case orderedOut
        case gone
    }

    /// ウィンドウのタグ。実機で確かめた値：最小化すると 1<<60、アプリを隠すと 1<<39 が立つ
    private static let minimizedTag: UInt64 = 1 << 60
    private static let appHiddenTag: UInt64 = 1 << 39

    static func presence(of windowID: CGWindowID, processID: pid_t?) -> Presence {
        // 最小化・非表示のウィンドウは optionIncludingWindow では返らないので、全ウィンドウの一覧から探す
        guard let info = windowInfo(windowID),
              let boundsDict = info[kCGWindowBounds as String],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary)
        else { return .gone }

        if info[kCGWindowIsOnscreen as String] as? Bool == true {
            return .shown(bounds)
        }
        // 画面に出ていない：最小化・アプリの非表示・別のデスクトップ・閉じられた のどれか
        let tags = windowTags(windowID)
        if tags & minimizedTag != 0 {
            return .minimized
        }
        if tags & appHiddenTag != 0
            || processID.flatMap({ NSRunningApplication(processIdentifier: $0)?.isHidden }) == true {
            return .appHidden
        }
        if let processID, axMinimized(windowID: windowID, processID: processID) == true {
            return .minimized
        }
        // 実機で確かめた違い：選ばれていないタブはどのデスクトップにも属さない。
        // 別のデスクトップにあるウィンドウは今のデスクトップにだけ属さない。閉じたウィンドウは今のデスクトップに属したまま残る
        // （ただしタブだったウィンドウは閉じてもどこにも属さない）。
        // 同じタブグループのウィンドウは同じ位置・大きさなので、そこに同じアプリのウィンドウが見えていれば選ばれていないタブ
        if !isOnAnySpace(windowID) {
            return hasVisibleTabSibling(windowID, bounds: bounds, processID: processID) ? .inactiveTab : .orderedOut
        }
        return isOnCurrentSpace(windowID) ? .orderedOut : .shown(bounds)
    }

    private static func hasVisibleTabSibling(_ windowID: CGWindowID, bounds: CGRect, processID: pid_t?) -> Bool {
        guard let processID,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == processID,
                  (info[kCGWindowNumber as String] as? CGWindowID) != windowID,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String],
                  let other = CGRect(dictionaryRepresentation: dict as! CFDictionary) else { return false }
            return abs(other.minX - bounds.minX) <= 4 && abs(other.minY - bounds.minY) <= 4
                && abs(other.width - bounds.width) <= 4 && abs(other.height - bounds.height) <= 4
        }
    }

    private static func windowTags(_ windowID: CGWindowID) -> UInt64 {
        var tags: UInt64 = 0
        _ = CGSGetWindowTags(CGSMainConnectionID(), windowID, &tags, 64)
        return tags
    }

    private static func windowInfo(_ windowID: CGWindowID) -> [String: Any]? {
        if let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first {
            return info
        }
        let all = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] ?? []
        return all.first { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }
    }

    /// CGWindowList の位置（左上原点）を AppKit の画面座標（左下原点）に直す
    static func appKitFrame(fromWindowBounds bounds: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    /// 元のウィンドウがいちばん手前にあるか（ユーザーが元のウィンドウを見ている）
    static func isFrontmost(_ windowID: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        // 普通のウィンドウ（レイヤー 0）のうち最も手前のもの。
        // SideWindow 自身の補助ウィンドウ（画面取り込みが作る NSLocalWindowSharingWindow など）は数えない
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownNormalWindows = Set(NSApp.windows
            .filter { $0.isVisible && $0.level == .normal && $0.styleMask.contains(.titled) }
            .map { CGWindowID($0.windowNumber) })
        let front = list.first { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID else { return false }
            return (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID
                || number == windowID || ownNormalWindows.contains(number)
        }
        return (front?[kCGWindowNumber as String] as? CGWindowID) == windowID
    }

    /// 今表示しているデスクトップ（Space）に属しているか
    static func isOnCurrentSpace(_ windowID: CGWindowID) -> Bool {
        spaceCount(windowID, mask: 0x5) > 0
    }

    /// いずれかのデスクトップに属しているか
    static func isOnAnySpace(_ windowID: CGWindowID) -> Bool {
        spaceCount(windowID, mask: 0x7) > 0
    }

    private static func spaceCount(_ windowID: CGWindowID, mask: Int32) -> Int {
        let ids = [NSNumber(value: windowID)] as CFArray
        let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), mask, ids)?.takeRetainedValue() as? [Any]
        return spaces?.count ?? 0
    }

    /// 元のウィンドウを前面に出す。最小化・非表示なら元に戻す
    static func bringToFront(windowID: CGWindowID?, processID: pid_t) {
        // 自分のウィンドウは固定の対象にしない（自己テストで別のプロセスを起動してしまわないように）
        guard processID != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: processID) else { return }
        if app.isHidden { app.unhide() }
        if let windowID, let window = axWindow(windowID: windowID, processID: processID) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        // macOS 14 以降、前面にないアプリからの NSRunningApplication.activate() は無視されることがある。
        // Dock のアイコンをクリックしたのと同じ扱いになる openApplication を使う
        guard let url = app.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    // MARK: - アクセシビリティ（許可されているときだけ使う）

    private static func axWindow(windowID: CGWindowID, processID: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { window in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(window, &id) == .success && id == windowID
        }
    }

    private static func axMinimized(windowID: CGWindowID, processID: pid_t) -> Bool? {
        guard let window = axWindow(windowID: windowID, processID: processID) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    /// アクセシビリティの許可を求める
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
