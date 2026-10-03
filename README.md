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
- 検出のフレームレート (1〜10 FPS、推奨 3〜5)
- 解析する区間（開始位置と長さ、最長 45 分）
- フレームは1枚ずつ処理して手放すため、区間を長くしてもメモリは増えない

### 5. バックグラウンド解析と進捗表示
- 解析中も他のタブを操作可能。アプリをバックグラウンドに移しても `BGContinuedProcessingTask` で解析を継続
- タブバー上のアクセサリと解析タブのバッジで進捗を表示（どのタブからでもキャンセル可能）

### 6. 解析結果の保存と共有
- 解析完了時に自動保存し、「履歴」タブから見返し・削除が可能
- 共有メニューから LLM 向けテキスト（前提・集計・位置指標・フレーム別サマリ・依頼文）や JSON を ChatGPT / Claude などへ共有

### 7. AIアドバイス（Apple Intelligence）
- コーチ解説がある場合は、判定済みの場面と集計だけを渡して言語化させる（数値の解釈は LLM にさせない）
- コート設定なしの解析では、画面上の位置などの指標から総評・観察ポイント・改善提案を生成
- Apple Intelligence 非対応端末・未有効化の場合は理由を表示

### 8. コート・チームの設定
- 解析の開始位置のフレームで、コートの4点（全体または左右の半分）をタップして指定（ドラッグで微調整）
- 自チームの選手のユニフォームをタップして色を登録し、攻撃方向・形式（11人制 / 8人制 / フットサル）・寸法を指定
- 指定した4点から画像とピッチ（m）の射影変換を求め、足元がコート外の人、写る大きさが足元の位置と合わない人（奥の別コートの選手）を除外する
- コート周辺だけを切り出して YOLO に入力するため、背景の誤検出が減り、選手が大きく写る
- カメラを固定して撮影した動画が対象。設定時の画像から位置がずれたフレームは戦術分析から除外する

### 9. コーチ解説
- ユニフォームの色（L\*a\*b\* 色空間の 2クラス k-means）でチームを分け、ピッチ座標上の追跡結果ごとに多数決で確定
- ボールに最も近い選手からボール保持を判定し（0.6 秒続いたら確定）、攻撃・守備・2つの切り替えの4局面に分類
- 局面ごとに次の規則で判定し、課題3件・良い点2件までの場面を選ぶ

| 規則 | 局面 | 見る値 | 目安（11人制） |
|---|---|---|---|
| 縦の間延び / コンパクトさ | 守備 | フィールドプレーヤーの縦幅 | 42 m 超で課題、32 m 以下で良い点 |
| スライド | 守備 | チームの重心とボールの横方向の距離 | コート幅の 25% 超で課題 |
| 幅 | 攻撃 | フィールドプレーヤーの横幅 | コート幅の 45% 未満で課題、70% 以上で良い点 |
| サポート | 攻撃 | 保持者から 15 m 以内の味方 | 2 人未満で課題 |
| 失った直後の寄せ | 攻→守 | 3 秒以内にボールから 6 m 以内へ寄せた人数 | 1 人以下で課題、3 人以上で良い点 |
| 奪った直後の前進 | 守→攻 | 3 秒で 6 m 以上前進した人数 | 1 人以下で課題、3 人以上で良い点 |

- 距離の目安はコートの長さに比例して換算する
- 各場面に、映像の静止画（チーム色の枠とコートのライン）、俯瞰図（戦術ボード）、根拠の数値、指摘、改善点を表示

### 10. 得点シーンのチャプター
- 「ボールがゴールの枠の中に見えた」後、8〜150 秒以内に「ボールがセンターマークで止まり、両チームが自陣に並ぶ」キックオフが続いたら得点と判定
- ゴールへの侵入が見えていなくても、ゴール前でボールを見失った後にキックオフで再開した場合は「得点（推定）」として扱う
- ゴールへの侵入の後にプレーが続いていた場合（バーを越えたシュートの後のゴールキックなど）は除外
- 「得点」タブから、得点したチームがボールを持った時点（最大 25 秒前）から再生できる。YouTube の説明欄の形式でチャプターをコピーできる
- 判定できなかった得点は「検出結果」タブから手動で追加できる
- 試合全体を探す場合は、解析する長さを最長 45 分まで延ばし、2 FPS 程度で解析する

### 11. 背番号による選手別アドバイス
- コート設定で自チームの背番号と名前を任意で登録（「10 田中」のように1行に1人）
- 自チームの色に近く、大きく写る選手の背中を Vision の文字認識で読み取り、追跡ごとの多数決で背番号を決める（登録した番号以外は無視）
- 途切れた追跡を、位置・チーム・背番号が矛盾しない範囲でつなぎ直してから集計
- 「検出結果」タブで自チームの選手をタップすると、背番号を手動で割り当て・修正できる（選手別の集計にすぐ反映）
- 「選手」タブに、背番号ごとの位置の分布、移動距離、スプリント、ボール関与、失った直後の寄せ、奪った直後の前進と、それにもとづくアドバイスを表示
- 得点シーンの得点者（自チームで背番号が分かる場合）も推定する

## 🏗️ アーキテクチャ

```
learn-yolo-sports/
├── learn_yolo_sportsApp.swift         # エントリーポイント
├── Models/
│   ├── DetectionModels.swift          # データモデル
│   ├── SavedAnalysis.swift            # 保存用モデル
│   ├── AnalysisMetrics.swift          # 画面上の位置の指標（コート設定なしの解析用）
│   ├── AnalysisSetup.swift            # コート・チームの設定、色（Lab）
│   ├── PitchGeometry.swift            # 射影変換、コート判定
│   ├── CoachReport.swift              # コーチ解説のデータ
│   └── MatchChapter.swift             # 得点チャプター、選手別レポート
├── Services/
│   ├── VideoFrameExtractor.swift      # フレームの逐次抽出
│   ├── YOLODetector.swift             # YOLO検出エンジン
│   ├── KeyframeProcessor.swift        # 検出・コート判定・色の取得・画像保存
│   ├── MatchAnalyzer.swift            # チーム分類・追跡・ボール保持・局面
│   ├── CoachRules.swift               # 解説の判定規則と場面の選定
│   ├── GoalDetector.swift             # 得点シーンの検出
│   ├── PlayerAnalyzer.swift           # 背番号ごとの集計とアドバイス
│   ├── ContinuedProcessingSession.swift # バックグラウンド継続
│   ├── AnalysisStore.swift            # 解析結果の保存
│   ├── AnalysisReport.swift           # LLM 向けテキスト生成
│   └── IntelligenceAdvisor.swift      # Apple Intelligence アドバイス
├── Views/
│   ├── ContentView.swift              # メインタブビュー
│   ├── VideoPickerView.swift          # 動画選択
│   ├── VideoPlayerView.swift          # 動画プレーヤー
│   ├── VideoAnalysisView.swift        # 解析メインビュー
│   ├── AnalysisResultView.swift       # 解析結果表示・共有
│   ├── CourtSetupView.swift           # コート・チームの設定
│   ├── CoachReportView.swift          # コーチ解説
│   ├── PitchDiagramView.swift         # 俯瞰図（戦術ボード）
│   ├── ChaptersView.swift             # 得点チャプターと再生
│   ├── PlayersView.swift              # 選手別アドバイス、背番号の割り当て
│   ├── AnalysisProgressAccessory.swift # タブバーの進捗表示
│   ├── HistoryView.swift              # 解析履歴
│   ├── AdviceView.swift               # AIアドバイス
│   ├── DetectionOverlayView.swift     # 検出結果・コートのラインの重ね表示
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
4. ⚙️ボタンで解析する区間とフレームレートを調整
5. **「コート・チームの設定」**で、コートの4点と自チームの選手をタップし、攻撃方向と形式を指定
6. **「解析開始」**ボタンをタップ
7. 解析完了後、「解説」で場面ごとの解説、「得点」で得点シーン、「選手」で背番号ごとのアドバイス、「検出」でフレームごとの検出を確認

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

## 📝 ライセンス

MIT License

## 👨‍💻 作成者

mosugi - 2026/10/03

---

Enjoy analyzing sports videos! ⚽️
