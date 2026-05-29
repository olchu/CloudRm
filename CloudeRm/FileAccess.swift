//
//  FileAccess.swift
//  CloudeRm
//
//  Created by olchu on 28. 5. 2026..
//

import AppKit
import Foundation

enum FileAccess {
    enum AccessError: LocalizedError, Sendable {
        case selectedItemIsNotFolder

        var errorDescription: String? {
            switch self {
            case .selectedItemIsNotFolder:
                "Выбранный объект не является папкой."
            }
        }
    }

    @MainActor
    static func selectFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Выберите папку iCloud Drive"
        panel.message = "Выберите папку, в которой CloudeRm будет искать локально скачанные iCloud-файлы."
        panel.prompt = "Выбрать"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        return panel.runModal() == .OK ? panel.url : nil
    }

    nonisolated static func validateFolder(_ url: URL) throws {
        try withSecurityScopedAccess(to: url) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw AccessError.selectedItemIsNotFolder
            }
        }
    }

    nonisolated static func withSecurityScopedAccess<Result>(
        to url: URL,
        perform operation: () throws -> Result
    ) rethrows -> Result {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try operation()
    }
}
