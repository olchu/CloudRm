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
        let skippedFileCount: Int
        let scannedFileCount: Int
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
            .contentModificationDateKey
        ]
        var skippedFileCount = 0
        var scannedFileCount = 0
        var files: [CloudFile] = []
        var candidateBatch: [CloudFile] = []

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
                let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                guard values.isDirectory != true else {
                    continue
                }

                scannedFileCount += 1

                guard values.isUbiquitousItem == true else {
                    continue
                }

                let downloadStatus = downloadStatus(from: values)
                guard downloadStatus.isStoredLocally else {
                    continue
                }

                let file = CloudFile(
                    url: fileURL,
                    displayName: fileURL.lastPathComponent,
                    relativePath: relativePath(for: fileURL, in: folderURL),
                    byteSize: values.fileSize.map(Int64.init),
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

            if scannedFileCount.isMultiple(of: 100) || candidateBatch.count >= 25 {
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
            skippedFileCount: skippedFileCount,
            scannedFileCount: scannedFileCount
        )
    }

    nonisolated private static func sortByLargestSizeFirst(_ lhs: CloudFile, _ rhs: CloudFile) -> Bool {
        let lhsSize = lhs.byteSize ?? -1
        let rhsSize = rhs.byteSize ?? -1

        if lhsSize != rhsSize {
            return lhsSize > rhsSize
        }

        return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
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

    nonisolated private static func relativePath(for fileURL: URL, in folderURL: URL) -> String {
        let folderPath = folderURL.standardizedFileURL.path(percentEncoded: false)
        let filePath = fileURL.standardizedFileURL.path(percentEncoded: false)
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"

        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }

        return fileURL.lastPathComponent
    }
}
