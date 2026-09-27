//
//  CloudFileScanner.swift
//  CloudeRm
//
//  Created by olchu on 28. 5. 2026..
//

import Foundation

enum CloudFileScanner {
    enum ScanError: LocalizedError, Sendable {
        case unableToCreateEnumerator

        var errorDescription: String? {
            switch self {
            case .unableToCreateEnumerator:
                "Не удалось начать сканирование выбранной папки."
            }
        }
    }

    struct ScanResult: Sendable {
        let files: [CloudFile]
        let folderTotals: [String: CloudFolderTotal]
        let skippedFileCount: Int
        let scannedFileCount: Int
        /// Local files inside iCloud Drive that iCloud does not sync.
        var notSyncedFileCount = 0
        var notSyncedByteSize: Int64 = 0
    }

    struct ScanProgress: Sendable {
        let scannedFileCount: Int
        let candidateFileCount: Int
        let skippedFileCount: Int
        let candidateBatch: [CloudFile]
    }

    nonisolated static func scan(
        folderURL: URL,
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
    ) throws -> ScanResult {
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey
        ]
        let resourceKeySet = Set(resourceKeys)
        var skippedFileCount = 0
        var scannedFileCount = 0
        var files: [CloudFile] = []
        var folderTotals: [String: CloudFolderTotal] = [:]
        var candidateBatch: [CloudFile] = []
        let folderPath = folderURL.standardizedFileURL.path(percentEncoded: false)
        let relativePathPrefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"

        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                skippedFileCount += 1
                return true
            }
        ) else {
            throw ScanError.unableToCreateEnumerator
        }

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()

            do {
                let values = try fileURL.resourceValues(forKeys: resourceKeySet)
                guard values.isDirectory != true else {
                    folderTotals.addSubfolder(relativePath: relativePath(for: fileURL, prefix: relativePathPrefix))
                    continue
                }

                scannedFileCount += 1

                guard values.isUbiquitousItem == true else {
                    continue
                }

                let downloadStatus = downloadStatus(from: values)
                folderTotals.addFile(
                    relativePath: relativePath(for: fileURL, prefix: relativePathPrefix),
                    byteSize: Int64(values.fileSize ?? 0),
                    isLocal: downloadStatus.isStoredLocally,
                    modificationDate: values.contentModificationDate
                )
                guard downloadStatus.isStoredLocally else {
                    continue
                }

                let file = CloudFile(
                    url: fileURL,
                    displayName: fileURL.lastPathComponent,
                    relativePath: relativePath(for: fileURL, prefix: relativePathPrefix),
                    byteSize: values.fileSize.map(Int64.init),
                    allocatedByteSize: allocatedByteSize(from: values),
                    modificationDate: values.contentModificationDate,
                    downloadStatus: downloadStatus
                )
                files.append(file)
                candidateBatch.append(file)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skippedFileCount += 1
            }

            if scannedFileCount.isMultiple(of: 500) || candidateBatch.count >= 100 {
                onProgress?(
                    ScanProgress(
                        scannedFileCount: scannedFileCount,
                        candidateFileCount: files.count,
                        skippedFileCount: skippedFileCount,
                        candidateBatch: candidateBatch
                    )
                )
                candidateBatch = []
            }
        }

        onProgress?(
            ScanProgress(
                scannedFileCount: scannedFileCount,
                candidateFileCount: files.count,
                skippedFileCount: skippedFileCount,
                candidateBatch: candidateBatch
            )
        )

        return ScanResult(
            files: files.sorted(by: sortByLargestSizeFirst),
            folderTotals: folderTotals,
            skippedFileCount: skippedFileCount,
            scannedFileCount: scannedFileCount
        )
    }

    nonisolated static func sortByLargestSizeFirst(_ lhs: CloudFile, _ rhs: CloudFile) -> Bool {
        let lhsSize = lhs.localByteSize
        let rhsSize = rhs.localByteSize

        if lhsSize != rhsSize {
            return lhsSize > rhsSize
        }

        return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }

    nonisolated private static func allocatedByteSize(from values: URLResourceValues) -> Int64? {
        if let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
            return Int64(size)
        }

        return nil
    }

    nonisolated private static func downloadStatus(from values: URLResourceValues) -> CloudDownloadStatus {
        if values.ubiquitousItemIsDownloading == true {
            return .downloading
        }

        switch values.ubiquitousItemDownloadingStatus {
        case .current:
            return .current
        case .downloaded:
            return .downloaded
        case .notDownloaded:
            return .notDownloaded
        case nil:
            return .unknown
        default:
            return .unknown
        }
    }

    nonisolated private static func relativePath(for fileURL: URL, prefix: String) -> String {
        let filePath = fileURL.standardizedFileURL.path(percentEncoded: false)

        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }

        return fileURL.lastPathComponent
    }
}
