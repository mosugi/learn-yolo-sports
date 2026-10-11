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
/// Application Support/Analyses/<id>/ に analysis.json とフレーム画像（JPEG）を保存する。
@MainActor
@Observable
final class AnalysisStore {
    
    /// 保存済みの解析結果（新しい順）
    private(set) var records: [SavedAnalysis] = []
    
    private let baseURL: URL
    
    /// 書き込み中の保存処理（削除と競合しないように待ち合わせる）
    private var pendingSaves: [UUID: Task<Void, Error>] = [:]
    
    init(baseURL: URL = URL.applicationSupportDirectory.appending(path: "Analyses", directoryHint: .isDirectory)) {
        self.baseURL = baseURL
        loadAll()
    }
    
    // MARK: - Paths
    
    nonisolated static func imageFileName(for frameNumber: Int) -> String {
        String(format: "frame_%04d.jpg", frameNumber)
    }
    
    /// 解析結果のディレクトリ（解析中のフレーム画像もここに書き込む）
    func directoryURL(for id: UUID) -> URL {
        baseURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }
    
    /// 解析結果の JSON ファイル（共有にも使う）
    func jsonURL(for record: SavedAnalysis) -> URL {
        directoryURL(for: record.id).appending(path: "analysis.json")
    }
    
    // MARK: - Read
    
    func record(for id: UUID) -> SavedAnalysis? {
        records.first { $0.id == id }
    }
    
    /// 保存済みの解析結果をすべて読み込む
    func loadAll() {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil
        ) else {
            records = []
            return
        }
        
        let decoder = Self.makeDecoder()
        records = directories
            .compactMap { directory in
                let url = directory.appending(path: "analysis.json")
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SavedAnalysis.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
    
    /// フレーム画像を読み込む
    func image(for frame: SavedFrame, in record: SavedAnalysis) async -> CGImage? {
        guard let fileName = frame.imageFileName else { return nil }
        let url = directoryURL(for: record.id).appending(path: fileName)
        return await Task.detached(priority: .userInitiated) {
            FrameImageIO.readImage(at: url)
        }.value
    }
    
    // MARK: - Write
    
    /// 解析結果を保存する（一覧にはすぐに反映し、ファイル書き込みはバックグラウンドで行う）
    ///
    /// フレーム画像は解析中に directoryURL(for:) へ書き込み済みであること。
    func save(_ record: SavedAnalysis) async throws {
        records.insert(record, at: 0)
        
        let directory = directoryURL(for: record.id)
        let data = try Self.makeEncoder().encode(record)
        
        let task = Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // JSON は最後に書く（JSON があれば画像も揃っている）
            try data.write(to: directory.appending(path: "analysis.json"), options: .atomic)
        }
        pendingSaves[record.id] = task
        defer { pendingSaves[record.id] = nil }
        
        try await task.value
    }
    
    /// 保存に至らなかった解析の書きかけのファイルを消す
    func discardPartial(id: UUID) {
        let directory = directoryURL(for: id)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
    
    /// 保存済みの解析結果を更新する
    func update(_ record: SavedAnalysis) throws {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        let data = try Self.makeEncoder().encode(record)
        try data.write(to: jsonURL(for: record), options: .atomic)
    }
    
    /// 保存済みの解析結果の一部を書き換えて保存する
    func modify(_ id: UUID, _ change: (inout SavedAnalysis) -> Void) throws {
        guard var record = record(for: id) else { return }
        change(&record)
        try update(record)
    }
    
        /// 解析結果を削除する
    func delete(_ record: SavedAnalysis) {
        records.removeAll { $0.id == record.id }
        
        let directory = directoryURL(for: record.id)
        let pendingSave = pendingSaves[record.id]
        Task {
            // 保存中なら書き込みが終わってから削除する（先に消すと保存処理がファイルを作り直してしまう）
            _ = try? await pendingSave?.value
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                print("❌ 解析結果の削除に失敗: \(error)")
            }
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
