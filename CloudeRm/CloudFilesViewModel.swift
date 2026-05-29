//
//  CloudFilesViewModel.swift
//  CloudeRm
//
//  Created by olchu on 28. 5. 2026..
//

import Foundation
import Observation

@MainActor
@Observable
final class CloudFilesViewModel {
    var selectedFolderURL: URL?
    var files: [CloudFile] = []
    var selectedFileIDs: Set<CloudFile.ID> = []
    var statusMessage = "Выберите папку iCloud Drive"
    var errorMessage: String?
    var isScanning = false
    var isEvicting = false
    var skippedFileCount = 0
    var scannedFileCount = 0

    @ObservationIgnored
    private var scanTask: Task<Void, Never>?

    @ObservationIgnored
    private var scanGeneration = 0

    var hasSelectedFolder: Bool {
        selectedFolderURL != nil
    }

    var selectedFolderDisplayPath: String {
        selectedFolderURL?.path(percentEncoded: false) ?? "Папка не выбрана"
    }

    var totalKnownByteSize: Int64 {
        files.reduce(0) { total, file in
            total + (file.byteSize ?? 0)
        }
    }

    var selectedFiles: [CloudFile] {
        files.filter { selectedFileIDs.contains($0.id) }
    }

    var selectedKnownByteSize: Int64 {
        selectedFiles.reduce(0) { total, file in
            total + (file.byteSize ?? 0)
        }
    }

    var fileSummary: String? {
        guard !files.isEmpty else {
            return nil
        }

        return "\(files.count) локальных iCloud-файлов • \(ByteCountFormatter.string(fromByteCount: totalKnownByteSize, countStyle: .file))"
    }

    var selectionSummary: String {
        guard !selectedFiles.isEmpty else {
            return "Ничего не выбрано"
        }

        return "Выбрано: \(selectedFiles.count) • \(ByteCountFormatter.string(fromByteCount: selectedKnownByteSize, countStyle: .file))"
    }

    var canEvictSingleSelectedFile: Bool {
        selectedFiles.count == 1 && !isScanning && !isEvicting
    }

    func chooseFolder() {
        guard let folderURL = FileAccess.selectFolder() else {
            return
        }

        do {
            try FileAccess.validateFolder(folderURL)

            selectedFolderURL = folderURL
            files = []
            selectedFileIDs = []
            errorMessage = nil
            isEvicting = false
            skippedFileCount = 0
            scannedFileCount = 0
            statusMessage = "Сканирование..."
            scanSelectedFolder()
        } catch {
            selectedFolderURL = nil
            files = []
            selectedFileIDs = []
            errorMessage = error.localizedDescription
            isEvicting = false
            skippedFileCount = 0
            scannedFileCount = 0
            statusMessage = "Не удалось выбрать папку"
        }
    }

    func scanSelectedFolder() {
        guard let selectedFolderURL else {
            return
        }

        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        isEvicting = false
        errorMessage = nil
        files = []
        selectedFileIDs = []
        skippedFileCount = 0
        scannedFileCount = 0
        statusMessage = "Сканирование..."

        scanTask = Task.detached(priority: .userInitiated) { [weak self, selectedFolderURL] in
            do {
                let result = try CloudFileScanner.scan(folderURL: selectedFolderURL) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.applyScanProgress(progress, generation: generation)
                    }
                }

                guard !Task.isCancelled else {
                    return
                }

                await MainActor.run { [weak self] in
                    self?.finishScan(result, generation: generation)
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.markScanStopped(generation: generation)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.failScan(error, generation: generation)
                }
            }
        }
    }

    func cancelScan() {
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        statusMessage = "Сканирование остановлено"
    }

    func evictSelectedFile() {
        guard canEvictSingleSelectedFile, let file = selectedFiles.first else {
            return
        }

        isEvicting = true
        errorMessage = nil
        statusMessage = "Выгружаем локальную копию..."
        updateEvictionResult(for: file.id, result: .pending)

        Task { [selectedFolderURL] in
            let result = await Task.detached(priority: .userInitiated) {
                CloudFileEvictor.evict(file, accessFolderURL: selectedFolderURL)
            }.value

            updateEvictionResult(for: file.id, result: result)
            isEvicting = false

            switch result {
            case .success:
                statusMessage = "Локальная копия выгружена"
            case .pending:
                statusMessage = "Выгружаем локальную копию..."
            case .skipped(let reason):
                statusMessage = "Файл пропущен: \(reason)"
            case .failure(let message):
                statusMessage = "Не удалось выгрузить файл"
                errorMessage = message
            }
        }
    }

    func selectAllFiles() {
        selectedFileIDs = Set(files.map(\.id))
    }

    func clearSelection() {
        selectedFileIDs = []
    }

    private func updateEvictionResult(for fileID: CloudFile.ID, result: EvictionResult) {
        guard let index = files.firstIndex(where: { $0.id == fileID }) else {
            return
        }

        files[index].evictionResult = result
    }

    private func applyScanProgress(_ progress: CloudFileScanner.ScanProgress, generation: Int) {
        guard generation == scanGeneration, isScanning else {
            return
        }

        appendScannedFiles(progress.candidateBatch)
        scannedFileCount = progress.scannedFileCount
        skippedFileCount = progress.skippedFileCount
        statusMessage = "Сканирование: \(progress.scannedFileCount) файлов, найдено \(progress.candidateFileCount)"
    }

    private func finishScan(_ result: CloudFileScanner.ScanResult, generation: Int) {
        guard generation == scanGeneration else {
            return
        }

        files = result.files
        skippedFileCount = result.skippedFileCount
        scannedFileCount = result.scannedFileCount
        statusMessage = result.files.isEmpty ? "Скачанные iCloud-файлы не найдены" : "Можно выгрузить: \(result.files.count)"
        isScanning = false
        scanTask = nil
    }

    private func markScanStopped(generation: Int) {
        guard generation == scanGeneration else {
            return
        }

        selectedFileIDs = []
        statusMessage = "Сканирование остановлено"
        isScanning = false
        scanTask = nil
    }

    private func failScan(_ error: Error, generation: Int) {
        guard generation == scanGeneration else {
            return
        }

        files = []
        selectedFileIDs = []
        skippedFileCount = 0
        errorMessage = error.localizedDescription
        statusMessage = "Не удалось просканировать папку"
        isScanning = false
        scanTask = nil
    }

    private func appendScannedFiles(_ newFiles: [CloudFile]) {
        guard !newFiles.isEmpty else {
            return
        }

        let existingIDs = Set(files.map(\.id))
        files.append(contentsOf: newFiles.filter { !existingIDs.contains($0.id) })
        files.sort { lhs, rhs in
            let lhsSize = lhs.byteSize ?? -1
            let rhsSize = rhs.byteSize ?? -1

            if lhsSize != rhsSize {
                return lhsSize > rhsSize
            }

            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }
}
