//
//  AnalysisStore.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

/// 解析結果の保存・読み込みを行うストア
///
/// Application Support/Analyses/<id>/ に analysis.json、動画ファイル、フレーム画像（JPEG）を保存する。
/// 解析が完成する前は checkpoint.json と frames.jsonl に少しずつ書き込み、中断されても再開できるようにする。
@MainActor
@Observable
final class AnalysisStore {

    /// 保存済みの解析結果（新しい順）
    private(set) var records: [SavedAnalysis] = []
    /// 中断された解析（analysis.json がまだ書き終わっていないもの、新しい順）
    private(set) var interrupted: [AnalysisCheckpoint] = []

    private let baseURL: URL
    /// 解析中のフレーム追記用に開いたままにしておくファイルハンドル（1フレームごとの open/close を避ける）
    private var frameHandles: [UUID: FileHandle] = [:]

    init(baseURL: URL = URL.applicationSupportDirectory.appending(path: "Analyses", directoryHint: .isDirectory)) {
        self.baseURL = baseURL
        loadAll()
    }

    // MARK: - Paths

    nonisolated static func imageFileName(for frameNumber: Int) -> String {
        String(format: "frame_%04d.jpg", frameNumber)
    }

    func directoryURL(for id: UUID) -> URL {
        baseURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// 解析結果の JSON ファイル（共有にも使う）
    func jsonURL(for record: SavedAnalysis) -> URL {
        directoryURL(for: record.id).appending(path: "analysis.json")
    }

    private func checkpointURL(for id: UUID) -> URL {
        directoryURL(for: id).appending(path: "checkpoint.json")
    }

    private func framesJSONLURL(for id: UUID) -> URL {
        directoryURL(for: id).appending(path: "frames.jsonl")
    }

    /// 保存済みの動画（履歴からの再生用。古い記録には存在しない）
    func videoURL(for record: SavedAnalysis) -> URL? {
        guard let fileName = record.videoFileName else { return nil }
        return directoryURL(for: record.id).appending(path: fileName)
    }

    /// 中断された解析の動画
    func videoURL(for checkpoint: AnalysisCheckpoint) -> URL {
        directoryURL(for: checkpoint.id).appending(path: checkpoint.videoFileName)
    }

    /// 保存済みフレーム画像のパス
    func imageURL(for record: SavedAnalysis, frameNumber: Int) -> URL {
        directoryURL(for: record.id).appending(path: Self.imageFileName(for: frameNumber))
    }

    // MARK: - Read

    func record(for id: UUID) -> SavedAnalysis? {
        records.first { $0.id == id }
    }

    func checkpoint(for id: UUID) -> AnalysisCheckpoint? {
        interrupted.first { $0.id == id }
    }

    /// 保存済みの解析結果・中断された解析をすべて読み込む
    func loadAll() {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil
        ) else {
            records = []
            interrupted = []
            return
        }

        let decoder = Self.makeDecoder()
        var loadedRecords: [SavedAnalysis] = []
        var loadedCheckpoints: [AnalysisCheckpoint] = []

        for directory in directories {
            let analysisURL = directory.appending(path: "analysis.json")
            if let data = try? Data(contentsOf: analysisURL),
               let record = try? decoder.decode(SavedAnalysis.self, from: data) {
                loadedRecords.append(record)
                continue
            }
            // analysis.json がなければ、中断された解析かどうかを確認する
            let checkpointURL = directory.appending(path: "checkpoint.json")
            if let data = try? Data(contentsOf: checkpointURL),
               let checkpoint = try? decoder.decode(AnalysisCheckpoint.self, from: data) {
                loadedCheckpoints.append(checkpoint)
            }
        }

        records = loadedRecords.sorted { $0.createdAt > $1.createdAt }
        interrupted = loadedCheckpoints.sorted { $0.createdAt > $1.createdAt }
    }

    /// 保存済みのフレーム画像を1枚読み込む（動画ファイルがない古い記録の表示用）
    func loadFrameImage(for record: SavedAnalysis, frameNumber: Int) async -> CGImage? {
        let url = imageURL(for: record, frameNumber: frameNumber)
        return await Task.detached(priority: .userInitiated) {
            FrameImageIO.readImage(at: url)
        }.value
    }

    /// 中断された解析のフレーム画像を1枚読み込む
    func loadFrameImage(for checkpoint: AnalysisCheckpoint, frameNumber: Int) async -> CGImage? {
        let url = directoryURL(for: checkpoint.id).appending(path: Self.imageFileName(for: frameNumber))
        return await Task.detached(priority: .userInitiated) {
            FrameImageIO.readImage(at: url)
        }.value
    }

    // MARK: - Write（解析中に少しずつ呼ばれる）

    /// 解析用のディレクトリを作り、動画ファイルを移動して、最初のチェックポイントを書く
    @discardableResult
    func beginAnalysis(id: UUID, movingVideoFrom sourceURL: URL, info: VideoInfo, framesPerSecond: Int) async throws -> URL {
        let directory = directoryURL(for: id)
        let fileName = sourceURL.lastPathComponent
        let destination = directory.appending(path: fileName)

        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: sourceURL, to: destination)
        }.value

        let checkpoint = AnalysisCheckpoint(
            id: id,
            videoFileName: fileName,
            videoDuration: info.duration,
            createdAt: Date(),
            updatedAt: Date(),
            stage: .detecting,
            lastProcessedFrame: 0,
            totalFrames: info.totalFrames,
            framesPerSecond: framesPerSecond,
            usedRealModel: false
        )
        try writeCheckpoint(checkpoint)
        interrupted.removeAll { $0.id == id }
        interrupted.insert(checkpoint, at: 0)
        return destination
    }

    /// フレームの検出結果を1件、ディスクに追記する（画像とJSON行）
    func appendFrame(id: UUID, frame: SavedFrame, image: CGImage?) async throws {
        let directory = directoryURL(for: id)
        let handle = try frameHandle(for: id)

        let encoder = Self.makeEncoder()
        encoder.outputFormatting = []
        var lineData = try encoder.encode(frame)
        lineData.append(contentsOf: "\n".utf8)

        try await Task.detached(priority: .utility) {
            if let fileName = frame.imageFileName, let image {
                try FrameImageIO.writeJPEG(image, to: directory.appending(path: fileName))
            }
            try handle.write(contentsOf: lineData)
        }.value
    }

    /// フレームの検出結果をすべて書き直す（チーム判定の確定など、後から全件を更新したいとき）
    func rewriteFrames(id: UUID, frames: [SavedFrame]) async throws {
        // 以後そのIDへの追記は行わないので、古いファイルを指したままのハンドルは閉じておく
        closeFrameHandle(for: id)

        let url = framesJSONLURL(for: id)
        let encoder = Self.makeEncoder()
        encoder.outputFormatting = []
        let lines = try frames.map { frame -> Data in
            var data = try encoder.encode(frame)
            data.append(contentsOf: "\n".utf8)
            return data
        }

        try await Task.detached(priority: .utility) {
            var combined = Data()
            for line in lines { combined.append(line) }
            try combined.write(to: url, options: .atomic)
        }.value
    }

    /// フレーム追記用のファイルハンドルを取得する（なければ開いて末尾にシークする）
    private func frameHandle(for id: UUID) throws -> FileHandle {
        if let handle = frameHandles[id] {
            return handle
        }
        let url = framesJSONLURL(for: id)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        frameHandles[id] = handle
        return handle
    }

    private func closeFrameHandle(for id: UUID) {
        if let handle = frameHandles.removeValue(forKey: id) {
            try? handle.close()
        }
    }

    /// これまでに追記したフレームを読み込む（再開時に使う）
    func readAppendedFrames(id: UUID) -> [SavedFrame] {
        let url = framesJSONLURL(for: id)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = Self.makeDecoder()
        return text
            .split(separator: "\n")
            .compactMap { line in
                guard let lineData = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(SavedFrame.self, from: lineData)
            }
            .sorted { $0.frameNumber < $1.frameNumber }
    }

    /// チェックポイントを更新する（進捗・段階・チーム・シーンの確定を反映）
    func updateCheckpoint(_ checkpoint: AnalysisCheckpoint) throws {
        try writeCheckpoint(checkpoint)
        if let index = interrupted.firstIndex(where: { $0.id == checkpoint.id }) {
            interrupted[index] = checkpoint
        } else {
            interrupted.insert(checkpoint, at: 0)
        }
    }

    private func writeCheckpoint(_ checkpoint: AnalysisCheckpoint) throws {
        let data = try Self.makeEncoder().encode(checkpoint)
        try data.write(to: checkpointURL(for: checkpoint.id), options: .atomic)
    }

    /// 解析を完成させる（analysis.json を書き、チェックポイントと途中ファイルを消す）
    func finalize(_ record: SavedAnalysis) async throws {
        closeFrameHandle(for: record.id)
        let directory = directoryURL(for: record.id)
        let data = try Self.makeEncoder().encode(record)

        try await Task.detached(priority: .utility) {
            try data.write(to: directory.appending(path: "analysis.json"), options: .atomic)
            try? FileManager.default.removeItem(at: directory.appending(path: "checkpoint.json"))
            try? FileManager.default.removeItem(at: directory.appending(path: "frames.jsonl"))
        }.value

        interrupted.removeAll { $0.id == record.id }
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
    }

    /// 保存済みの解析結果を更新する（AI総評・シーン解説の追記など）
    func update(_ record: SavedAnalysis) throws {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        let data = try Self.makeEncoder().encode(record)
        try data.write(to: jsonURL(for: record), options: .atomic)
    }

    /// 解析結果を削除する
    func delete(_ record: SavedAnalysis) {
        records.removeAll { $0.id == record.id }
        let directory = directoryURL(for: record.id)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// 中断された解析を破棄する
    func discardCheckpoint(_ checkpoint: AnalysisCheckpoint) {
        closeFrameHandle(for: checkpoint.id)
        interrupted.removeAll { $0.id == checkpoint.id }
        let directory = directoryURL(for: checkpoint.id)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Coding

    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// フレーム画像の読み書き
nonisolated enum FrameImageIO {

    /// 長辺を maxDimension 以下に縮小して JPEG で保存する
    static func writeJPEG(_ image: CGImage, to url: URL, maxDimension: Int = 1280, quality: Double = 0.7) throws {
        let source = downscaled(image, maxDimension: maxDimension) ?? image

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, source, options)

        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func readImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 長辺を maxDimension 以下に縮小する（縮小不要なら nil）
    static func downscaled(_ image: CGImage, maxDimension: Int) -> CGImage? {
        let longSide = max(image.width, image.height)
        guard longSide > maxDimension else { return nil }

        let scale = Double(maxDimension) / Double(longSide)
        let width = Int(Double(image.width) * scale)
        let height = Int(Double(image.height) * scale)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
