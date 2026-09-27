//
//  CloudFilesViewModel.swift
//  CloudeRm
//
//  Created by olchu on 28. 5. 2026..
//

import Foundation
import Observation

nonisolated enum CloudFolderFilter: String, CaseIterable, Identifiable, Sendable {
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

nonisolated enum CloudFolderSort: String, CaseIterable, Identifiable, Sendable {
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

nonisolated enum CloudFolderDownloadState: Hashable, Sendable {
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

nonisolated struct CloudFolderSummary: Identifiable, Hashable, Sendable {
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
    private(set) var files: [CloudFile] = []
    var selectedFileIDs: Set<CloudFile.ID> = []
    /// Folder whose contents the list shows; nil is the scanned root.
    var currentFolderPath: String? {
        didSet {
            guard currentFolderPath != oldValue else {
                return
            }

            rebuildDerivedState()
        }
    }
    var searchText = "" {
        didSet {
            rebuildDerivedState()
        }
    }
    var folderFilter: CloudFolderFilter = .all {
        didSet {
            rebuildDerivedState()
        }
    }
    var folderSort: CloudFolderSort = .size {
        didSet {
            rebuildDerivedState()
        }
    }
    var statusMessage = "Выберите папку iCloud Drive"
    var errorMessage: String?
    var isScanning = false
    var isEvicting = false
    var skippedFileCount = 0
    var scannedFileCount = 0
    private(set) var folderSummaries: [CloudFolderSummary] = []
    private(set) var filteredFolderSummaries: [CloudFolderSummary] = []
    private(set) var currentFolder: CloudFolderSummary?
    /// Local files directly inside the current folder.
    private(set) var levelFiles: [CloudFile] = []
    private(set) var levelCloudOnlyFileCount = 0
    private(set) var levelCloudOnlyByteSize: Int64 = 0
    private(set) var totalKnownByteSize: Int64 = 0
    private(set) var totalCloudByteSize: Int64 = 0
    private(set) var totalCloudOnlyByteSize: Int64 = 0

    @ObservationIgnored
    private var directoryTotals: [String: CloudFolderTotal] = [:]

    @ObservationIgnored
    private var scanTask: Task<Void, Never>?

    @ObservationIgnored
    private var scanGeneration = 0

    @ObservationIgnored
    private var progressFileIDs: Set<CloudFile.ID> = []

    @ObservationIgnored
    private var derivedStateTask: Task<Void, Never>?

    @ObservationIgnored
    private var derivedStateRevision = 0

    @ObservationIgnored
    private var snapshotLoadTask: Task<Void, Never>?

    @ObservationIgnored
    private var snapshotSaveTask: Task<Void, Never>?

    init() {
        restoreLastFolder()
    }

    var hasSelectedFolder: Bool {
        selectedFolderURL != nil
    }

    var selectedFolderDisplayPath: String {
        selectedFolderURL?.path(percentEncoded: false) ?? "Папка не выбрана"
    }

    var isCurrentLevelEmpty: Bool {
        filteredFolderSummaries.isEmpty && levelFiles.isEmpty
    }

    /// Breadcrumb for the current folder: (title, path) from the top down.
    var currentFolderTrail: [(title: String, path: String)] {
        guard let currentFolderPath else {
            return []
        }

        var trail: [(title: String, path: String)] = []
        var path = ""
        for component in currentFolderPath.split(separator: "/") {
            path = path.isEmpty ? String(component) : path + "/" + component
            trail.append((String(component), path))
        }
        return trail
    }

    func openFolder(_ path: String) {
        currentFolderPath = path
    }

    func openParentFolder() {
        guard let currentFolderPath, let slash = currentFolderPath.lastIndex(of: "/") else {
            self.currentFolderPath = nil
            return
        }

        self.currentFolderPath = String(currentFolderPath[..<slash])
    }

    func openRootFolder() {
        currentFolderPath = nil
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
            total + file.localByteSize
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

    var canEvictCurrentFolder: Bool {
        currentFolder?.canFreeUpSpace == true && !isScanning && !isEvicting
    }

    func chooseFolder() {
        guard let folderURL = FileAccess.selectFolder() else {
            return
        }

        useSelectedFolder(folderURL, initialStatus: "Сканирование...")
    }

    func analyzeDefaultICloudDriveFolder() {
        let folderURL = FileAccess.defaultICloudDriveFolderURL

        do {
            try useFolder(folderURL, initialStatus: "Анализируем iCloud Drive...")
        } catch {
            guard let confirmedFolderURL = FileAccess.selectICloudDriveFolder() else {
                errorMessage = error.localizedDescription
                statusMessage = "Нужен доступ к папке iCloud Drive"
                return
            }

            useSelectedFolder(confirmedFolderURL, initialStatus: "Анализируем iCloud Drive...")
        }
    }

    private func useSelectedFolder(_ folderURL: URL, initialStatus: String) {
        do {
            try useFolder(folderURL, initialStatus: initialStatus)
        } catch {
            selectedFolderURL = nil
            files = []
            directoryTotals = [:]
            resetDerivedState()
            selectedFileIDs = []
            currentFolderPath = nil
            errorMessage = error.localizedDescription
            isEvicting = false
            skippedFileCount = 0
            scannedFileCount = 0
            statusMessage = "Не удалось выбрать папку"
        }
    }

    private func useFolder(_ folderURL: URL, initialStatus: String) throws {
        try FileAccess.validateFolder(folderURL)
        CloudFileCache.saveLastFolder(folderURL)

        selectedFolderURL = folderURL
        files = []
        directoryTotals = [:]
        resetDerivedState()
        selectedFileIDs = []
        currentFolderPath = nil
        errorMessage = nil
        isEvicting = false
        skippedFileCount = 0
        scannedFileCount = 0
        statusMessage = initialStatus
        loadCachedSnapshot(for: folderURL)
        scanSelectedFolder()
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
        if files.isEmpty {
            statusMessage = "Ищем файлы в выбранной папке..."
        } else {
            statusMessage = "Обновление списка..."
        }
        selectedFileIDs = []
        skippedFileCount = 0
        scannedFileCount = 0
        progressFileIDs = Set(files.map(\.id))

        scanTask = Task { [weak self, selectedFolderURL] in
            do {
                let result = try await CloudFileDiskScanner.scan(folderURL: selectedFolderURL) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.applyScanProgress(progress, generation: generation)
                    }
                }

                guard !Task.isCancelled else {
                    return
                }

                self?.finishScan(result, generation: generation)
            } catch is CancellationError {
                self?.markScanStopped(generation: generation)
            } catch {
                self?.failFastScan(error, generation: generation)
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
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        isEvicting = false
        errorMessage = nil
        files = []
        directoryTotals = [:]
        resetDerivedState()
        selectedFileIDs = []
        currentFolderPath = nil
        skippedFileCount = 0
        scannedFileCount = 0
        progressFileIDs = []
        statusMessage = "Полное сканирование..."

        scanTask = Task.detached(priority: .userInitiated) { [weak self, selectedFolderURL] in
            do {
                let result = try await Self.scanWithFileManager(folderURL: selectedFolderURL) { [weak self] progress in
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
                recordEviction(of: [file])
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

    func evictCurrentFolderLocalCopies() {
        guard canEvictCurrentFolder, let folder = currentFolder else {
            return
        }

        let filesToEvict = folder.files.filter { $0.downloadStatus.isStoredLocally }
        guard !filesToEvict.isEmpty else {
            return
        }

        isEvicting = true
        errorMessage = nil
        statusMessage = "Выгружаем локальные копии..."

        let fileIDsToEvict = Set(filesToEvict.map(\.id))
        updateEvictionResults(for: fileIDsToEvict, result: .pending)

        Task { [selectedFolderURL] in
            let results = await Task.detached(priority: .userInitiated) {
                CloudFileEvictor.evict(filesToEvict, accessFolderURL: selectedFolderURL)
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

            recordEviction(of: filesToEvict.filter { successfulIDs.contains($0.id) })
            files.removeAll { successfulIDs.contains($0.id) }
            selectedFileIDs.subtract(successfulIDs)

            let failuresByID = Dictionary(uniqueKeysWithValues: failedResults)
            for index in files.indices {
                if let result = failuresByID[files[index].id] {
                    files[index].evictionResult = result
                }
            }
            rebuildDerivedState()

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

    private func updateEvictionResults(for fileIDs: Set<CloudFile.ID>, result: EvictionResult) {
        for index in files.indices where fileIDs.contains(files[index].id) {
            files[index].evictionResult = result
        }
    }

    /// Evicted files leave the list but stay in iCloud, so their size moves
    /// to the folder's cloud-only total.
    private func recordEviction(of evictedFiles: [CloudFile]) {
        for file in evictedFiles {
            for path in CloudFolderTotal.ancestorPaths(of: file.relativePath) {
                directoryTotals[path]?.cloudOnlyByteSize += file.byteSize ?? file.localByteSize
            }
        }
    }

    private func removeEvictedFile(withID fileID: CloudFile.ID) {
        files.removeAll { $0.id == fileID }
        selectedFileIDs.remove(fileID)
        rebuildDerivedState()
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
        snapshotLoadTask?.cancel()
        snapshotLoadTask = Task { [weak self] in
            guard let snapshot = await CloudFileCacheStore.shared.loadSnapshot(for: folderURL) else {
                return
            }

            guard
                !Task.isCancelled,
                self?.selectedFolderURL == folderURL,
                self?.scannedFileCount == 0,
                self?.files.isEmpty == true
            else {
                return
            }

            self?.files = snapshot.files.map(\.cloudFile)
            self?.directoryTotals = snapshot.directoryTotals ?? [:]
            self?.selectedFileIDs = []
            self?.progressFileIDs = Set(snapshot.files.map(\.url))
            self?.rebuildDerivedState()
            self?.statusMessage = "Показан кеш от \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        }
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
        directoryTotals = result.directoryTotals
        rebuildDerivedState()
        skippedFileCount = result.skippedFileCount
        scannedFileCount = result.scannedFileCount
        progressFileIDs = Set(result.files.map(\.id))
        statusMessage = result.files.isEmpty ? "Локальные iCloud-файлы не найдены" : "Найдено: \(result.files.count)"
        if result.notSyncedFileCount > 0 {
            let notSyncedSize = ByteCountFormatter.string(fromByteCount: result.notSyncedByteSize, countStyle: .file)
            statusMessage += " • не синхронизируются с iCloud: \(result.notSyncedFileCount) (\(notSyncedSize))"
        }
        isScanning = false
        scanTask = nil
        saveCurrentSnapshot()
    }

    private func failFastScan(_ error: Error, generation: Int) {
        guard generation == scanGeneration else {
            return
        }

        files = []
        directoryTotals = [:]
        resetDerivedState()
        selectedFileIDs = []
        currentFolderPath = nil
        skippedFileCount = 0
        scannedFileCount = 0
        errorMessage = error.localizedDescription
        statusMessage = "Быстрый поиск недоступен. Используйте Full Scan."
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
        directoryTotals = [:]
        resetDerivedState()
        selectedFileIDs = []
        currentFolderPath = nil
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

        let uniqueFiles = newFiles.filter { progressFileIDs.insert($0.id).inserted }
        guard !uniqueFiles.isEmpty else {
            return
        }

        files.append(contentsOf: uniqueFiles)
        rebuildDerivedState()
    }

    /// A rescan or eviction can remove the open folder; fall back to the root.
    private func ensureCurrentFolderStillExists() {
        if currentFolderPath != nil, currentFolder == nil {
            currentFolderPath = nil
        }
    }

    private func rebuildDerivedState() {
        derivedStateTask?.cancel()
        derivedStateRevision += 1
        let revision = derivedStateRevision
        let filesSnapshot = files
        let totalsSnapshot = directoryTotals
        let folderPath = currentFolderPath
        let filter = folderFilter
        let sort = folderSort
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        derivedStateTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else {
                return
            }

            let state = Self.makeDerivedState(
                files: filesSnapshot,
                directoryTotals: totalsSnapshot,
                currentFolderPath: folderPath,
                filter: filter,
                sort: sort,
                searchQuery: query
            )

            guard !Task.isCancelled else {
                return
            }

            await self?.applyDerivedState(state, revision: revision)
        }
    }

    private func applyDerivedState(_ state: DerivedState, revision: Int) {
        guard revision == derivedStateRevision else {
            return
        }

        folderSummaries = state.folderSummaries
        filteredFolderSummaries = state.filteredFolderSummaries
        currentFolder = state.currentFolder
        levelFiles = state.levelFiles
        levelCloudOnlyFileCount = state.levelCloudOnlyFileCount
        levelCloudOnlyByteSize = state.levelCloudOnlyByteSize
        totalKnownByteSize = state.totalKnownByteSize
        totalCloudByteSize = state.totalCloudByteSize
        totalCloudOnlyByteSize = state.totalCloudOnlyByteSize
        ensureCurrentFolderStillExists()
        derivedStateTask = nil
    }

    private func resetDerivedState() {
        derivedStateTask?.cancel()
        derivedStateTask = nil
        derivedStateRevision += 1
        folderSummaries = []
        filteredFolderSummaries = []
        currentFolder = nil
        levelFiles = []
        levelCloudOnlyFileCount = 0
        levelCloudOnlyByteSize = 0
        totalKnownByteSize = 0
        totalCloudByteSize = 0
        totalCloudOnlyByteSize = 0
    }

    nonisolated private static func makeDerivedState(
        files: [CloudFile],
        directoryTotals: [String: CloudFolderTotal],
        currentFolderPath: String?,
        filter: CloudFolderFilter,
        sort: CloudFolderSort,
        searchQuery: String
    ) -> DerivedState {
        let prefix = currentFolderPath.map { $0 + "/" } ?? ""
        var totalKnownByteSize: Int64 = 0
        var currentFolderFiles: [CloudFile] = []
        var filesByChildFolder: [String: [CloudFile]] = [:]
        var levelFiles: [CloudFile] = []

        for file in files {
            if file.downloadStatus.isStoredLocally {
                totalKnownByteSize += file.localByteSize
            }

            guard file.relativePath.hasPrefix(prefix) else {
                continue
            }

            currentFolderFiles.append(file)
            let remainder = file.relativePath.dropFirst(prefix.count)
            if let slash = remainder.firstIndex(of: "/") {
                filesByChildFolder[prefix + remainder[..<slash], default: []].append(file)
            } else {
                levelFiles.append(file)
            }
        }

        // Folders with no local files are known only from the scan totals.
        var childPaths = Set(filesByChildFolder.keys)
        for path in directoryTotals.keys where !path.isEmpty && path.hasPrefix(prefix) {
            if !path.dropFirst(prefix.count).contains("/") {
                childPaths.insert(path)
            }
        }

        let summaries = childPaths
            .map { folderSummary(path: $0, files: filesByChildFolder[$0] ?? [], total: directoryTotals[$0]) }
            .sorted { sortFolderSummaries($0, $1, by: sort) }
        let filteredSummaries = summaries.filter {
            matches($0, filter: filter) && matches($0, searchQuery: searchQuery)
        }

        let showsFiles = filter == .all || filter == .downloaded
        let filteredLevelFiles = !showsFiles ? [] : levelFiles
            .filter { searchQuery.isEmpty || $0.displayName.localizedCaseInsensitiveContains(searchQuery) }
            .sorted { $0.localByteSize > $1.localByteSize }

        // Files directly in this folder that are only in iCloud: the folder
        // total minus its subfolders' totals minus the local files.
        let levelTotal = directoryTotals[currentFolderPath ?? ""]
        let childTotals = childPaths.compactMap { directoryTotals[$0] }
        let levelFileCount = (levelTotal?.fileCount ?? 0) - childTotals.reduce(0) { $0 + $1.fileCount }
        let levelCloudOnlyByteSize = (levelTotal?.cloudOnlyByteSize ?? 0) - childTotals.reduce(0) { $0 + $1.cloudOnlyByteSize }

        let rootTotal = directoryTotals[""]
        let fallbackCloudByteSize = files.reduce(Int64(0)) { $0 + ($1.byteSize ?? 0) }

        return DerivedState(
            folderSummaries: summaries,
            filteredFolderSummaries: filteredSummaries,
            currentFolder: currentFolderPath.flatMap { path in
                currentFolderFiles.isEmpty && directoryTotals[path] == nil
                    ? nil
                    : folderSummary(path: path, files: currentFolderFiles, total: directoryTotals[path])
            },
            levelFiles: filteredLevelFiles,
            levelCloudOnlyFileCount: max(0, levelFileCount - levelFiles.count),
            levelCloudOnlyByteSize: max(0, levelCloudOnlyByteSize),
            totalKnownByteSize: totalKnownByteSize,
            totalCloudByteSize: max(rootTotal?.byteSize ?? fallbackCloudByteSize, totalKnownByteSize),
            totalCloudOnlyByteSize: rootTotal?.cloudOnlyByteSize ?? 0
        )
    }

    /// `files` are the local files anywhere inside the folder.
    nonisolated private static func folderSummary(
        path: String,
        files: [CloudFile],
        total: CloudFolderTotal?
    ) -> CloudFolderSummary {
        let localByteSize = files.reduce(Int64(0)) { sum, file in
            sum + (file.downloadStatus.isStoredLocally ? file.localByteSize : 0)
        }
        let cloudByteSize = total?.byteSize ?? files.reduce(Int64(0)) { $0 + ($1.byteSize ?? 0) }
        let lastModified = (files.compactMap(\.modificationDate) + [total?.lastModified].compactMap { $0 }).max()

        return CloudFolderSummary(
            id: path,
            name: path.split(separator: "/").last.map(String.init) ?? path,
            relativePath: path,
            files: files,
            fileCount: max(total?.fileCount ?? 0, files.count),
            folderCount: total?.folderCount ?? 0,
            localByteSize: localByteSize,
            cloudByteSize: max(cloudByteSize, localByteSize),
            lastModified: lastModified
        )
    }

    nonisolated private static func matches(_ folder: CloudFolderSummary, filter: CloudFolderFilter) -> Bool {
        switch filter {
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

    nonisolated private static func matches(_ folder: CloudFolderSummary, searchQuery: String) -> Bool {
        guard !searchQuery.isEmpty else {
            return true
        }

        return folder.name.localizedCaseInsensitiveContains(searchQuery)
            || folder.relativePath.localizedCaseInsensitiveContains(searchQuery)
    }

    nonisolated private static func sortFolderSummaries(
        _ lhs: CloudFolderSummary,
        _ rhs: CloudFolderSummary,
        by sort: CloudFolderSort
    ) -> Bool {
        switch sort {
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

    private func saveCurrentSnapshot() {
        guard let selectedFolderURL else {
            return
        }

        let filesSnapshot = files
        let totalsSnapshot = directoryTotals
        snapshotSaveTask?.cancel()
        snapshotSaveTask = Task {
            await CloudFileCacheStore.shared.saveSnapshot(
                folderURL: selectedFolderURL,
                files: filesSnapshot,
                directoryTotals: totalsSnapshot
            )
        }
    }

    nonisolated private static func scanWithFileManager(
        folderURL: URL,
        onProgress: (@Sendable (CloudFileScanner.ScanProgress) -> Void)? = nil
    ) async throws -> CloudFileScanner.ScanResult {
        try await Task.detached(priority: .userInitiated) {
            try CloudFileScanner.scan(folderURL: folderURL, onProgress: onProgress)
        }.value
    }

    nonisolated private static let largeFolderThreshold: Int64 = 1_000_000_000

    nonisolated private struct DerivedState: Sendable {
        let folderSummaries: [CloudFolderSummary]
        let filteredFolderSummaries: [CloudFolderSummary]
        let currentFolder: CloudFolderSummary?
        let levelFiles: [CloudFile]
        let levelCloudOnlyFileCount: Int
        let levelCloudOnlyByteSize: Int64
        let totalKnownByteSize: Int64
        let totalCloudByteSize: Int64
        let totalCloudOnlyByteSize: Int64
    }
}
