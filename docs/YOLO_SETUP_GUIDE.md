# YOLOモデルのセットアップガイド

このアプリはサッカー用に学習された YOLO モデルを Core ML に変換して使います。モデルがない状態でもビルドは通り、その場合はランダムな検出結果を返すモックモードで動作します。

---

## 使用モデル

| 項目 | 内容 |
|------|------|
| モデル | [mobadam/football-player-detection](https://huggingface.co/mobadam/football-player-detection) |
| ベース | YOLO26l（Ultralytics） |
| ライセンス | Apache-2.0 |
| クラス | `ball`, `player`, `referee`, `goalkeeper` |
| 変換後サイズ | 約48MB（FP16, NMS 込み） |

モデルファイルは大きいので git には含めず、下のスクリプトで各自生成します。

---

## セットアップ（推奨: スクリプト）

必要なもの: macOS, [uv](https://docs.astral.sh/uv/)

```bash
./scripts/setup_model.sh
```

スクリプトは次の処理を行います:

1. Hugging Face から重み (`player_detector.pt`) をダウンロード
2. `.model-build/.venv` に Python 3.12 の環境を作り、ultralytics と coremltools をインストール
3. Core ML に変換（NMS 込み・FP16）
   ```bash
   yolo export model=football-player-detection.pt format=coreml nms=True half=True imgsz=640
   ```
4. `learn-yolo-sports/MLModels/FootballPlayerDetector.mlpackage` に配置

このプロジェクトはフォルダ同期型（`learn-yolo-sports/` 配下が自動でターゲットに入る）なので、Xcode へのドラッグ&ドロップやターゲットメンバーシップの設定は不要です。そのままビルドすると Xcode が `.mlpackage` を `.mlmodelc` にコンパイルしてアプリに組み込みます。

---

## 手動でセットアップする場合

```bash
uv venv -p 3.12 .venv && source .venv/bin/activate
uv pip install ultralytics coremltools==9.0 "torch==2.7.0" "torchvision==0.22.0" "numpy<2.3"

curl -L -o football-player-detection.pt \
  https://huggingface.co/mobadam/football-player-detection/resolve/main/player_detector.pt
yolo export model=football-player-detection.pt format=coreml nms=True half=True imgsz=640

mv football-player-detection.mlpackage learn-yolo-sports/MLModels/FootballPlayerDetector.mlpackage
```

> **バージョン固定が必要です。** coremltools 9.0 では、新しすぎる torch では変換に失敗し、numpy 2.3 以降では `only 0-dimensional arrays can be converted to Python scalars` というエラーで止まります。

---

## アプリ側の読み込み処理

`learn-yolo-sports/Services/YOLODetector.swift` がバンドル内の `FootballPlayerDetector.mlmodelc` を読み込みます。Xcode が自動生成するクラスは使っていないので、モデルがなくてもコンパイルエラーにはなりません。

```swift
guard let url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
    // モックモード
}
let mlModel = try MLModel(contentsOf: url, configuration: config)
self.model = try VNCoreMLModel(for: mlModel)
```

- `nms=True` で書き出したモデルは、Vision から `VNRecognizedObjectObservation` として結果を受け取れます
- 入力画像はアスペクト比を保ってリサイズします（`imageCropAndScaleOption = .scaleFit`）
- Vision の座標系（左下原点）は、画像の座標系（左上原点）に変換してから表示しています

---

## 別のモデルに差し替える

1. ultralytics の検出モデル（`.pt`）を `format=coreml nms=True` で書き出す
2. `learn-yolo-sports/MLModels/` に配置し、ファイル名を `YOLODetector.modelName` に合わせる（またはその値を変更する）
3. `Models/DetectionModels.swift` の `SportsClass` を、モデルのクラス名（`names`）に合わせる

たとえば COCO で学習した汎用モデル（`yolov8s.pt` など）を使う場合、ラベルは `person` や `sports ball` などになります。

---

## 動作確認

1. アプリをビルド&実行 (⌘R)
2. コンソールを確認
   - `✅ YOLOモデル読み込み完了: FootballPlayerDetector` → 実モデルで動作
   - `⚠️ FootballPlayerDetector.mlmodelc が見つかりません。モックモードで動作します。` → モデル未配置
3. 「YOLO解析」タブで動画を選ぶと、画面に「サッカー検出モデル」または「モックモード（モデル未配置）」と表示されます

---

## トラブルシューティング

### モックモードになる
- `./scripts/setup_model.sh` を実行したか確認
- `learn-yolo-sports/MLModels/FootballPlayerDetector.mlpackage` があるか確認
- Product → Clean Build Folder (⌘⇧K) してから再ビルド

### 変換が失敗する
- `.model-build/` を削除してからスクリプトを再実行

### 解析が遅い・メモリ不足
- YOLO26l は大きめのモデルです。最大フレーム数を 10〜20 に減らす
- シミュレーターより実機のほうが高速です（Neural Engine を使えるため）
