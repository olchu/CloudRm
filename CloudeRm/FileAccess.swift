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
                "The selected item is not a folder."
            }
        }
    }

    nonisolated static var defaultICloudDriveFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    @MainActor
    static func selectFolder() -> URL? {
        selectFolder(startingAt: nil)
    }

    @MainActor
    static func selectICloudDriveFolder() -> URL? {
        selectFolder(startingAt: defaultICloudDriveFolderURL)
    }

    @MainActor
    private static func selectFolder(startingAt directoryURL: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an iCloud Drive Folder"
        panel.message = "Choose the folder where CloudeRm should look for downloaded iCloud files."
        panel.prompt = "Choose"
        panel.directoryURL = directoryURL
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

    /// Runs `operation` inside the folder's security scope; a nil URL needs none.
    nonisolated static func withSecurityScopedAccess<Result>(
        to url: URL?,
        perform operation: () throws -> Result
    ) rethrows -> Result {
        let didStartAccess = url?.startAccessingSecurityScopedResource() == true
        defer {
            if didStartAccess {
                url?.stopAccessingSecurityScopedResource()
            }
        }

        return try operation()
    }

    nonisolated static func makeSecurityScopedBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    nonisolated static func resolveSecurityScopedBookmark(_ bookmarkData: Data) -> URL? {
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ),
            !isStale
        else {
            return nil
        }

        return url
    }
}
