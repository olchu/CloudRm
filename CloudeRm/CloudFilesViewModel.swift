//
//  CloudFilesViewModel.swift
//  CloudeRm
//
//  Created by olchu on 28. 5. 2026..
//

import Foundation
import Observation

enum CloudFolderFilter: String, CaseIterable, Identifiable {
    case all
    case downloaded
    case cloudOnly
    case partial
    case largeFolders

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            "All"
        case .downloaded:
            "Downloaded"
        case .cloudOnly:
            "Cloud Only"
        case .partial:
            "Partial"
        case .largeFolders:
            "Large Folders"
        }
    }
}

enum CloudFolderSort: String, CaseIterable, Identifiable {
    case size
    case name
    case modified
    case files

    var id: Self { self }

    var title: String {
        switch self {
        case .size:
            "Size"
        case .name:
            "Name"
        case .modified:
            "Updated"
        case .files:
            "Files"
        }
    }
}

enum CloudFolderDownloadState: Hashable {
    case downloaded
    case cloudOnly
    case partial

    var title: String {
        switch self {
        case .downloaded:
            "Downloaded"
        case .cloudOnly:
            "Cloud Only"
        case .partial:
            "Partially Downloaded"
        }
    }
}

struct CloudFolderSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let relativePath: String
    let files: [CloudFile]
    let fileCount: Int
    let folderCount: Int
    let localByteSize: Int64
    let cloudByteSize: Int64
    let lastModified: Date?

    var downloadedFraction: Double {
        guard cloudByteSize > 0 else {
            return localByteSize > 0 ? 1 : 0
        }

        return min(1, max(0, Double(localByteSize) / Double(cloudByteSize)))
    }

    var downloadState: CloudFolderDownloadState {
        if localByteSize == 0 {
            return .cloudOnly
        }

        if downloadedFraction >= 0.995 {
            return .downloaded
        }

        return .partial
    }

    var canFreeUpSpace: Bool {
        localByteSize > 0 && files.contains { $0.downloadStatus.isStoredLocally }
    }
}

@MainActor
@Observable
final class CloudFilesViewModel {
    var selectedFolderURL: URL?
    var files: [CloudFile] = []
    var selectedFileIDs: Set<CloudFile.ID> = []
    var selectedFolderID: CloudFolderSummary.ID?
    var searchText = ""
    var folderFilter: CloudFolderFilter = .all {
        didSet {
            ensureSelectedFolderStillExists()
        }
    }
    var folderSort: CloudFolderSort = .size {
        didSet {
            ensureSelectedFolderStillExists()
        }
    }
    var statusMessage = "Выберите папку iCloud Drive"
    var errorMessage: String?
    var isScanning = false
    var isEvicting = false
    var skippedFileCount = 0
    var scannedFileCount = 0

    @ObservationIgnored
    private var scanTask: Task<Void, Never>?

    @ObservationIgnored
    private var metadataScanner: CloudFileMetadataScanner?

    @ObservationIgnored
    private var scanGeneration = 0

    init() {
        restoreLastFolder()
    }

    var hasSelectedFolder: Bool {
        selectedFolderURL != nil
    }

    var selectedFolderDisplayPath: String {
        selectedFolderURL?.path(percentEncoded: false) ?? "Папка не выбрана"
    }

    var totalKnownByteSize: Int64 {
        files.reduce(0) { total, file in
            total + (file.downloadStatus.isStoredLocally ? (file.byteSize ?? 0) : 0)
        }
    }

    var totalCloudByteSize: Int64 {
        files.reduce(0) { total, file in
            total + (file.byteSize ?? 0)
        }
    }

    var potentialFreeUpByteSize: Int64 {
        totalKnownByteSize
    }

    var folderSummaries: [CloudFolderSummary] {
        let groupedFiles = Dictionary(grouping: files, by: folderKey(for:))

        return groupedFiles.map { key, groupedFiles in
            let sortedFiles = groupedFiles.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            let localByteSize = sortedFiles.reduce(Int64(0)) { total, file in
                total + (file.downloadStatus.isStoredLocally ? (file.byteSize ?? 0) : 0)
            }
            let cloudByteSize = sortedFiles.reduce(Int64(0)) { total, file in
                total + (file.byteSize ?? 0)
            }
            let folderCount = Set(
                sortedFiles.compactMap { file -> String? in
                    guard let slashIndex = file.relativePath.lastIndex(of: "/") else {
                        return nil
                    }

                    return String(file.relativePath[..<slashIndex])
                }
            ).count
            let lastModified = sortedFiles.compactMap(\.modificationDate).max()

            return CloudFolderSummary(
                id: key,
                name: folderName(for: key, files: sortedFiles),
                relativePath: key,
                files: sortedFiles,
                fileCount: sortedFiles.count,
                folderCount: folderCount,
                localByteSize: localByteSize,
                cloudByteSize: max(cloudByteSize, localByteSize),
                lastModified: lastModified
            )
        }
        .sorted(by: sortFolderSummaries)
    }

    var filteredFolderSummaries: [CloudFolderSummary] {
        folderSummaries
            .filter(matchesCurrentFilter)
            .filter(matchesSearch)
            .sorted(by: sortFolderSummaries)
    }

    var selectedFolderSummary: CloudFolderSummary? {
        guard let selectedFolderID else {
            return nil
        }

        return filteredFolderSummaries.first { $0.id == selectedFolderID }
    }

    var downloadedFolderCount: Int {
        folderSummaries.filter { $0.downloadState == .downloaded }.count
    }

    var cloudOnlyFolderCount: Int {
        folderSummaries.filter { $0.downloadState == .cloudOnly }.count
    }

    var partialFolderCount: Int {
        folderSummaries.filter { $0.downloadState == .partial }.count
    }

    var largeFolderCount: Int {
        folderSummaries.filter { $0.cloudByteSize >= Self.largeFolderThreshold }.count
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

        let cloudText = ByteCountFormatter.string(fromByteCount: totalCloudByteSize, countStyle: .file)
        let localText = ByteCountFormatter.string(fromByteCount: totalKnownByteSize, countStyle: .file)
        return "\(files.count) iCloud-файлов • \(localText) на Mac • \(cloudText) в iCloud"
    }

    var selectionSummary: String {
        guard !selectedFiles.isEmpty else {
            return "Ничего не выбрано"
        }

        return "Выбрано: \(selectedFiles.count) • \(ByteCountFormatter.string(fromByteCount: selectedKnownByteSize, countStyle: .file))"
    }

    var canEvictSingleSelectedFile: Bool {
        selectedFiles.count == 1 && selectedFiles.first?.downloadStatus.isStoredLocally == true && !isScanning && !isEvicting
    }

    var canEvictSelectedFolder: Bool {
        selectedFolderSummary?.canFreeUpSpace == true && !isScanning && !isEvicting
    }

    func chooseFolder() {
        guard let folderURL = FileAccess.selectFolder() else {
            return
        }

        do {
            try FileAccess.validateFolder(folderURL)
            CloudFileCache.saveLastFolder(folderURL)

            selectedFolderURL = folderURL
            files = []
            selectedFileIDs = []
            selectedFolderID = nil
            errorMessage = nil
            isEvicting = false
            skippedFileCount = 0
            scannedFileCount = 0
            statusMessage = "Сканирование..."
            loadCachedSnapshot(for: folderURL)
            scanSelectedFolder()
        } catch {
            selectedFolderURL = nil
            files = []
            selectedFileIDs = []
            selectedFolderID = nil
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
        metadataScanner?.cancel()
        metadataScanner = nil
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        isEvicting = false
        errorMessage = nil
        if files.isEmpty {
            statusMessage = "Быстрый поиск..."
        } else {
            statusMessage = "Обновление списка..."
        }
        selectedFileIDs = []
        skippedFileCount = 0
        scannedFileCount = 0

        scanTask = Task { [weak self, selectedFolderURL] in
            guard let self else {
                return
            }

            do {
                let scanner = CloudFileMetadataScanner(folderURL: selectedFolderURL) { [weak self] progress in
                    self?.applyScanProgress(progress, generation: generation)
                }
                metadataScanner = scanner
                let result = try await scanner.start()

                guard !Task.isCancelled else {
                    return
                }

                finishScan(result, generation: generation)
            } catch is CancellationError, is CloudFileMetadataScanner.MetadataScanError {
                markScanStopped(generation: generation)
            } catch {
                failScan(error, generation: generation)
            }
        }
    }

    func refreshSelectedFolder() {
        scanSelectedFolder()
    }

    func scanSelectedFolderWithFileManagerFallback() {
        guard let selectedFolderURL else {
            return
        }

        scanTask?.cancel()
        metadataScanner?.cancel()
        metadataScanner = nil
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        isEvicting = false
        errorMessage = nil
        files = []
        selectedFileIDs = []
        selectedFolderID = nil
        skippedFileCount = 0
        scannedFileCount = 0
        statusMessage = "Полное сканирование..."

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
        metadataScanner?.cancel()
        metadataScanner = nil
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        statusMessage = "Сканирование остановлено"
    }

    func evictSelectedFile() {
        guard canEvictSingleSelectedFile, let file = selectedFiles.first else {
            return
        }

        evictFile(file)
    }

    func evictFile(_ file: CloudFile) {
        guard file.downloadStatus.isStoredLocally, !isScanning, !isEvicting else {
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

            isEvicting = false

            switch result {
            case .success:
                removeEvictedFile(withID: file.id)
                saveCurrentSnapshot()
                statusMessage = "Локальная копия выгружена"
            case .pending:
                updateEvictionResult(for: file.id, result: result)
                statusMessage = "Выгружаем локальную копию..."
            case .skipped(let reason):
                updateEvictionResult(for: file.id, result: result)
                statusMessage = "Файл пропущен: \(reason)"
            case .failure(let message):
                updateEvictionResult(for: file.id, result: result)
                statusMessage = "Не удалось выгрузить файл"
                errorMessage = message
            }
        }
    }

    func evictSelectedFolderLocalCopies() {
        guard canEvictSelectedFolder, let folder = selectedFolderSummary else {
            return
        }

        let filesToEvict = folder.files.filter { $0.downloadStatus.isStoredLocally }
        guard !filesToEvict.isEmpty else {
            return
        }

        isEvicting = true
        errorMessage = nil
        statusMessage = "Выгружаем локальные копии..."

        for file in filesToEvict {
            updateEvictionResult(for: file.id, result: .pending)
        }

        Task { [selectedFolderURL] in
            let results = await Task.detached(priority: .userInitiated) {
                filesToEvict.map { file in
                    (file.id, CloudFileEvictor.evict(file, accessFolderURL: selectedFolderURL))
                }
            }.value

            let successfulIDs = Set(results.compactMap { fileID, result in
                if case .success = result {
                    return fileID
                }

                return nil
            })
            let failedResults = results.filter { fileID, result in
                if successfulIDs.contains(fileID) {
                    return false
                }

                if case .pending = result {
                    return false
                }

                return true
            }

            for fileID in successfulIDs {
                removeEvictedFile(withID: fileID)
            }

            for (fileID, result) in failedResults {
                updateEvictionResult(for: fileID, result: result)
            }

            isEvicting = false
            saveCurrentSnapshot()

            if successfulIDs.count == filesToEvict.count {
                statusMessage = "Локальные копии выгружены: \(successfulIDs.count)"
            } else if successfulIDs.isEmpty {
                statusMessage = "Не удалось выгрузить выбранную папку"
                errorMessage = failedResults.first?.1.displayName
            } else {
                statusMessage = "Выгружено: \(successfulIDs.count), осталось: \(filesToEvict.count - successfulIDs.count)"
                errorMessage = failedResults.first?.1.displayName
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

    private func removeEvictedFile(withID fileID: CloudFile.ID) {
        files.removeAll { $0.id == fileID }
        selectedFileIDs.remove(fileID)
        ensureSelectedFolderStillExists()
    }

    private func restoreLastFolder() {
        guard let folderURL = CloudFileCache.loadLastFolder() else {
            return
        }

        selectedFolderURL = folderURL
        loadCachedSnapshot(for: folderURL)

        if files.isEmpty {
            statusMessage = "Последняя папка восстановлена. Нажмите Scan Now."
        } else {
            statusMessage = "Показан последний результат. Scan Now обновит список."
        }
    }

    private func loadCachedSnapshot(for folderURL: URL) {
        guard let snapshot = CloudFileCache.loadSnapshot(for: folderURL) else {
            return
        }

        files = snapshot.files.map(\.cloudFile)
        selectedFileIDs = []
        ensureSelectedFolderStillExists()
        statusMessage = "Показан кеш от \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func applyScanProgress(_ progress: CloudFileScanner.ScanProgress, generation: Int) {
        guard generation == scanGeneration, isScanning else {
            return
        }

        appendScannedFiles(progress.candidateBatch)
        scannedFileCount = progress.scannedFileCount
        skippedFileCount = progress.skippedFileCount
        statusMessage = "Сканирование: \(progress.scannedFileCount) файлов, найдено \(progress.candidateFileCount)"
        ensureSelectedFolderStillExists()
    }

    private func finishScan(_ result: CloudFileScanner.ScanResult, generation: Int) {
        guard generation == scanGeneration else {
            return
        }

        files = result.files
        skippedFileCount = result.skippedFileCount
        scannedFileCount = result.scannedFileCount
        ensureSelectedFolderStillExists()
        statusMessage = result.files.isEmpty ? "iCloud-файлы не найдены" : "Найдено: \(result.files.count)"
        isScanning = false
        scanTask = nil
        metadataScanner = nil
        saveCurrentSnapshot()
    }

    private func markScanStopped(generation: Int) {
        guard generation == scanGeneration else {
            return
        }

        selectedFileIDs = []
        statusMessage = "Сканирование остановлено"
        isScanning = false
        scanTask = nil
        metadataScanner = nil
    }

    private func failScan(_ error: Error, generation: Int) {
        guard generation == scanGeneration else {
            return
        }

        files = []
        selectedFileIDs = []
        selectedFolderID = nil
        skippedFileCount = 0
        errorMessage = error.localizedDescription
        statusMessage = "Не удалось просканировать папку"
        isScanning = false
        scanTask = nil
        metadataScanner = nil
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

    private func ensureSelectedFolderStillExists() {
        guard let selectedFolderID else {
            return
        }

        if !filteredFolderSummaries.contains(where: { $0.id == selectedFolderID }) {
            self.selectedFolderID = nil
        }
    }

    private func matchesCurrentFilter(_ folder: CloudFolderSummary) -> Bool {
        switch folderFilter {
        case .all:
            return true
        case .downloaded:
            return folder.downloadState == .downloaded
        case .cloudOnly:
            return folder.downloadState == .cloudOnly
        case .partial:
            return folder.downloadState == .partial
        case .largeFolders:
            return folder.cloudByteSize >= Self.largeFolderThreshold
        }
    }

    private func matchesSearch(_ folder: CloudFolderSummary) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return true
        }

        return folder.name.localizedCaseInsensitiveContains(query)
            || folder.relativePath.localizedCaseInsensitiveContains(query)
    }

    private func sortFolderSummaries(_ lhs: CloudFolderSummary, _ rhs: CloudFolderSummary) -> Bool {
        switch folderSort {
        case .size:
            if lhs.cloudByteSize != rhs.cloudByteSize {
                return lhs.cloudByteSize > rhs.cloudByteSize
            }
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .modified:
            if lhs.lastModified != rhs.lastModified {
                return (lhs.lastModified ?? .distantPast) > (rhs.lastModified ?? .distantPast)
            }
        case .files:
            if lhs.fileCount != rhs.fileCount {
                return lhs.fileCount > rhs.fileCount
            }
        }

        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func folderKey(for file: CloudFile) -> String {
        let parts = file.relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let firstPart = parts.first else {
            return file.displayName
        }

        return firstPart
    }

    private func folderName(for key: String, files: [CloudFile]) -> String {
        if files.count == 1, files.first?.relativePath.contains("/") == false {
            return "Root Files"
        }

        return key
    }

    private func saveCurrentSnapshot() {
        guard let selectedFolderURL else {
            return
        }

        CloudFileCache.saveSnapshot(folderURL: selectedFolderURL, files: files)
    }

    private static let largeFolderThreshold: Int64 = 1_000_000_000
}
