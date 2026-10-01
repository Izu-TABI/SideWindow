import AppKit

let app = NSApplication.shared
BackgroundCursor.enable()

if let index = CommandLine.arguments.firstIndex(of: "--demo") {
    // README 用の画像を作る（開発用）
    let output = CommandLine.arguments.dropFirst(index + 1).first ?? "docs/images"
    Task { @MainActor in await DemoScene(output: URL(fileURLWithPath: output)).run() }
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--selftest") {
    // 実際のパネルで動作を確認する（開発用）
    let output = CommandLine.arguments.dropFirst(index + 1).first ?? NSTemporaryDirectory() + "SideWindowSelfTest"
    Task { @MainActor in await SelfTest(outputDirectory: URL(fileURLWithPath: output)).run() }
    app.run()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
