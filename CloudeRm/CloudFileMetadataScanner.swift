//
//  CloudFileMetadataScanner.swift
//  CloudeRm
//
//  Created by olchu on 29. 5. 2026..
//

import Foundation

@MainActor
final class CloudFileMetadataScanner {
    enum MetadataScanError: LocalizedError {
        case unableToStart
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unableToStart:
                "Не удалось запустить быстрый поиск через Spotlight."
            case .cancelled:
                "Сканирование остановлено."
            }
        }
    }

    private let folderURL: URL
    private let onProgress: (CloudFileScanner.ScanProgress) -> Void
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var continuation: CheckedContinuation<CloudFileScanner.ScanResult, Error>?
    private var filesByURL: [URL: CloudFile] = [:]
    private var isCompleted = false
    private var skippedFileCount = 0
    private var didStartSecurityScopedAccess = false

    init(
        folderURL: URL,
        onProgress: @escaping (CloudFileScanner.ScanProgress) -> Void
    ) {
        self.folderURL = folderURL
        self.onProgress = onProgress
    }

    func start() async throws -> CloudFileScanner.ScanResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            didStartSecurityScopedAccess = folderURL.startAccessingSecurityScopedResource()

            configureQuery()
            addObservers()

            if !query.start() {
                finish(throwing: MetadataScanError.unableToStart)
            }
        }
    }

    func cancel() {
        finish(throwing: MetadataScanError.cancelled)
    }

    private func configureQuery() {
        query.searchScopes = [folderURL]
        query.predicate = NSPredicate(
            format: "%K == %@ OR %K == %@ OR %K == %@",
            NSMetadataUbiquitousItemDownloadingStatusKey,
            NSMetadataUbiquitousItemDownloadingStatusCurrent,
            NSMetadataUbiquitousItemDownloadingStatusKey,
            NSMetadataUbiquitousItemDownloadingStatusDownloaded,
            NSMetadataUbiquitousItemDownloadingStatusKey,
            NSMetadataUbiquitousItemDownloadingStatusNotDownloaded
        )
        query.sortDescriptors = [
            NSSortDescriptor(key: NSMetadataItemFSSizeKey, ascending: false)
        ]
        query.notificationBatchingInterval = 0.75
    }

    private func addObservers() {
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: .NSMetadataQueryDidUpdate,
                object: query,
                queue: .main
            ) { [weak self] notification in
                let changedItems = Self.changedItems(from: notification)
                Task { @MainActor [weak self] in
                    self?.processResults(changedItems, isFinished: false)
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.processResults(nil, isFinished: true)
                }
            }
        )
    }

    nonisolated private static func changedItems(from notification: Notification) -> [NSMetadataItem] {
        let addedItems = notification.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
        let changedItems = notification.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] ?? []
        return addedItems + changedItems
    }

    private func processResults(_ changedItems: [NSMetadataItem]?, isFinished: Bool) {
        guard !isCompleted else {
            return
        }

        query.disableUpdates()
        defer {
            query.enableUpdates()
        }

        var candidateBatch: [CloudFile] = []
        let items: [NSMetadataItem]

        if let changedItems {
            items = changedItems
        } else {
            items = (0..<query.resultCount).compactMap {
                query.result(at: $0) as? NSMetadataItem
            }
        }

        for item in items {
            guard let file = cloudFile(from: item) else {
                continue
            }

            let isNewFile = filesByURL.updateValue(file, forKey: file.url) == nil
            if isNewFile {
                candidateBatch.append(file)
            }
        }

        if !candidateBatch.isEmpty || isFinished {
            onProgress(
                CloudFileScanner.ScanProgress(
                    scannedFileCount: query.resultCount,
                    candidateFileCount: filesByURL.count,
                    skippedFileCount: skippedFileCount,
                    candidateBatch: candidateBatch
                )
            )
        }

        if isFinished {
            finish(
                returning: CloudFileScanner.ScanResult(
                    files: sortedFiles,
                    skippedFileCount: skippedFileCount,
                    scannedFileCount: query.resultCount
                )
            )
        }
    }

    private func cloudFile(from item: NSMetadataItem) -> CloudFile? {
        guard let fileURL = item.value(forAttribute: NSMetadataItemURLKey) as? URL else {
            skippedFileCount += 1
            return nil
        }

        let downloadStatus = downloadStatus(from: item)

        if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return nil
        }

        return CloudFile(
            url: fileURL,
            displayName: displayName(from: item, fileURL: fileURL),
            relativePath: relativePath(for: fileURL),
            byteSize: byteSize(from: item),
            modificationDate: modificationDate(from: item),
            downloadStatus: downloadStatus
        )
    }

    private func displayName(from item: NSMetadataItem, fileURL: URL) -> String {
        (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String) ?? fileURL.lastPathComponent
    }

    private func byteSize(from item: NSMetadataItem) -> Int64? {
        if let size = item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber {
            return size.int64Value
        }

        return nil
    }

    private func modificationDate(from item: NSMetadataItem) -> Date? {
        item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
    }

    private func downloadStatus(from item: NSMetadataItem) -> CloudDownloadStatus {
        guard let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String else {
            return .unknown
        }

        switch status {
        case NSMetadataUbiquitousItemDownloadingStatusCurrent:
            return .current
        case NSMetadataUbiquitousItemDownloadingStatusDownloaded:
            return .downloaded
        case NSMetadataUbiquitousItemDownloadingStatusNotDownloaded:
            return .notDownloaded
        default:
            return .unknown
        }
    }

    private func relativePath(for fileURL: URL) -> String {
        let folderPath = folderURL.standardizedFileURL.path(percentEncoded: false)
        let filePath = fileURL.standardizedFileURL.path(percentEncoded: false)
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"

        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }

        return fileURL.lastPathComponent
    }

    private var sortedFiles: [CloudFile] {
        filesByURL.values.sorted { lhs, rhs in
            let lhsSize = lhs.byteSize ?? -1
            let rhsSize = rhs.byteSize ?? -1

            if lhsSize != rhsSize {
                return lhsSize > rhsSize
            }

            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    private func finish(returning result: CloudFileScanner.ScanResult) {
        guard !isCompleted else {
            return
        }

        isCompleted = true
        cleanup()
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func finish(throwing error: Error) {
        guard !isCompleted else {
            return
        }

        isCompleted = true
        cleanup()
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func cleanup() {
        if query.isStarted {
            query.stop()
        }

        if didStartSecurityScopedAccess {
            folderURL.stopAccessingSecurityScopedResource()
            didStartSecurityScopedAccess = false
        }

        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers = []
    }
}
