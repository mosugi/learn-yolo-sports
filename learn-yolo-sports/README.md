# 🏀 Sports Video Analyzer with YOLO

スポーツ動画をYOLOで解析するiOSアプリ

## ✨ 機能

### 1. 動画読み込み
- フォトライブラリから動画を選択
- 動画情報の表示（解像度、FPS、長さ）
- ビルトインプレーヤーで再生

### 2. YOLO物体検出
- 動画からフレームを自動抽出
- 各フレームでYOLO物体検出
- スポーツ関連オブジェクトの検出:
  - 👤 人
  - ⚽️ ボール
  - 🎾 テニスラケット
  - ⚾️ バット
  - 🏂 スケートボード、サーフボード、スノーボード
  - その他

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

## 🏗️ アーキテクチャ

```
learn-yolo-sports/
├── Models/
│   └── DetectionModels.swift          # データモデル
├── Services/
│   ├── VideoFrameExtractor.swift      # フレーム抽出
│   └── YOLODetector.swift             # YOLO検出エンジン
├── Views/
│   ├── ContentView.swift              # メインタブビュー
│   ├── VideoPickerView.swift          # 動画選択
│   ├── VideoPlayerView.swift          # 動画プレーヤー
│   ├── VideoAnalysisView.swift        # 解析メインビュー
│   ├── DetectionOverlayView.swift     # 検出結果表示
│   └── InfoView.swift                 # アプリ情報
├── ViewModels/
│   └── VideoAnalysisViewModel.swift   # 解析ロジック
└── Info.plist                         # アプリ権限設定
```

## 🚀 使い方

### 1. セットアップ

1. Xcodeでプロジェクトを開く
2. Info.plistがプロジェクトに追加されていることを確認
3. ビルド&実行 (⌘R)

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

Info.plistに以下の権限が設定されています:

- **NSPhotoLibraryUsageDescription**: フォトライブラリアクセス
- **NSCameraUsageDescription**: カメラアクセス（将来の機能用）
- **NSMicrophoneUsageDescription**: マイクアクセス（将来の機能用）

## 🤖 YOLOモデルについて

現在、このアプリは**モックモード**で動作しています。実際のYOLO検出を行うには:

### Core MLモデルの追加

1. **YOLOv8モデルを取得**
   - [Ultralytics YOLOv8](https://github.com/ultralytics/ultralytics)
   - または [Roboflow](https://roboflow.com/) でカスタムモデルを作成

2. **Core ML形式に変換**
   ```bash
   pip install ultralytics
   yolo export model=yolov8n.pt format=coreml
   ```

3. **Xcodeに追加**
   - `.mlmodel` ファイルをプロジェクトにドラッグ&ドロップ
   - ターゲットメンバーシップを確認

4. **YOLODetector.swift を更新**
   ```swift
   private func loadModel() async {
       do {
           let config = MLModelConfiguration()
           let model = try YOLOv8(configuration: config)
           self.model = try VNCoreMLModel(for: model.model)
           print("✅ YOLOモデル読み込み完了")
       } catch {
           print("❌ モデル読み込みエラー: \(error)")
       }
   }
   ```

## 🎨 検出クラスと色

| クラス | 色 | 日本語名 |
|--------|-----|----------|
| person | 🔵 Blue | 人 |
| sports ball | 🔴 Red | ボール |
| baseball bat | 🟠 Orange | バット |
| tennis racket | 🟢 Green | ラケット |
| skateboard | 🟣 Purple | スケートボード |
| surfboard | 🔷 Cyan | サーフボード |
| skis | 🟡 Yellow | スキー |
| snowboard | 🌸 Pink | スノーボード |
| frisbee | 🌿 Mint | フリスビー |
| kite | 🟦 Indigo | 凧 |

## 🔧 技術スタック

- **SwiftUI**: UI構築
- **AVFoundation**: 動画処理
- **Vision**: Core ML統合
- **Core ML**: 機械学習推論
- **Swift Concurrency**: 非同期処理（async/await, Actor）
- **Observation**: 状態管理（@Observable）

## 📚 参考

- [Roboflow Sports](https://github.com/roboflow/sports)
- [YOLOv8](https://github.com/ultralytics/ultralytics)
- [Apple Vision Framework](https://developer.apple.com/documentation/vision)
- [Core ML](https://developer.apple.com/documentation/coreml)

## 🐛 トラブルシューティング

### 動画が選択できない
- Info.plistに `NSPhotoLibraryUsageDescription` が設定されているか確認
- アプリをアンインストールして再インストール

### 解析が遅い
- フレームレートを下げる（1〜2 FPS）
- 最大フレーム数を減らす（10〜20フレーム）

### モデルが読み込まれない
- YOLODetector.swiftでモデルのロードコードが正しいか確認
- .mlmodelファイルがターゲットに含まれているか確認

## 📝 ライセンス

MIT License

## 👨‍💻 作成者

mosugi - 2026/10/03

---

Enjoy analyzing sports videos! 🏀⚽️🎾
