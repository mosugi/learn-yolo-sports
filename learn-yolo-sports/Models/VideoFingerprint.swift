//
//  VideoFingerprint.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/11.
//

import Foundation
import CryptoKit

/// 同じ動画を選び直したときに見分けるための目印
///
/// 写真ライブラリの識別子があればそれで見分ける（動画の読み込みより前に分かるため、コピーも省ける）。
/// 取れない場合は、ファイルの大きさと先頭・末尾の一部から求めたハッシュで見分ける。
nonisolated struct VideoFingerprint: Codable, Hashable {
    /// 写真ライブラリ上の識別子（PhotosPickerItem.itemIdentifier）
    var assetIdentifier: String?
    var fileSize: Int64?
    /// 先頭と末尾の一部の SHA-256
    var sampleHash: String?

    /// ハッシュに使う先頭・末尾の大きさ
    private static let sampleLength = 1 << 20

    func matches(_ other: VideoFingerprint) -> Bool {
        if let a = assetIdentifier, let b = other.assetIdentifier, a == b {
            return true
        }
        if let a = sampleHash, let b = other.sampleHash, let size = fileSize, size == other.fileSize {
            return a == b
        }
        return false
    }

    /// ファイルの大きさと、先頭・末尾の一部のハッシュを求める（ファイル全体は読まない）
    static func make(fileAt url: URL, assetIdentifier: String?) throws -> VideoFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        var hasher = SHA256()
        try handle.seek(toOffset: 0)
        if let head = try handle.read(upToCount: sampleLength) {
            hasher.update(data: head)
        }
        if size > UInt64(sampleLength) {
            try handle.seek(toOffset: size - UInt64(sampleLength))
            if let tail = try handle.read(upToCount: sampleLength) {
                hasher.update(data: tail)
            }
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return VideoFingerprint(assetIdentifier: assetIdentifier, fileSize: Int64(size), sampleHash: hash)
    }
}
