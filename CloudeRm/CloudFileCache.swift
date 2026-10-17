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
    private static let snapshotFileName = "last-folder-snapshot.json"

    nonisolated struct Snapshot: Codable, Sendable {
        let folderPath: String
        let updatedAt: Date
        let files: [CloudFile]
        /// Missing in snapshots saved before per-directory totals were tracked.
        let directoryTotals: [String: CloudFolderTotal]?
    }

    nonisolated static func saveLastFolder(_ folderURL: URL) {
        guard let bookmarkData = FileAccess.makeSecurityScopedBookmark(for: folderURL) else {
            return
        }

        UserDefaults.standard.set(bookmarkData, forKey: folderBookmarkKey)
    }

    nonisolated static func loadLastFolder() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: folderBookmarkKey) else {
            return nil
        }

        return FileAccess.resolveSecurityScopedBookmark(bookmarkData)
    }

    nonisolated static func saveSnapshot(folderURL: URL, files: [CloudFile], directoryTotals: [String: CloudFolderTotal]) {
        let snapshot = Snapshot(
            folderPath: folderURL.standardizedFileURL.path(percentEncoded: false),
            updatedAt: Date(),
            files: files,
            directoryTotals: directoryTotals
        )

        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }

        guard let snapshotURL = try? snapshotFileURL() else {
            return
        }

        try? data.write(to: snapshotURL, options: .atomic)
    }

    nonisolated static func loadSnapshot(for folderURL: URL) -> Snapshot? {
        let data: Data?
        if let snapshotURL = try? snapshotFileURL(), let fileData = try? Data(contentsOf: snapshotURL) {
            data = fileData
        } else {
            data = UserDefaults.standard.data(forKey: snapshotKey)
        }

        guard let data, let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return nil
        }

        let folderPath = folderURL.standardizedFileURL.path(percentEncoded: false)
        return snapshot.folderPath == folderPath ? snapshot : nil
    }

    nonisolated private static func snapshotFileURL() throws -> URL {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cacheDirectoryURL = applicationSupportURL.appendingPathComponent("CloudeRm", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDirectoryURL,
            withIntermediateDirectories: true
        )
        return cacheDirectoryURL.appendingPathComponent(snapshotFileName, isDirectory: false)
    }
}

actor CloudFileCacheStore {
    static let shared = CloudFileCacheStore()

    func saveSnapshot(folderURL: URL, files: [CloudFile], directoryTotals: [String: CloudFolderTotal]) {
        CloudFileCache.saveSnapshot(folderURL: folderURL, files: files, directoryTotals: directoryTotals)
    }

    func loadSnapshot(for folderURL: URL) -> CloudFileCache.Snapshot? {
        CloudFileCache.loadSnapshot(for: folderURL)
    }
}
