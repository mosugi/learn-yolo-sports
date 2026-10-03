# ビルドチェックリスト

## ✅ 必要なファイル一覧

### コアファイル
- [x] learn_yolo_sportsApp.swift - アプリのエントリーポイント
- [x] ContentView.swift - メインビュー（3つのタブ）

### ビュー
- [x] VideoPickerView.swift - 動画選択画面
- [x] VideoPlayerView.swift - 動画プレーヤー
- [x] VideoAnalysisView.swift - YOLO解析メイン画面
- [x] DetectionOverlayView.swift - 検出結果の表示

### ビューモデル
- [x] VideoAnalysisViewModel.swift - 解析ロジック

### モデル
- [x] DetectionModels.swift - データモデル（Detection, SportsClass等）

### サービス
- [x] VideoFrameExtractor.swift - 動画からフレーム抽出
- [x] YOLODetector.swift - YOLO物体検出

### 設定
- [x] Info.plist - アプリ権限

### ドキュメント
- [x] README.md - プロジェクト説明

## 🔧 Xcodeでの確認手順

1. **プロジェクトナビゲーター**を開く (⌘1)
2. 以下のファイルがすべて表示されているか確認:
   - DetectionModels.swift
   - VideoFrameExtractor.swift
   - YOLODetector.swift
   - DetectionOverlayView.swift
   - VideoAnalysisViewModel.swift
   - VideoAnalysisView.swift
   - VideoPickerView.swift
   - VideoPlayerView.swift
   - ContentView.swift
   - Info.plist

3. **重複ファイルを削除**:
   - VideoPickerView 2.swift (削除)
   - VideoPlayerView 2.swift (削除)

4. **各ファイルのターゲットメンバーシップを確認**:
   - ファイルを選択
   - 右側のインスペクター (⌘⌥1)
   - "Target Membership" でアプリのターゲットにチェック

5. **Info.plistをプロジェクトに追加**:
   - プロジェクト設定 → TARGETS → learn-yolo-sports
   - Build Settings → Packaging
   - "Info.plist File" を "Info.plist" に設定

6. **クリーン&ビルド**:
   - Product → Clean Build Folder (⌘⇧K)
   - Product → Build (⌘B)

7. **実行**:
   - Product → Run (⌘R)

## 🐛 エラーが出る場合

### "Cannot find 'VideoPickerView' in scope"
→ VideoPickerView.swiftがターゲットに含まれていない
→ ファイルを右クリック → "Delete" → "Remove Reference"
→ 再度ファイルを追加: File → Add Files to "learn-yolo-sports"

### "Cannot find 'VideoAnalysisView' in scope"
→ VideoAnalysisView.swiftがターゲットに含まれていない
→ 同様に再追加

### ビルドが通らない
→ すべてのファイルを確認
→ インポート文が正しいか確認
→ Derived Data を削除: Xcode → Preferences → Locations → Derived Data → 削除

## 📱 稼働確認手順

1. **アプリ起動**
   - シミュレーターまたは実機で起動

2. **情報タブ**を確認
   - アニメーションが表示されるか

3. **動画再生タブ**を確認
   - "動画を選択" ボタンが表示されるか
   - フォトライブラリへのアクセス許可が求められるか
   - 動画を選択して再生できるか

4. **YOLO解析タブ**を確認（メイン機能）
   - "動画を選択" ボタンが表示されるか
   - 動画選択後、プレビューが表示されるか
   - ⚙️ボタンで設定画面が開くか
   - "解析開始" ボタンが機能するか
   - 解析中の進捗バーが表示されるか
   - 解析完了後、検出結果が表示されるか
   - スライダーでフレーム切り替えができるか
   - バウンディングボックスが表示されるか
   - 検出リストが表示されるか
   - 統計情報が表示されるか

## ✨ 成功の確認

すべてが正常に動作すれば:
- ✅ 3つのタブが表示される
- ✅ 動画を選択できる
- ✅ 動画を再生できる
- ✅ 解析を開始できる
- ✅ モック検出結果が表示される（ランダムなバウンディングボックス）
- ✅ フレームを切り替えられる
- ✅ 統計情報が表示される

## 🎉 次のステップ

稼働確認後:
1. 実際のYOLOモデルを追加
2. カスタムスポーツデータセットで学習
3. リアルタイム解析機能を追加
4. 結果の保存・共有機能を追加
