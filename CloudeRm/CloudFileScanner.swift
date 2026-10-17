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
        let directoryTotals: [String: CloudFolderTotal]
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

    /// Asks FileManager about every item; slower than `CloudFileDiskScanner`
    /// but relies only on the iCloud resource values.
    nonisolated static func scan(
        folderURL: URL,
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanResult {
        let task = Task.detached(priority: .userInitiated) {
            try FileAccess.withSecurityScopedAccess(to: folderURL) {
                try scanSynchronously(folderURL: folderURL, onProgress: onProgress)
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func scanSynchronously(
        folderURL: URL,
        onProgress: (@Sendable (ScanProgress) -> Void)?
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
        var directoryTotals: [String: CloudFolderTotal] = [:]
        var candidateBatch: [CloudFile] = []
        let folderPath = folderURL.standardizedFileURL.path(percentEncoded: false)
        let relativePathPrefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"

        func reportProgress() {
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
                let relativePath = relativePath(for: fileURL, prefix: relativePathPrefix)
                guard values.isDirectory != true else {
                    directoryTotals.addSubfolder(relativePath: relativePath)
                    continue
                }

                scannedFileCount += 1

                guard values.isUbiquitousItem == true else {
                    continue
                }

                let downloadStatus = CloudDownloadStatus(resourceValues: values)
                directoryTotals.addFile(
                    relativePath: relativePath,
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
                    relativePath: relativePath,
                    byteSize: values.fileSize.map(Int64.init),
                    allocatedByteSize: (values.totalFileAllocatedSize ?? values.fileAllocatedSize).map(Int64.init),
                    modificationDate: values.contentModificationDate,
                    downloadStatus: downloadStatus
                )
                files.append(file)
                candidateBatch.append(file)
            } catch {
                skippedFileCount += 1
            }

            if scannedFileCount.isMultiple(of: 500) || candidateBatch.count >= 100 {
                reportProgress()
            }
        }

        reportProgress()

        return ScanResult(
            files: files.sorted(by: sortByLargestSizeFirst),
            directoryTotals: directoryTotals,
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

    nonisolated private static func relativePath(for fileURL: URL, prefix: String) -> String {
        let filePath = fileURL.standardizedFileURL.path(percentEncoded: false)

        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }

        return fileURL.lastPathComponent
    }
}
