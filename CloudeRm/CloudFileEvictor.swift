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

    nonisolated static func evict(_ file: CloudFile, accessFolderURL: URL?) -> EvictionResult {
        do {
            if let accessFolderURL {
                try FileAccess.withSecurityScopedAccess(to: accessFolderURL) {
                    try evictValidatedFile(at: file.url)
                }
            } else {
                try evictValidatedFile(at: file.url)
            }

            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    nonisolated static func evict(_ files: [CloudFile], accessFolderURL: URL?) -> [(CloudFile.ID, EvictionResult)] {
        if let accessFolderURL {
            return FileAccess.withSecurityScopedAccess(to: accessFolderURL) {
                files.map { file in
                    (file.id, evictionResult(for: file.url))
                }
            }
        }

        return files.map { file in
            (file.id, evictionResult(for: file.url))
        }
    }

    nonisolated private static func evictionResult(for fileURL: URL) -> EvictionResult {
        do {
            try evictValidatedFile(at: fileURL)
            return .success
        } catch {
            return .failure(error.localizedDescription)
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

private extension CloudDownloadStatus {
    nonisolated init(resourceValues values: URLResourceValues) {
        if values.ubiquitousItemIsDownloading == true {
            self = .downloading
            return
        }

        switch values.ubiquitousItemDownloadingStatus {
        case .current:
            self = .current
        case .downloaded:
            self = .downloaded
        case .notDownloaded:
            self = .notDownloaded
        case nil:
            self = .unknown
        default:
            self = .unknown
        }
    }
}
