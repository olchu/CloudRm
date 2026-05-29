//
//  CloudFileCache.swift
//  CloudeRm
//
//  Created by olchu on 29. 5. 2026..
//

import Foundation

nonisolated enum CloudFileCache {
    private static let folderBookmarkKey = "lastFolderBookmark"
    private static let snapshotKey = "lastFolderSnapshot"

    nonisolated struct Snapshot: Codable, Sendable {
        let folderPath: String
        let updatedAt: Date
        let files: [CachedFile]
    }

    nonisolated struct CachedFile: Codable, Sendable {
        let url: URL
        let displayName: String
        let relativePath: String
        let byteSize: Int64?
        let modificationDate: Date?
        let downloadStatusName: String

        init(file: CloudFile) {
            url = file.url
            displayName = file.displayName
            relativePath = file.relativePath
            byteSize = file.byteSize
            modificationDate = file.modificationDate
            downloadStatusName = file.downloadStatus.cacheName
        }

        var cloudFile: CloudFile {
            CloudFile(
                url: url,
                displayName: displayName,
                relativePath: relativePath,
                byteSize: byteSize,
                modificationDate: modificationDate,
                downloadStatus: CloudDownloadStatus(cacheName: downloadStatusName)
            )
        }
    }

    nonisolated static func saveLastFolder(_ folderURL: URL) {
        guard let bookmarkData = try? FileAccess.makeSecurityScopedBookmark(for: folderURL) else {
            return
        }

        UserDefaults.standard.set(bookmarkData, forKey: folderBookmarkKey)
    }

    nonisolated static func loadLastFolder() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: folderBookmarkKey) else {
            return nil
        }

        return try? FileAccess.resolveSecurityScopedBookmark(bookmarkData)
    }

    nonisolated static func saveSnapshot(folderURL: URL, files: [CloudFile]) {
        let snapshot = Snapshot(
            folderPath: folderURL.standardizedFileURL.path(percentEncoded: false),
            updatedAt: Date(),
            files: files.map(CachedFile.init(file:))
        )

        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }

        UserDefaults.standard.set(data, forKey: snapshotKey)
    }

    nonisolated static func loadSnapshot(for folderURL: URL) -> Snapshot? {
        guard
            let data = UserDefaults.standard.data(forKey: snapshotKey),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else {
            return nil
        }

        let folderPath = folderURL.standardizedFileURL.path(percentEncoded: false)
        return snapshot.folderPath == folderPath ? snapshot : nil
    }
}

private extension CloudDownloadStatus {
    nonisolated var cacheName: String {
        switch self {
        case .downloaded:
            "downloaded"
        case .notDownloaded:
            "notDownloaded"
        case .current:
            "current"
        case .downloading:
            "downloading"
        case .unknown:
            "unknown"
        }
    }

    nonisolated init(cacheName: String) {
        switch cacheName {
        case "downloaded":
            self = .downloaded
        case "notDownloaded":
            self = .notDownloaded
        case "current":
            self = .current
        case "downloading":
            self = .downloading
        default:
            self = .unknown
        }
    }
}
