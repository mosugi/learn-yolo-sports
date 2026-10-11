# ⚽️ Sports Video Analyzer with YOLO

サッカー動画をYOLOで解析するiOSアプリ

## ✨ 機能

### 1. 動画読み込み
- フォトライブラリから動画を選択
- 動画情報の表示（解像度、FPS、長さ）
- ビルトインプレーヤーで再生

### 2. YOLO物体検出
- 動画からフレームを自動抽出
- 各フレームでYOLO物体検出
- サッカー用YOLOモデルで以下を検出:
  - ⚽️ ボール
  - 🏃 選手
  - 🧑‍⚖️ 審判
  - 🧤 ゴールキーパー

### 3. 結果表示
- バウンディングボックスのオーバーレイ表示
- 検出オブジェクトのリスト表示
- フレーム間のナビゲーション（スライダー、ボタン）
- 統計情報:
  - 総検出数
  - フレームあたりの平均検出数
  - 処理時間

### 4. カスタマイズ設定
- フレーム抽出レート (1〜10 FPS)
- 最大フレーム数 (10〜100)

### 5. バックグラウンド解析と進捗表示
- 解析中も他のタブを操作可能。アプリをバックグラウンドに移しても `BGContinuedProcessingTask` で解析を継続
- タブバー上のアクセサリと解析タブのバッジで進捗を表示（どのタブからでもキャンセル可能）

### 6. 解析結果の保存と共有
- 解析完了時に自動保存し、「履歴」タブから見返し・削除が可能
- 共有メニューから LLM 向けテキスト（前提・集計・位置指標・フレーム別サマリ・依頼文）や JSON を ChatGPT / Claude などへ共有

### 7. AIアドバイス（Apple Intelligence）
- Foundation Models のオンデバイス LLM が、位置や密集度などの指標から総評・観察ポイント・改善提案を生成
- Apple Intelligence 非対応端末・未有効化の場合は理由を表示

### 8. チーム判定と場面ごとの選択肢
- 胸部分の色の中央値を L*a*b* 空間で k-means にかけ、2チームに分ける（明るさの重みを下げて日なた・日陰の差を抑え、審判などの外れ値は除外）
- 各シーンの注目時点で、ボール保持者からのパス・ドリブルの選択肢を最大3つ計算し、番号付きの矢印で表示（おすすめは黄色）
- Apple Intelligence が各選択肢の利点・リスクとおすすめを解説

## 🏗️ アーキテクチャ

```
learn-yolo-sports/
├── learn_yolo_sportsApp.swift         # エントリーポイント
├── Models/
│   ├── DetectionModels.swift          # データモデル
│   ├── SavedAnalysis.swift            # 保存用モデル
│   └── AnalysisMetrics.swift          # 位置・密集度などの指標
├── Services/
│   ├── VideoFrameExtractor.swift      # フレーム抽出
│   ├── YOLODetector.swift             # YOLO検出エンジン
│   ├── ContinuedProcessingSession.swift # バックグラウンド継続
│   ├── AnalysisStore.swift            # 解析結果の保存
│   ├── AnalysisReport.swift           # LLM 向けテキスト生成
│   ├── IntelligenceAdvisor.swift      # Apple Intelligence アドバイス
│   ├── TeamClassifier.swift           # ユニフォーム色によるチーム分け
│   ├── SceneSegmenter.swift           # 重要シーンの区切り
│   └── TacticalPlanner.swift          # 場面ごとの選択肢（パス・ドリブル）の計算
├── Views/
│   ├── ContentView.swift              # メインタブビュー
│   ├── VideoPickerView.swift          # 動画選択
│   ├── VideoPlayerView.swift          # 動画プレーヤー
│   ├── VideoAnalysisView.swift        # 解析メインビュー
│   ├── AnalysisResultView.swift       # 解析結果表示・共有
│   ├── AnalysisProgressAccessory.swift # タブバーの進捗表示
│   ├── HistoryView.swift              # 解析履歴
│   ├── AdviceView.swift               # AIアドバイス
│   ├── DetectionOverlayView.swift     # 検出結果表示
│   ├── TacticalBoardView.swift        # 選択肢の矢印と一覧
│   └── InfoView.swift                 # アプリ情報
├── ViewModels/
│   └── VideoAnalysisViewModel.swift   # 解析ロジック
└── MLModels/
    └── FootballPlayerDetector.mlpackage  # setup_model.sh で生成（git 管理外）
scripts/
└── setup_model.sh                     # モデルのダウンロードと Core ML 変換
docs/
├── YOLO_SETUP_GUIDE.md                # YOLOモデルのセットアップ詳細
└── BUILD_CHECKLIST.md                 # ビルド・稼働確認チェックリスト
```

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

1. **「YOLO解析」タブ**を開く
2. **「動画を選択」**ボタンをタップ
3. フォトライブラリから解析したい動画を選択
4. （オプション）⚙️ボタンで設定を調整
5. **「解析開始」**ボタンをタップ
6. 解析完了後、フレームをスライダーで切り替えながら結果を確認

### 3. シンプルな再生

**「動画再生」タブ**で動画の選択と再生のみ行えます。

## ⚙️ 設定

### フレームレート
- **低 (1〜2 FPS)**: 高速処理、概要把握に最適
- **中 (3〜5 FPS)**: バランスの取れた解析
- **高 (6〜10 FPS)**: 詳細な解析、処理時間長

### 最大フレーム数
- 動画全体を解析したい場合は多めに設定
- テストや高速確認したい場合は少なめに設定

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

## 🚢 App Store 提出準備

### 実施済み（2026/10/10）

| 項目 | 内容 |
|------|------|
| App ID | `com.mosugi.learn-yolo-sports`（Team `LHSVZBJ4CR`、Xcode 自動署名で登録済み） |
| App Store Connect レコード | 名前「サッカー動画解析」/ Apple ID `6821265172` / SKU `learn-yolo-sports` / プライマリ言語 日本語 / ユーザアクセス 制限なし |
| カテゴリ | プライマリ: スポーツ、セカンダリ: 写真／ビデオ |
| 価格 | 無料（基準国 アメリカ合衆国 $0.00） |
| 配信状況 | すべての国または地域（175） |
| 輸出コンプライアンス | ビルド設定に `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` を追加（独自暗号化なし） |
| 表示名 | ビルド設定 `INFOPLIST_KEY_CFBundleDisplayName = サッカー動画解析`（ホーム画面の名前） |
| アプリアイコン | `scripts/generate_app_icon.swift` で生成（ライト / ダーク / ティントの 1024×1024） |
| プライバシーポリシー URL | https://privacy.mosugi.com/ |
| TestFlight | ビルド 1.0 (1)・(2) をアップロードし、内部テスター mosugix@gmail.com に配信 |

### TestFlight へのアップロード手順

TestFlight の内部グループ「Internal」（自動配信オン）に mosugix@gmail.com を登録済み。新しいビルドをアップロードすると自動で配信される。

```bash
./scripts/setup_model.sh   # モデル未配置の場合のみ（未配置だとモックモードのビルドになる）
xcodebuild -project learn-yolo-sports.xcodeproj -scheme learn-yolo-sports -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/learn-yolo-sports.xcarchive \
  -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/learn-yolo-sports.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export -allowProvisioningUpdates
```

`ExportOptions.plist` は `method = app-store-connect`、`destination = upload`、`teamID = LHSVZBJ4CR`、`manageAppVersionAndBuildNumber = true`（ビルド番号を自動で繰り上げ）。Xcode に Apple アカウントでサインインしている必要がある。

### 残作業

1. **プライバシーマニフェスト**: `PrivacyInfo.xcprivacy` を追加し、Required Reason API（`UserDefaults` やファイルタイムスタンプなど）の利用理由を記載
2. **アプリのプライバシー（栄養ラベル）**: 通信・外部送信なし、解析はオンデバイス、共有はユーザ操作のみのため「データを収集しない」で回答予定
3. **年齢制限指定**: 「アプリ情報」の質問票に回答
4. **バージョン 1.0 のメタデータ**: スクリーンショット（6.9 インチ iPhone 必須、iPad 対応なら 13 インチも）、説明文、キーワード、サポート URL、著作権
5. **App Review 情報**: 連絡先、審査メモ（YOLO モデル同梱であること、Apple Intelligence 非対応端末の挙動など）
6. **審査提出**: バージョン 1.0 に TestFlight 済みのビルドを紐付けて審査提出
7. **EU 配信**: デジタルサービス法のトレーダーステータス未提供（未提供だと EU で配信されない）

## 📝 ライセンス

MIT License

## 👨‍💻 作成者

mosugi - 2026/10/03

---

Enjoy analyzing sports videos! ⚽️
