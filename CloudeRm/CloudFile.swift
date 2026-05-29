//
//  CloudFile.swift
//  CloudeRm
//
//  Created by olchu on 28. 5. 2026..
//

import Foundation

struct CloudFile: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let displayName: String
    let relativePath: String
    let byteSize: Int64?
    let modificationDate: Date?
    let downloadStatus: CloudDownloadStatus
    var evictionResult: EvictionResult?

    nonisolated init(
        url: URL,
        displayName: String,
        relativePath: String,
        byteSize: Int64? = nil,
        modificationDate: Date? = nil,
        downloadStatus: CloudDownloadStatus = .unknown,
        evictionResult: EvictionResult? = nil
    ) {
        self.id = url
        self.url = url
        self.displayName = displayName
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.modificationDate = modificationDate
        self.downloadStatus = downloadStatus
        self.evictionResult = evictionResult
    }
}

enum CloudDownloadStatus: Hashable, Sendable {
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

enum EvictionResult: Hashable, Sendable {
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
