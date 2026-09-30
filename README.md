# ChatGPT Usage Meter

ChatGPTプランの **Codex使用上限**(5時間制限/週間制限)をmacOSのメニューバーに常時表示するアプリです。
[Claude Usage Meter](https://github.com/withfox-fox1/claude-usage-meter) のChatGPT版で、表示・通知・履歴グラフは同じ仕様です。

> ChatGPTの通常チャットには「使用率%」の仕組みが無いため、Codex(Codex CLI / Codexアプリ / chatgpt.com/codex)の上限を表示します。
> メニューバーでは Claude 版と区別できるよう `GPT 18%` のように表示します。

> 別のMacへの導入は、[SETUP_PROMPT.md](SETUP_PROMPT.md) を Claude Code に渡せば自動で行えます。

## 仕組み

1. ログイン画面(WKWebView)で chatgpt.com にログインする
2. WebView内で `/api/auth/session` を呼び、アクセストークンを取得して Keychain に保存
   (chatgpt.com のCookie系APIはCloudflare保護下にあり、アプリから直接は叩けないため)
3. 5分おきに `https://chatgpt.com/backend-api/wham/usage` を `Authorization: Bearer` 付きで取得
4. アクセストークンが失効(401)したら、非表示のWebViewでトークンを取り直す(1日1回も定期的に取り直す)。
   WebView側のログインも切れていたら「要ログイン」表示になる

## 前提条件

このプロジェクトをビルド・実行するには、以下がインストール済みである必要があります：

- **Xcode** (App Storeからインストール)
- **xcodegen** (Homebrewからインストール)

インストール済みの確認方法：
```bash
brew list xcodegen
```

xcodegen がない場合は以下でインストール：
```bash
brew install xcodegen
```

## ビルド手順

### 1. Xcodeプロジェクトを生成

```bash
cd /Users/agents/chatgpt-usage-meter
xcodegen generate
```

これにより `ChatGPTUsageMeter.xcodeproj` が生成されます。

### 2. Xcodeで開く

```bash
open ChatGPTUsageMeter.xcodeproj
```

### 3. 署名について

`project.yml` で「Apple Development」証明書による**プロビジョニングプロファイルなし**の署名を設定済みです（`CODE_SIGN_STYLE: Manual`）。
Xcodeに自分のApple ID（無料のPersonal Teamで可）でサインインしていれば、そのままビルドできます。
別のApple IDを使う場合は `project.yml` の `DEVELOPMENT_TEAM` を書き換えて `xcodegen generate` し直してください。

> 無料のPersonal Teamのプロファイルは7日で失効し、失効後はアプリが起動できなくなります。
> そのためプロファイルが必要な権限（App Groups / keychain-access-groups）は使わず、ウィジェットも廃止しています。
> プロジェクトにこれらの権限を足すと、また7日ごとの再ビルドが必要になるので注意してください。

### 4. 常用のためにインストール

XcodeのRun（Cmd+R）で起動したアプリはデバッガ配下で動くため、**Xcodeを閉じると一緒に終了します**。
普段使いにはRelease版を `/Applications` に置いて起動してください。

```bash
xcodebuild -project ChatGPTUsageMeter.xcodeproj -scheme ChatGPTUsageMeter \
  -configuration Release -derivedDataPath build build
pkill -x ChatGPTUsageMeter; rm -rf /Applications/ChatGPTUsageMeter.app
ditto build/Build/Products/Release/ChatGPTUsageMeter.app /Applications/ChatGPTUsageMeter.app
open /Applications/ChatGPTUsageMeter.app
```

初回起動時はメニューバーの「GPT」→「ログイン」から chatgpt.com にログインしてください（Googleアカウント等でのログインも可）。
Mac起動時に自動で立ち上げたい場合は、システム設定 → 一般 → ログイン項目 に `/Applications/ChatGPTUsageMeter.app` を追加します。

## 既知の制限事項

- このアプリはchatgpt.comの**非公開の内部API**を利用しています
- OpenAI側の仕様変更により、予告なく動作しなくなる可能性があります
- API仕様変更時は、本プロジェクトを更新する必要があります

## ライセンス

Copyright © 2024. All rights reserved.
