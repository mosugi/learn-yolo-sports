# ビルドチェックリスト

## ✅ セットアップ手順

1. **YOLOモデルを用意する**
   ```bash
   ./scripts/setup_model.sh
   ```
   `learn-yolo-sports/MLModels/FootballPlayerDetector.mlpackage` が作成されればOK

2. **Xcodeでプロジェクトを開いてビルド**
   - Product → Build (⌘B)
   - `learn-yolo-sports/` 配下のファイルはフォルダ同期で自動的にターゲットに含まれるため、手動でのファイル追加やターゲットメンバーシップの設定は不要です

3. **実行**
   - Product → Run (⌘R)

コマンドラインでビルドする場合:
```bash
xcodebuild -project learn-yolo-sports.xcodeproj -scheme learn-yolo-sports \
  -destination 'generic/platform=iOS Simulator' build
```

## 🐛 エラーが出る場合

### "Cannot find 'XXX' in scope"
→ ファイルが `learn-yolo-sports/` フォルダの外（例: `.xcodeproj` の中）に置かれていないか確認

### setup_model.sh の変換が失敗する
→ `.model-build/` を削除して再実行
→ `only 0-dimensional arrays can be converted to Python scalars` は numpy が新しすぎる場合のエラー（スクリプトで固定済み）

### ビルドが通らない
→ Product → Clean Build Folder (⌘⇧K)
→ Derived Data を削除: Xcode → Settings → Locations → Derived Data → 削除

## 📱 稼働確認手順

1. **アプリ起動**
   - シミュレーターまたは実機で起動
   - コンソールに `✅ YOLOモデル読み込み完了: FootballPlayerDetector` が出ること

2. **情報タブ**を確認
   - アニメーションが表示されるか

3. **動画再生タブ**を確認
   - 動画を選択して再生できるか

4. **YOLO解析タブ**を確認（メイン機能）
   - 動画選択後、「サッカー検出モデル」と表示されるか（「モックモード」ならモデル未配置）
   - ⚙️ボタンで設定画面が開くか
   - "解析開始" で進捗バーが表示されるか
   - 解析完了後、選手・審判・ボールにバウンディングボックスが表示されるか
   - スライダーでフレーム切り替えができるか
   - 検出リスト・統計情報が表示されるか

## 🎉 次のステップ

1. 選手のトラッキング（フレーム間の同一人物の追跡）
2. チーム分類（ユニフォームの色で分ける）
3. リアルタイム解析機能を追加
4. 結果の保存・共有機能を追加
