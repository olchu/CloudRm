//
//  CloudFileEvictor.swift
//  CloudeRm
//
//  Created by olchu on 28. 5. 2026..
//

import Foundation

enum CloudFileEvictor {
    enum EvictionError: LocalizedError, Sendable {
        case selectedItemIsDirectory
        case selectedItemIsNotICloudFile
        case fileIsDownloading
        case fileIsNotStoredLocally

        var errorDescription: String? {
            switch self {
            case .selectedItemIsDirectory:
                "это папка"
            case .selectedItemIsNotICloudFile:
                "это не iCloud-файл"
            case .fileIsDownloading:
                "файл сейчас загружается"
            case .fileIsNotStoredLocally:
                "локальной копии уже нет"
            }
        }
    }

    /// Evicts each file's local copy and returns the error message for every
    /// file that could not be evicted, keyed by file ID.
    nonisolated static func evict(_ files: [CloudFile], accessFolderURL: URL?) -> [CloudFile.ID: String] {
        FileAccess.withSecurityScopedAccess(to: accessFolderURL) {
            var failures: [CloudFile.ID: String] = [:]
            for file in files {
                do {
                    try evictValidatedFile(at: file.url)
                } catch {
                    failures[file.id] = error.localizedDescription
                }
            }
            return failures
        }
    }

    nonisolated private static func evictValidatedFile(at fileURL: URL) throws {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey
        ]
        let values = try fileURL.resourceValues(forKeys: resourceKeys)

        // Packages such as .pages documents are single iCloud items.
        guard values.isDirectory != true || values.isPackage == true else {
            throw EvictionError.selectedItemIsDirectory
        }

        guard values.isUbiquitousItem == true else {
            throw EvictionError.selectedItemIsNotICloudFile
        }

        guard values.ubiquitousItemIsDownloading != true else {
            throw EvictionError.fileIsDownloading
        }

        guard CloudDownloadStatus(resourceValues: values).isStoredLocally else {
            throw EvictionError.fileIsNotStoredLocally
        }

        try FileManager.default.evictUbiquitousItem(at: fileURL)
    }
}
