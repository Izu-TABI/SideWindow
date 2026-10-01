## インストール

1. 下の **SideWindow.zip** をダウンロードして開き、`SideWindow.app` を「アプリケーション」フォルダに移動します。
2. `SideWindow.app` を開きます。Apple の公証を受けていないため、初回は「開いていません」という警告が出るので「完了」を押します。
3. 「システム設定」→「プライバシーとセキュリティ」を開き、下の方にある SideWindow の「このまま開く」を押します。
4. もう一度確認が出たら「このまま開く」を押します。

使い方の案内が開いたら準備完了です。メニューバーのアイコンか ⌃⌥P で、手前に置きたいウィンドウを選びます。

ターミナルが使える場合は、手順 2〜4 の代わりに次のコマンドでも開けるようになります。

```
xattr -dr com.apple.quarantine /Applications/SideWindow.app
```

**動作環境**: macOS 15.2 以降（Apple シリコン / Intel）

---

## Installation

1. Download **SideWindow.zip** below, open it, and move `SideWindow.app` to your Applications folder.
2. Open `SideWindow.app`. Because the app isn’t notarized by Apple, the first launch shows a warning that it can’t be opened — click Done.
3. Open System Settings → Privacy & Security, scroll down, and click Open Anyway next to SideWindow.
4. Confirm with Open Anyway again.

You’re ready when the welcome guide appears. Choose the window to keep on top from the menu bar icon or with ⌃⌥P. The app is shown in English unless Japanese comes before English in your Mac’s preferred languages.

If you’re comfortable with Terminal, this command replaces steps 2–4:

```
xattr -dr com.apple.quarantine /Applications/SideWindow.app
```

**Requirements**: macOS 15.2 or later (Apple silicon / Intel)
