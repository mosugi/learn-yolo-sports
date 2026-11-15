# ⚽️ Sports Video Analyzer with YOLO

サッカー動画をYOLOで解析するiOSアプリ

## ✨ 機能

### 1. 動画を選ぶだけで全自動解析
- フォトライブラリから動画を選ぶと、検出 → 選手の追跡と識別 → シーンの区切り → AI 解説の生成まで自動で進む（コートやチームの事前設定は不要）
- 動画の読み込み（iCloud からのダウンロードを含む）中は進捗・経過時間・残り時間を表示し、キャンセル可能
- 解析中も他のタブを操作可能。アプリをバックグラウンドに移しても `BGContinuedProcessingTask` で継続し、タブバーのアクセサリとバッジで進捗と残り時間を表示
- 途中で止めても、検出済みのフレームから再開できる（アプリを終了しても再開可能）

### 2. YOLO 物体検出
- 動画全体から 1 秒に 3 フレームを取り出し、サッカー用 YOLO モデルでボール・選手・審判・ゴールキーパーを検出
- 画像は 1 秒に 1 枚だけ保存し、容量を抑える

### 3. 選手の追跡と識別
- カメラが左右に振られる動画を前提に、フレーム間の位置合わせ（Vision）でカメラの動きを求め、動画全体で共通の位置で追跡する
- 距離は写っている人の身長（枠の高さ）を単位にし、遠近で大きさが変わっても同じ基準で対応付ける
- ユニフォームの色（L\*a\*b\* 色空間の 2クラス k-means）でチームを分け、追跡ごとの重み付き多数決でチームを確定。床（芝）の色の画素は除いて色を取る
- 大きく写る選手の背中を Vision の文字認識で読み取り、追跡ごとの多数決で背番号を決める
- 選手は背番号が読めれば「#10」、読めなければ登場順に「A」「B」…の記号で呼ぶ。同じチームで時間の重なる追跡に同じ背番号は付けない
- フレームごとに床の色を求め、その上に立っていない人（観客席など）をコート外として除く

### 4. シーンと戦術ボード
- ボール周辺の密集度・画面端への接近・ボールの速さから重要シーンを区切り、チャプターとして表示
- 各シーンの注目時点で、ボール保持者が取れるパス・ドリブルの選択肢を番号付きの矢印で表示（受け手は #10、A などの呼び名で示す）
- 動画の再生位置に合わせて、そのシーンの解説カードが切り替わる

### 5. AI 解説（Apple Intelligence）
- シーンごとに見出し・状況説明・アドバイスと、選択肢それぞれの評価・おすすめを生成
- 動画全体の総評・観察ポイント・改善提案を生成
- Apple Intelligence 非対応端末・未有効化の場合は理由を表示し、フォアグラウンドに戻ったときに再試行する

### 6. 解析結果の保存と共有
- 解析完了時に自動保存し、「履歴」タブから見返し・削除が可能
- 共有メニューから LLM 向けテキスト（前提・識別した選手・シーン別解説・集計・依頼文）や JSON を ChatGPT / Claude などへ共有


## 🏗️ アーキテクチャ

```
learn-yolo-sports/
├── learn_yolo_sportsApp.swift         # エントリーポイント
├── LaunchOptions.swift                # 起動引数（スクリーンショット用）
├── Models/
│   ├── DetectionModels.swift          # 検出・色名・クラス
│   ├── ColorModels.swift              # 色（Lab）、ユニフォームの色・床の色の取得
│   ├── SavedAnalysis.swift            # 保存用モデル
│   ├── AnalysisTimeline.swift         # チーム・選手・シーン・選択肢
│   ├── AnalysisCheckpoint.swift       # 中断した解析の再開情報
│   └── AnalysisMetrics.swift          # 画面上の位置の指標（AI への入力）
├── Services/
│   ├── VideoFrameExtractor.swift      # フレームの抽出
│   ├── VideoImporter.swift            # 動画の取り込みと進捗
│   ├── YOLODetector.swift             # YOLO検出エンジン
│   ├── PlayerAttributeAnalyzer.swift  # ユニフォームの色・コート内の判定・背番号・カメラの動き
│   ├── PlayerTracker.swift            # 追跡・チームと背番号の多数決・選手の呼び名
│   ├── TeamClassifier.swift           # チームの代表色
│   ├── SceneSegmenter.swift           # 重要シーンの区切り
│   ├── TacticalPlanner.swift          # パス・ドリブルの選択肢
│   ├── ContinuedProcessingSession.swift # バックグラウンド継続
│   ├── AnalysisStore.swift            # 解析結果・途中経過の保存
│   ├── AnalysisReport.swift           # LLM 向けテキスト生成
│   ├── IntelligenceAdvisor.swift      # Apple Intelligence の解説
│   └── DemoData.swift                 # スクリーンショット用のデモデータ
├── Views/
│   ├── ContentView.swift              # メインタブビュー
│   ├── VideoAnalysisView.swift        # 動画選択・解析の進捗
│   ├── VideoPlayerView.swift          # 動画プレーヤー
│   ├── AnalysisResultView.swift       # 解析結果（再生・解説・選手・チャプター・総評）と共有
│   ├── TacticalBoardView.swift        # 選択肢の矢印と戦術ボード
│   ├── DetectionOverlayView.swift     # 検出結果と選手の呼び名の重ね表示
│   ├── AnalysisProgressAccessory.swift # タブバーの進捗表示
│   ├── HistoryView.swift              # 解析履歴・中断した解析
│   └── InfoView.swift                 # アプリ情報
├── ViewModels/
│   └── VideoAnalysisViewModel.swift   # 解析パイプライン
└── MLModels/
    └── FootballPlayerDetector.mlpackage  # setup_model.sh で生成（git 管理外）
scripts/
├── setup_model.sh                     # モデルのダウンロードと Core ML 変換
└── generate_app_icon.swift            # アプリアイコンの生成
learn-yolo-sportsUITests/
└── ScreenshotTests.swift              # App Store 用スクリーンショット撮影
fastlane/                              # TestFlight 配信・申請情報（docs/STORE_RELEASE.md）
.github/workflows/
├── ci.yml                             # PR ごとのビルド確認
└── release.yml                        # fastlane（TestFlight 配信・申請情報の入力）
docs/
├── YOLO_SETUP_GUIDE.md                # YOLOモデルのセットアップ詳細
├── BUILD_CHECKLIST.md                 # ビルド・稼働確認チェックリスト
└── STORE_RELEASE.md                   # App Store 配信（fastlane × GitHub Actions）
```

## 📦 App Store 配信

fastlane と GitHub Actions で、TestFlight 配信・申請情報の入力・スクリーンショット撮影を自動化しています。`main` への push で TestFlight に配信されます。初回セットアップと各レーンの説明は [docs/STORE_RELEASE.md](docs/STORE_RELEASE.md) を参照してください。

## 🚀 使い方

### 1. セットアップ

1. YOLOモデルを用意する（[uv](https://docs.astral.sh/uv/) が必要）
   ```bash
   ./scripts/setup_model.sh
   ```
2. Xcodeでプロジェクトを開く
3. ビルド&実行 (⌘R)

モデルを配置しなくてもビルドは通り、その場合はランダムな検出結果を返すモックモードで動作します。詳しくは [docs/YOLO_SETUP_GUIDE.md](docs/YOLO_SETUP_GUIDE.md) を参照してください。

### 2. 動画解析

1. **「YOLO解析」タブ**で**「動画を選択」**をタップし、フォトライブラリから動画を選ぶ
2. 解析が自動で始まる（他のタブに移っても、アプリを閉じても続く。「一時停止」で止めて後から再開もできる）
3. 完了すると、動画の再生に合わせてシーンの解説・選択肢の矢印・選手の呼び名が表示される
4. 「選手」の #10 や A をタップすると、その選手が最初に写った場面へ移動する

## 📱 必要な権限

プロジェクトのビルド設定（`INFOPLIST_KEY_*`）で以下の権限を設定しています:

- **NSPhotoLibraryUsageDescription**: フォトライブラリアクセス
- **NSCameraUsageDescription**: カメラアクセス（将来の機能用）
- **NSMicrophoneUsageDescription**: マイクアクセス（将来の機能用）

バックグラウンド解析用の `BGTaskSchedulerPermittedIdentifiers` は `learn-yolo-sports-Info.plist` に記載し、生成される Info.plist にマージしています。

## 🤖 YOLOモデルについて

[mobadam/football-player-detection](https://huggingface.co/mobadam/football-player-detection)（YOLO26l, Apache-2.0）を使用しています。サッカー中継映像で学習されたモデルです。

`scripts/setup_model.sh` が重みのダウンロード、Core ML への変換（NMS 込み・FP16、約48MB）、プロジェクトへの配置までを行います。手順の詳細やモデルの差し替え方法は [docs/YOLO_SETUP_GUIDE.md](docs/YOLO_SETUP_GUIDE.md) を参照してください。

## 🎨 検出クラスと色

| クラス | 色 | 日本語名 |
|--------|-----|----------|
| ball | 🔴 Red | ボール |
| player | 🔵 Blue | 選手 |
| referee | 🟡 Yellow | 審判 |
| goalkeeper | 🟢 Green | ゴールキーパー |

## 🔧 技術スタック

- **SwiftUI**: UI構築
- **AVFoundation**: 動画処理
- **Vision**: Core ML統合
- **Core ML**: 機械学習推論
- **Swift Concurrency**: 非同期処理（async/await, Actor）
- **Observation**: 状態管理（@Observable）
- **BackgroundTasks**: バックグラウンド継続（BGContinuedProcessingTask）
- **Foundation Models**: オンデバイス LLM によるアドバイス

## 📚 参考

- [mobadam/football-player-detection](https://huggingface.co/mobadam/football-player-detection)
- [Roboflow Sports](https://github.com/roboflow/sports)
- [YOLOv8](https://github.com/ultralytics/ultralytics)
- [Apple Vision Framework](https://developer.apple.com/documentation/vision)
- [Core ML](https://developer.apple.com/documentation/coreml)

## 🐛 トラブルシューティング

### 動画が選択できない
- ビルド設定に `INFOPLIST_KEY_NSPhotoLibraryUsageDescription` があるか確認
- アプリをアンインストールして再インストール

### 解析が遅い
- フレームレートを下げる（1〜2 FPS）
- 最大フレーム数を減らす（10〜20フレーム）

### モックモードになる（モデルが読み込まれない）
- `./scripts/setup_model.sh` を実行したか確認
- `learn-yolo-sports/MLModels/FootballPlayerDetector.mlpackage` があるか確認
- Product → Clean Build Folder (⌘⇧K) してから再ビルド

## 📝 ライセンス

MIT License

## 👨‍💻 作成者

mosugi - 2026/10/03

---

Enjoy analyzing sports videos! ⚽️
