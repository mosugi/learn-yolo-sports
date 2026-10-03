#!/bin/bash
# サッカー検出用 YOLO モデルをダウンロードし、Core ML 形式に変換してプロジェクトに配置する
#
# モデル: https://huggingface.co/mobadam/football-player-detection (YOLO26l / Apache-2.0)
# クラス: ball, player, referee, goalkeeper
#
# 必要なもの: macOS, uv (https://docs.astral.sh/uv/)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.model-build"
DEST="$ROOT/learn-yolo-sports/MLModels/FootballPlayerDetector.mlpackage"
WEIGHTS_URL="https://huggingface.co/mobadam/football-player-detection/resolve/main/player_detector.pt"

mkdir -p "$WORK"
cd "$WORK"

if [ ! -f football-player-detection.pt ]; then
    echo "⬇️  モデルの重みをダウンロード中..."
    curl -fL -o football-player-detection.pt "$WEIGHTS_URL"
fi

if [ ! -d .venv ]; then
    echo "🐍 Python 環境を作成中..."
    uv venv -q -p 3.12 .venv
fi
# coremltools 9.0 は新しすぎる torch / numpy では変換に失敗するためバージョンを固定する
uv pip install -q --python .venv/bin/python \
    ultralytics coremltools==9.0 "torch==2.7.0" "torchvision==0.22.0" "numpy<2.3"

echo "🔄 Core ML に変換中 (NMS 込み, FP16)..."
rm -rf football-player-detection.mlpackage
.venv/bin/yolo export model=football-player-detection.pt format=coreml nms=True half=True imgsz=640

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mv football-player-detection.mlpackage "$DEST"

echo "✅ 配置完了: ${DEST#$ROOT/}"
echo "   Xcode でビルドすると自動でアプリに組み込まれます"
