//
//  AllInOneApp.swift
//  learn-yolo-sports
//
//  統合版: すべてのコードを1ファイルに集約
//  ビルドエラーを回避するための一時的な解決策
//

import SwiftUI
import PhotosUI
import AVFoundation
import AVKit
import Vision
import CoreML
import CoreImage

// MARK: - Models

/// 検出されたオブジェクト
struct Detection: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect
    let color: Color
    
    var confidencePercentage: Int {
        Int(confidence * 100)
    }
}

/// スポーツ関連のクラスラベル
enum SportsClass: String, CaseIterable {
    case person = "person"
    case ball = "sports ball"
    case baseball = "baseball bat"
    case tennis = "tennis racket"
    case skateboard = "skateboard"
    case surfboard = "surfboard"
    case skis = "skis"
    case snowboard = "snowboard"
    case frisbee = "frisbee"
    case kite = "kite"
    
    var color: Color {
        switch self {
        case .person: return .blue
        case .ball: return .red
        case .baseball: return .orange
        case .tennis: return .green
        case .skateboard: return .purple
        case .surfboard: return .cyan
        case .skis: return .yellow
        case .snowboard: return .pink
        case .frisbee: return .mint
        case .kite: return .indigo
        }
    }
    
    var japaneseName: String {
        switch self {
        case .person: return "人"
        case .ball: return "ボール"
        case .baseball: return "バット"
        case .tennis: return "ラケット"
        case .skateboard: return "スケートボード"
        case .surfboard: return "サーフボード"
        case .skis: return "スキー"
        case .snowboard: return "スノーボード"
        case .frisbee: return "フリスビー"
        case .kite: return "凧"
        }
    }
}

/// フレームの検出結果
struct FrameDetectionResult: Identifiable {
    let id = UUID()
    let frameNumber: Int
    let timestamp: Double
    let detections: [Detection]
    let image: CGImage?
    
    var totalDetections: Int {
        detections.count
    }
}

/// 動画全体の解析結果
struct VideoAnalysisResult {
    let totalFrames: Int
    let processedFrames: Int
    let detectionResults: [FrameDetectionResult]
    let duration: TimeInterval
    
    var totalDetections: Int {
        detectionResults.reduce(0) { $0 + $1.totalDetections }
    }
    
    var averageDetectionsPerFrame: Double {
        guard processedFrames > 0 else { return 0 }
        return Double(totalDetections) / Double(processedFrames)
    }
}

// MARK: - Video Frame Extractor

actor VideoFrameExtractor {
    typealias ProgressHandler = (Int, Int) -> Void
    
    func extractFrames(
        from url: URL,
        fps: Int = 1,
        maxFrames: Int = 100,
        progressHandler: ProgressHandler? = nil
    ) async throws -> [CGImage] {
        
        let asset = AVAsset(url: url)
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoFrameExtractor", code: 1, userInfo: [NSLocalizedDescriptionKey: "動画トラックが見つかりません"])
        }
        
        let duration = try await asset.load(.duration)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        
        let reader = try AVAssetReader(asset: asset)
        
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        reader.add(output)
        reader.startReading()
        
        var frames: [CGImage] = []
        var frameCount = 0
        let frameInterval = max(1, Int(nominalFrameRate) / fps)
        
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if frameCount % frameInterval == 0 {
                if let cgImage = createCGImage(from: sampleBuffer) {
                    frames.append(cgImage)
                    progressHandler?(frames.count, maxFrames)
                    
                    if frames.count >= maxFrames {
                        break
                    }
                }
            }
            frameCount += 1
        }
        
        reader.cancelReading()
        print("✅ フレーム抽出完了: \(frames.count)フレーム")
        
        return frames
    }
    
    private func createCGImage(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        return cgImage
    }
}

// MARK: - YOLO Detector

actor YOLODetector {
    private var model: VNCoreMLModel?
    private let confidenceThreshold: Float = 0.25
    
    init() {
        Task {
            await loadModel()
        }
    }
    
    private func loadModel() async {
        print("🤖 YOLOモデルを読み込み中...")
        
        // YOLOv3 または YOLOv3-Tiny を試す
        if let modelURL = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc") {
            do {
                let mlModel = try MLModel(contentsOf: modelURL)
                model = try VNCoreMLModel(for: mlModel)
                print("✅ YOLOモデル読み込み完了")
                return
            } catch {
                print("❌ モデル読み込みエラー: \(error)")
            }
        }
        
        print("⚠️ YOLOモデルが見つかりません。モックモードで動作します。")
    }
    
    func detect(image: CGImage) async throws -> [Detection] {
        if model == nil {
            return generateMockDetections(for: image)
        }
        
        guard let model = model else {
            throw NSError(domain: "YOLODetector", code: 1, userInfo: [NSLocalizedDescriptionKey: "モデルが読み込まれていません"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: model) { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let results = request.results as? [VNRecognizedObjectObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                
                let detections = self.processResults(results, imageSize: CGSize(width: image.width, height: image.height))
                continuation.resume(returning: detections)
            }
            
            request.imageCropAndScaleOption = .scaleFill
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    private func processResults(_ results: [VNRecognizedObjectObservation], imageSize: CGSize) -> [Detection] {
        return results
            .filter { $0.confidence >= confidenceThreshold }
            .map { observation in
                let label = observation.labels.first?.identifier ?? "unknown"
                let confidence = observation.confidence
                
                let boundingBox = VNImageRectForNormalizedRect(
                    observation.boundingBox,
                    Int(imageSize.width),
                    Int(imageSize.height)
                )
                
                let color = SportsClass(rawValue: label)?.color ?? .gray
                
                return Detection(
                    label: label,
                    confidence: confidence,
                    boundingBox: boundingBox,
                    color: color
                )
            }
    }
    
    private func generateMockDetections(for image: CGImage) -> [Detection] {
        let imageSize = CGSize(width: image.width, height: image.height)
        let mockCount = Int.random(in: 2...5)
        
        return (0..<mockCount).map { _ in
            let randomClass = SportsClass.allCases.randomElement()!
            
            let x = CGFloat.random(in: 0.1...0.7) * imageSize.width
            let y = CGFloat.random(in: 0.1...0.7) * imageSize.height
            let width = CGFloat.random(in: 0.1...0.3) * imageSize.width
            let height = CGFloat.random(in: 0.1...0.3) * imageSize.height
            
            return Detection(
                label: randomClass.rawValue,
                confidence: Float.random(in: 0.5...0.95),
                boundingBox: CGRect(x: x, y: y, width: width, height: height),
                color: randomClass.color
            )
        }
    }
}

// MARK: - Video Transferable

struct VideoTransferable: Transferable {
    let url: URL
    
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let fileName = received.file.lastPathComponent
            let copy = URL.documentsDirectory.appending(path: fileName)
            
            if FileManager.default.fileExists(atPath: copy.path()) {
                try FileManager.default.removeItem(at: copy)
            }
            
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

// MARK: - View Model

@MainActor
@Observable
class VideoAnalysisViewModel {
    var videoURL: URL?
    var isAnalyzing = false
    var analysisProgress: Double = 0.0
    var currentFrame: Int = 0
    var totalFrames: Int = 0
    var errorMessage: String?
    var detectionResults: [FrameDetectionResult] = []
    var selectedFrameIndex: Int = 0
    var analysisResult: VideoAnalysisResult?
    
    var selectedFrameResult: FrameDetectionResult? {
        guard selectedFrameIndex < detectionResults.count else { return nil }
        return detectionResults[selectedFrameIndex]
    }
    
    var hasResults: Bool {
        !detectionResults.isEmpty
    }
    
    private let frameExtractor = VideoFrameExtractor()
    private let detector = YOLODetector()
    
    func analyzeVideo(url: URL, framesPerSecond: Int = 1, maxFrames: Int = 30) async {
        isAnalyzing = true
        analysisProgress = 0.0
        currentFrame = 0
        errorMessage = nil
        detectionResults = []
        videoURL = url
        
        do {
            print("🎬 動画解析開始")
            let startTime = Date()
            
            let frames = try await frameExtractor.extractFrames(
                from: url,
                fps: framesPerSecond,
                maxFrames: maxFrames
            ) { current, total in
                Task { @MainActor in
                    self.currentFrame = current
                    self.totalFrames = total
                    self.analysisProgress = Double(current) / Double(total) * 0.5
                }
            }
            
            totalFrames = frames.count
            var results: [FrameDetectionResult] = []
            
            for (index, frame) in frames.enumerated() {
                let detections = try await detector.detect(image: frame)
                
                let result = FrameDetectionResult(
                    frameNumber: index,
                    timestamp: Double(index) / Double(framesPerSecond),
                    detections: detections,
                    image: frame
                )
                
                results.append(result)
                currentFrame = index + 1
                analysisProgress = 0.5 + (Double(index + 1) / Double(frames.count) * 0.5)
            }
            
            detectionResults = results
            
            let endTime = Date()
            let duration = endTime.timeIntervalSince(startTime)
            
            analysisResult = VideoAnalysisResult(
                totalFrames: frames.count,
                processedFrames: frames.count,
                detectionResults: results,
                duration: duration
            )
            
            print("✅ 解析完了! 処理時間: \(String(format: "%.2f", duration))秒")
            isAnalyzing = false
            
        } catch {
            errorMessage = "エラー: \(error.localizedDescription)"
            isAnalyzing = false
            print("❌ エラー: \(error)")
        }
    }
    
    func cancelAnalysis() {
        isAnalyzing = false
        analysisProgress = 0.0
        currentFrame = 0
    }
    
    func reset() {
        videoURL = nil
        isAnalyzing = false
        analysisProgress = 0.0
        currentFrame = 0
        totalFrames = 0
        errorMessage = nil
        detectionResults = []
        selectedFrameIndex = 0
        analysisResult = nil
    }
    
    func nextFrame() {
        if selectedFrameIndex < detectionResults.count - 1 {
            selectedFrameIndex += 1
        }
    }
    
    func previousFrame() {
        if selectedFrameIndex > 0 {
            selectedFrameIndex -= 1
        }
    }
}

// このファイルは長いため、次のメッセージで続きを送ります
