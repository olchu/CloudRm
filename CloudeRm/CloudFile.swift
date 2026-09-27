//
//  CloudFile.swift
//  CloudeRm
//
//  Created by olchu on 28. 5. 2026..
//

import Foundation

nonisolated struct CloudFile: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let displayName: String
    let relativePath: String
    let byteSize: Int64?
    let allocatedByteSize: Int64?
    let modificationDate: Date?
    let downloadStatus: CloudDownloadStatus
    var evictionResult: EvictionResult?

    nonisolated init(
        url: URL,
        displayName: String,
        relativePath: String,
        byteSize: Int64? = nil,
        allocatedByteSize: Int64? = nil,
        modificationDate: Date? = nil,
        downloadStatus: CloudDownloadStatus = .unknown,
        evictionResult: EvictionResult? = nil
    ) {
        self.id = url
        self.url = url
        self.displayName = displayName
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.allocatedByteSize = allocatedByteSize
        self.modificationDate = modificationDate
        self.downloadStatus = downloadStatus
        self.evictionResult = evictionResult
    }

    /// Bytes physically allocated on this Mac. Older cached scans fall back to
    /// the logical size until the next scan refreshes the value.
    nonisolated var localByteSize: Int64 {
        allocatedByteSize ?? byteSize ?? 0
    }
}

/// iCloud totals for one directory and everything below it, including files
/// that live only in iCloud and therefore never appear in the scanned file
/// list. Keyed by the directory's relative path; "" is the scanned root.
nonisolated struct CloudFolderTotal: Codable, Hashable, Sendable {
    var byteSize: Int64 = 0
    var cloudOnlyByteSize: Int64 = 0
    var fileCount = 0
    var folderCount = 0
    var lastModified: Date?

    /// "A/B/file" → ["", "A", "A/B"]: every directory containing the item.
    nonisolated static func ancestorPaths(of relativePath: String) -> [String] {
        var paths = [""]
        var index = relativePath.startIndex
        while let slash = relativePath[index...].firstIndex(of: "/") {
            paths.append(String(relativePath[..<slash]))
            index = relativePath.index(after: slash)
        }
        return paths
    }

    nonisolated mutating func addFile(byteSize: Int64, isLocal: Bool, modificationDate: Date?) {
        self.byteSize += byteSize
        if !isLocal {
            cloudOnlyByteSize += byteSize
        }
        fileCount += 1
        if let modificationDate, modificationDate > (lastModified ?? .distantPast) {
            lastModified = modificationDate
        }
    }

    nonisolated mutating func merge(_ other: CloudFolderTotal) {
        byteSize += other.byteSize
        cloudOnlyByteSize += other.cloudOnlyByteSize
        fileCount += other.fileCount
        folderCount += other.folderCount
        if let otherDate = other.lastModified, otherDate > (lastModified ?? .distantPast) {
            lastModified = otherDate
        }
    }
}

extension [String: CloudFolderTotal] {
    nonisolated mutating func addFile(relativePath: String, byteSize: Int64, isLocal: Bool, modificationDate: Date?) {
        for path in CloudFolderTotal.ancestorPaths(of: relativePath) {
            self[path, default: CloudFolderTotal()].addFile(byteSize: byteSize, isLocal: isLocal, modificationDate: modificationDate)
        }
    }

    /// Counts the folder in its ancestors. `isListed` is false for a dataless
    /// folder: its contents are unknown, so it gets no entry of its own.
    nonisolated mutating func addSubfolder(relativePath: String, isListed: Bool = true) {
        for path in CloudFolderTotal.ancestorPaths(of: relativePath) {
            self[path, default: CloudFolderTotal()].folderCount += 1
        }
        if isListed, self[relativePath] == nil {
            self[relativePath] = CloudFolderTotal()
        }
    }

    nonisolated mutating func merge(_ other: [String: CloudFolderTotal]) {
        for (key, total) in other {
            self[key, default: CloudFolderTotal()].merge(total)
        }
    }
}

nonisolated enum CloudDownloadStatus: Hashable, Sendable {
    case downloaded
    case notDownloaded
    case current
    case downloading
    case unknown

    nonisolated var isStoredLocally: Bool {
        switch self {
        case .downloaded, .current:
            true
        case .notDownloaded, .downloading, .unknown:
            false
        }
    }

    nonisolated var displayName: String {
        switch self {
        case .downloaded:
            "Скачан"
        case .notDownloaded:
            "Только iCloud"
        case .current:
            "Актуален"
        case .downloading:
            "Загружается"
        case .unknown:
            "Неизвестно"
        }
    }
}

nonisolated enum EvictionResult: Hashable, Sendable {
    case pending
    case success
    case skipped(String)
    case failure(String)

    nonisolated var displayName: String {
        switch self {
        case .pending:
            "Выгрузка..."
        case .success:
            "Выгружен"
        case .skipped(let reason):
            "Пропущен: \(reason)"
        case .failure(let message):
            "Ошибка: \(message)"
        }
    }
}
