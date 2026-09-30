# セットアップ指示書（Claude Code向け）

このファイルは、別のMacに ChatGPT Usage Meter（ChatGPTプランのCodex使用上限をメニューバーに表示するmacOSアプリ）を導入するための自己完結した指示書です。
ユーザーからこのファイル（またはこのリポジトリのURL）を渡されて「これで実装して」と言われたら、以下を上から順に実施してください。

**想定環境**: 開発元のMacと同じ構成（macOS 27 / Xcode 27 / Homebrew導入済み / Xcodeに開発元と同じApple IDでサインイン済み）。これ以外の環境向けの分岐は用意していないので、違いが見つかったら中断してユーザーに相談する。

## このアプリの前提（作業前に把握しておくこと）

- メニューバー専用アプリ。メニューバーには `GPT 18%` のように表示される（同じMacに Claude Usage Meter があっても区別できるように）
- 表示するのは **Codexの5時間制限/週間制限**（ChatGPTの通常チャットには使用率の仕組みが無いため）
- **プロビジョニングプロファイルなしで署名する**（`project.yml` で `CODE_SIGN_STYLE: Manual` / `CODE_SIGN_IDENTITY: "Apple Development"`）。
  無料のPersonal Teamのプロファイルは7日で失効し、失効後はアプリが起動できなくなるため。
  **App Groups / keychain-access-groups などプロファイルが必要な権限は絶対に追加しないこと。**
- 常用は `/Applications/ChatGPTUsageMeter.app` から起動する。XcodeのRun（Cmd+R）で起動するとデバッガ配下になり、Xcodeを閉じると一緒に終了してしまう
- Claude Usage Meter とはバンドルID・Keychain項目・設定がすべて別なので、同じMacに両方入れてよい。互いに干渉しない
- 以下のコマンドは、特に断りがなければリポジトリのルート（`~/chatgpt-usage-meter`）で実行する

## 手順

### 1. 環境の確認

```bash
sw_vers -productVersion        # 27.x
xcodebuild -version            # Xcode 27.x
brew --version
security find-identity -v -p codesigning | grep "Apple Development"   # 1件以上あること
```

- どれかが想定と違う（macOS/Xcodeのバージョン違い、Homebrewが無い、Apple Development証明書が無い）場合は、ここで中断してユーザーに状況を伝える。
  証明書が無いのは、XcodeにApple IDでサインインしていないのが原因のことが多い（Xcode → Settings → Accounts）。

### 2. xcodegen の導入

```bash
brew list xcodegen || brew install xcodegen
```

### 3. ソースの取得

リポジトリは公開（public）なのでログイン不要。

- `~/chatgpt-usage-meter` が**無い**場合:
  ```bash
  git clone https://github.com/withfox-fox1/chatgpt-usage-meter.git ~/chatgpt-usage-meter
  ```
- **既にある**場合: `git status --short` で未コミットの変更が無いことを確認してから `git pull --ff-only`。
  変更がある場合は勝手に捨てず、ユーザーに確認する。

### 4. プロジェクト生成とテスト

```bash
xcodegen generate
cd Sources/Shared && swift test; cd ../..
```

- 最後に `Test run with N tests in 5 suites passed` が出れば成功。
- テストが失敗した場合は中断し、出力をユーザーに見せて相談する。

### 5. Release版のビルド

署名はXcodeにサインイン済みのApple IDの「Apple Development」証明書で、プロファイルなしで行う（`project.yml` の設定どおり。追加の指定は不要）。

```bash
xcodebuild -project ChatGPTUsageMeter.xcodeproj -scheme ChatGPTUsageMeter \
  -configuration Release -derivedDataPath build build
```

- `-allowProvisioningUpdates` は付けない（プロファイルを使わないため不要）。
- 最後に `** BUILD SUCCEEDED **` が出れば成功。`AppIcon has 2 unassigned children` の警告は既知で無害。
- 失敗した場合は `error:` の行をユーザーに見せて相談する。署名関連（`No signing certificate` など）なら手順1の証明書を確認する。

### 6. ビルド結果の検証

```bash
APP=build/Build/Products/Release/ChatGPTUsageMeter.app
find "$APP" -name "*.provisionprofile" | wc -l          # 0 であること（1以上なら7日で起動不能になる）
codesign -d --entitlements - --xml "$APP" | plutil -p -  # app-sandbox / network.client / get-task-allow の3つだけであること
codesign --verify --deep --strict "$APP" && echo VERIFY_OK
```

どれか満たさない場合はインストールせず中断し、ユーザーに報告する。

### 7. /Applications へのインストールと起動

```bash
pkill -x ChatGPTUsageMeter || true
rm -rf /Applications/ChatGPTUsageMeter.app
ditto build/Build/Products/Release/ChatGPTUsageMeter.app /Applications/ChatGPTUsageMeter.app
open /Applications/ChatGPTUsageMeter.app
sleep 3
ps -axo pid,ppid,comm | grep '/Applications/ChatGPTUsageMeter.app' | grep -v grep   # 親PIDが 1 なら正常（Xcode配下ではない）
```

### 8. ログイン項目に登録（Mac起動時に自動で立ち上げる）

```bash
osascript -e 'tell application "System Events" to get the name of every login item'
```

一覧に `ChatGPTUsageMeter` が無ければ追加する（既にあれば追加しない。重複登録になるため）:

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/ChatGPTUsageMeter.app", hidden:false}'
osascript -e 'tell application "System Events" to get path of login item "ChatGPTUsageMeter"'   # /Applications/ChatGPTUsageMeter.app と出ればOK
```

- 初回は「“ターミナル”（または実行中のアプリ）が“System Events”を制御しようとしています」という確認が出る。ユーザーに「OK」を押してもらう。
- 拒否されて失敗した場合は、ユーザーに手動で登録してもらう: システム設定 → 一般 → ログイン項目 → 「+」→ `/Applications/ChatGPTUsageMeter.app`。

### 9. ユーザーに引き継ぐ（ここはユーザー自身の操作）

以下を伝える:

1. メニューバーに `GPT` と表示されたアイコンが出ていることを確認してください
2. `GPT` をクリック →「ログイン」から chatgpt.com にログインしてください（ブラウザのログイン状態とは別の、アプリ専用のログインです。Googleアカウント等でのログインも可）
3. ログインするとウィンドウが自動で閉じ、メニューバーが `GPT 0%` のような表示に変わります

ログイン後の確認（ユーザーから「ログインした」と言われたら実施）:

```bash
security find-generic-password -s dev.local.chatgptusagemeter.token >/dev/null 2>&1 && echo "token: present"
```

- アプリの設定ファイル（`~/Library/Containers/dev.local.chatgptusagemeter/...`）はmacOSのコンテナ保護で読めないので、読もうとしなくてよい。
  表示内容はユーザーにメニューバーを見てもらうか、`screencapture -x` で画面を撮って右上を確認する。

## 今後コードを更新したとき

```bash
cd ~/chatgpt-usage-meter && git pull --ff-only && xcodegen generate
```

のあと、手順5〜7（ビルド → 検証 → /Applications に上書き）を繰り返す。ログイン項目の登録とアプリへの再ログインはやり直さなくてよい（Keychainのトークンは、同じバンドルID・同じ証明書のビルドならそのまま使える）。

## 完了報告

以下をまとめてユーザーに報告する（「動いた」と言う場合は、実際のコマンド出力を添える）:

- macOS / Xcode のバージョン
- テスト結果
- ビルド結果
- 手順6の検証結果（プロファイル数・権限・VERIFY_OK）
- 起動状態（PIDと親PID）とログイン項目への登録結果
- 発生したエラーとその対処、ユーザーに残っている作業（ChatGPTへのログインなど）
