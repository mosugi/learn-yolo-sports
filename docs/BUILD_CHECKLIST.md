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

5. **コーチ解説**を確認
   - 「コート・チームの設定」でコートの4点と自チームの選手をタップし、点線のコートが実際のラインと重なること
   - 解析後の「検出結果」で、コート外の人が灰色の点線枠になり、選手が自チーム（水色）と相手（橙）に分かれること
   - 「コーチ解説」に場面ごとの静止画・俯瞰図・指摘が表示されること

## 🎉 次のステップ

1. 白線の自動検出（カメラが動く映像への対応、4点の手動指定の置き換え）
2. 判定規則の目安を、指導者がつけた場面と照合して調整
3. 前半・後半の攻撃方向の入れ替えへの対応
