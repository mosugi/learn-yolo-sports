# App Store 配信（fastlane × GitHub Actions）

TestFlight 配信、App Store の申請情報の入力、スクリーンショット撮影を fastlane と GitHub Actions で自動化しています。公開リポジトリで macOS ランナーが無料のため、ビルドを含めてすべて GitHub Actions で実行します。

構成は [mosugi/myapp-fastlane-demo](https://github.com/mosugi/myapp-fastlane-demo) をもとにしています。

## できること

| やること | 実行方法 | API キー |
|---|---|---|
| ビルド・署名・TestFlight 配信 | `main` へ push（または `lane=beta`） | 必要 |
| 申請情報の入力（説明文・スクショ・年齢制限・価格・配信地域・ビルド紐付けなど） | `lane=upload_metadata` | 必要 |
| スクリーンショット撮影 + 申請情報の入力 | `lane=screenshots` | 必要 |
| スクリーンショット撮影のみ（Artifacts に保存） | `lane=capture` | 不要 |
| TestFlight 配信 + 申請情報の入力 | `lane=release` | 必要 |
| App のプライバシー入力 | `fastlane upload_privacy`（ローカル） | Apple ID + 2FA |
| 審査への提出 | 下記コマンド（手動） | 必要 |

手動実行は Actions 画面の「Run workflow」、または次のコマンドで行います。

```bash
gh workflow run release.yml -f lane=upload_metadata
```

API キーの Secrets が未登録の間は、`main` への push で fastlane ワークフローが走っても何もせずに終了します（`capture` を除く）。

## 構成

```
.github/workflows/ci.yml           PR ごとのビルド確認（アプリ + UI テスト、署名なし）
.github/workflows/release.yml      fastlane の実行（レーン選択）
fastlane/
  Appfile                          Bundle ID / Team ID
  Fastfile                         レーン定義
  Gymfile                          ビルド設定
  Snapfile                         スクリーンショット撮影設定
  metadata/                        ストア情報（日本語）・審査用連絡先
  app_rating_config.json           年齢制限指定
  app_privacy_details.json         App のプライバシー
learn-yolo-sportsUITests/          スクリーンショット撮影用 UI テスト
PRIVACY.md                         プライバシーポリシー
```

### fastlane レーン

| レーン | 内容 |
|---|---|
| `beta` | YOLO モデルの配置を確認し、ビルド番号を「TestFlight 上の最新 + 1」にしてアーカイブ、TestFlight にアップロード。「テスト内容」には直近 5 件のコミットメッセージが入る |
| `upload_metadata` | `deliver` でストア情報・スクショ・年齢制限・審査用連絡先を入力し、API でコンテンツ配信権・価格（無料）・配信地域・審査対象ビルド（最新の処理済みビルド）を設定。**審査提出はしない** |
| `capture` | `capture_screenshots`（snapshot）でスクリーンショットを撮影 |
| `screenshots` | `capture` → `upload_metadata` |
| `upload_privacy` | App のプライバシー（データ収集なし）を入力・公開。Apple ID でログインする |
| `release` | `beta` → `upload_metadata` |

### YOLO モデル

モデル（`FootballPlayerDetector.mlpackage`）は git 管理外のため、`beta` / `release` では CI 上で `scripts/setup_model.sh` を実行して生成します。結果は `actions/cache` でキャッシュし、スクリプトを変更したときだけ作り直します。モデルが無い状態で `beta` を実行するとエラーで止まります（モックモードのアプリを配信しないため）。

### コード署名

証明書・プロビジョニングプロファイルの管理（match など）は不要です。`xcodebuild -allowProvisioningUpdates` に App Store Connect API キーを渡し、Xcode のクラウド署名で署名します。API キーは **Admin** 権限が必要です。

## 初回セットアップ手順

### 前提

- Apple Developer Program（有料）に加入済み
- `gh`（GitHub CLI）でログイン済み

### 1. App ID を登録する

[Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) > Identifiers > `+` > App IDs > App で、Bundle ID `com.mosugi.learn-yolo-sports`（Explicit）を登録します。

### 2. App Store Connect にアプリを作成する

[App Store Connect](https://appstoreconnect.apple.com/apps) > アプリ > `+` > 新規アプリ。プラットフォーム iOS、手順 1 の Bundle ID、**プライマリ言語は日本語**、名前・SKU を入力します。

> 名前は App Store 全体で一意である必要があります。`fastlane/metadata/ja/name.txt` と同じ名前が使えない場合は、両方を同じ名前に変更してください。

### 3. App Store Connect API キーを発行する

App Store Connect > ユーザーとアクセス > 統合 > App Store Connect API > **チームキー** で発行します（アクセス権は **Admin**）。Key ID・Issuer ID を控え、`.p8` をダウンロードします（一度しかダウンロードできません）。myapp-fastlane-demo で使っているキーをそのまま使うこともできます。

### 4. GitHub Secrets を登録する

```bash
gh secret set ASC_KEY_ID --body "Key ID"
```

```bash
gh secret set ASC_ISSUER_ID --body "Issuer ID"
```

```bash
gh secret set ASC_KEY_P8_BASE64 --body "$(base64 -i AuthKey_XXXXXXXXXX.p8)"
```

公開リポジトリでも Secrets はフォークからの PR には渡されません。fastlane ワークフローは `main` への push と手動実行でのみ動きます。

### 5. 初回配信

`main` に push するか `gh workflow run release.yml` を実行すると、TestFlight にビルドがアップロードされます。

### 6. テスターを登録する

App Store Connect > アプリ > TestFlight > 内部テスト でグループを作成し、テスターを追加します。「自動配信を有効にする」をオンにすると、以降のビルドが自動で届きます。

### 7. 申請情報を入力する

`fastlane/metadata/` などを編集してから実行します。

```bash
gh workflow run release.yml -f lane=screenshots
```

### 8. App のプライバシーを入力する（ローカルで一度だけ）

API キーでは操作できないため、Apple ID でログインします（2FA のコード入力あり）。この手順だけは GitHub Actions では実行できません。

```bash
bundle install
FASTLANE_USER=your-apple-id@example.com bundle exec fastlane upload_privacy
```

> 初回の公開時は App Store Connect の画面で「公開」を押す方が確実です。一度公開すれば、以降は変更時のみ実行します。

## 申請情報

| 項目 | ファイル |
|---|---|
| 名前・サブタイトル・概要・キーワード・プロモーション用テキスト | `fastlane/metadata/ja/*.txt` |
| サポート URL・マーケティング URL・プライバシーポリシー URL | `fastlane/metadata/ja/*_url.txt` |
| 著作権・カテゴリ（スポーツ） | `fastlane/metadata/copyright.txt`, `primary_category.txt` |
| 審査用連絡先・メモ | `fastlane/metadata/review_information/*.txt` |
| 年齢制限指定 | `fastlane/app_rating_config.json` |
| スクリーンショット（iPhone 6.9インチ・iPad 13インチ） | `fastlane/screenshots/ja/*.png`（`capture` で生成） |
| コンテンツ配信権・価格（無料）・配信地域（全地域） | `fastlane/Fastfile` |
| 審査対象ビルド | 最新の処理済みビルドを自動で選択 |
| 輸出コンプライアンス（暗号化） | `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` |
| App のプライバシー | `fastlane/app_privacy_details.json`（データ収集なし） |

**審査用連絡先（`review_information/` の氏名・メール・電話番号）はダミーです。** 申請前に実在の値に書き換えてください。

### 審査への提出

App Store Connect のバージョンページで「審査用に追加」を押すと、入力漏れが検証されます。審査に出す場合は次を実行します。

```bash
bundle exec fastlane deliver --submit_for_review --skip_binary_upload --skip_metadata --skip_screenshots --force
```

## スクリーンショットの自動撮影

- [`learn-yolo-sportsUITests/ScreenshotTests.swift`](../learn-yolo-sportsUITests/ScreenshotTests.swift) が起動引数で各画面を開いて撮影します（解析結果・AI アドバイス・履歴・解析開始画面）。
- 試合映像は権利の都合で同梱できないため、`-demoData YES` でピッチと選手を描いた画像・検出結果・アドバイスのデモデータを表示します（[`DemoData.swift`](../learn-yolo-sports/Services/DemoData.swift)）。乱数は固定シードなので毎回同じ画像になります。
- 撮影端末・言語は [`fastlane/Snapfile`](../fastlane/Snapfile)。端末名は GitHub Actions のランナーイメージにあるものに合わせています。
- CI の `capture` / `screenshots` レーンで撮影した画像は、ワークフローの Artifacts（`screenshots`）からダウンロードできます。リポジトリには書き戻しません。

## ハマりどころ（myapp-fastlane-demo で実際に起きたこと）

| 症状 | 原因と対処 |
|---|---|
| `invalid curve name (OpenSSL::PKey::ECError)` | API キーの Secret が空。Secrets を登録する |
| アップロードで失敗する | AppIcon（1024px、透過なし）が必須 |
| エクスポート時に署名できない | ビルド番号はビルド設定ではなく `increment_build_number` で設定する |
| 審査用連絡先の電話番号エラー | `+81 3 1234 5678` のように `+国番号` 始まり・スペース区切りで書く |
| 初回バージョンで「このバージョンの新機能」エラー | 初回は設定できない。`release_notes.txt` を置かない |
| 価格が設定できない | `deliver` の `price_tier` は廃止済み。Fastfile で `appPriceSchedules` を直接呼んでいる |
| snapshot で端末が見つからない | CI イメージにある端末名に合わせる |
| App のプライバシーを CI で入力できない | API キー非対応。Apple ID + 2FA が必要なのでローカルで実行 |
