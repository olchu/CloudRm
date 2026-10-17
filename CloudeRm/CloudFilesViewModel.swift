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

/// Progress of the eviction queue; files added while it runs extend the totals.
nonisolated struct EvictionProgress: Sendable {
    var totalCount = 0
    var completedCount = 0
    var failedCount = 0
    var totalByteSize: Int64 = 0
    var freedByteSize: Int64 = 0
    var firstFailure: String?

    var fraction: Double {
        totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0
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
}

@MainActor
@Observable
final class CloudFilesViewModel {
    var selectedFolderURL: URL?
    private(set) var files: [CloudFile] = []
    /// Folder whose contents the list shows; nil is the scanned root.
    var currentFolderPath: String? {
        didSet {
            if currentFolderPath != oldValue {
                rebuildDerivedState()
            }
        }
    }
    var searchText = "" {
        didSet {
            if searchText != oldValue {
                rebuildDerivedState()
            }
        }
    }
    var folderFilter: CloudFolderFilter = .all {
        didSet {
            if folderFilter != oldValue {
                rebuildDerivedState()
            }
        }
    }
    var folderSort: CloudFolderSort = .size {
        didSet {
            if folderSort != oldValue {
                rebuildDerivedState()
            }
        }
    }
    var statusMessage = "Choose an iCloud Drive folder"
    var errorMessage: String?
    var isScanning = false
    /// Non-nil while files are being evicted.
    private(set) var evictionProgress: EvictionProgress?
    /// Files queued or being evicted; they stay listed until they are done.
    private(set) var evictingFileIDs: Set<CloudFile.ID> = []
    var scannedFileCount = 0
    /// Everything the list and summary show, computed off the main actor.
    private(set) var derived = DerivedState()

    @ObservationIgnored
    private var directoryTotals: [String: CloudFolderTotal] = [:]

    @ObservationIgnored
    private var scanTask: Task<Void, Never>?

    @ObservationIgnored
    private var scanGeneration = 0

    @ObservationIgnored
    private var progressFileIDs: Set<CloudFile.ID> = []

    @ObservationIgnored
    private var evictionQueue: [CloudFile] = []

    @ObservationIgnored
    private var evictionTask: Task<Void, Never>?

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

    var currentFolder: CloudFolderSummary? {
        derived.currentFolder
    }

    var isCurrentLevelEmpty: Bool {
        derived.filteredFolderSummaries.isEmpty && derived.levelFiles.isEmpty
    }

    var primaryScanTitle: String {
        hasSelectedFolder ? "Scan Now" : "Analyze iCloud Drive"
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

    var isEvicting: Bool {
        evictionProgress != nil
    }

    /// The open folder still has local files that are not queued for eviction.
    var canEvictCurrentFolder: Bool {
        !isScanning && currentFolder?.files.contains { isEvictable($0) } == true
    }

    var isEvictingCurrentFolder: Bool {
        currentFolder?.files.contains { evictingFileIDs.contains($0.id) } == true
    }

    /// Rescans the selected folder, or analyzes iCloud Drive when none is selected.
    func scanOrAnalyze() {
        if hasSelectedFolder {
            scanSelectedFolder()
        } else {
            analyzeDefaultICloudDriveFolder()
        }
    }

    func chooseFolder() {
        guard !isEvicting, let folderURL = FileAccess.selectFolder() else {
            return
        }

        useSelectedFolder(folderURL, initialStatus: "Scanning...")
    }

    func analyzeDefaultICloudDriveFolder() {
        guard !isEvicting else {
            return
        }

        let folderURL = FileAccess.defaultICloudDriveFolderURL

        do {
            try useFolder(folderURL, initialStatus: "Analyzing iCloud Drive...")
        } catch {
            guard let confirmedFolderURL = FileAccess.selectICloudDriveFolder() else {
                errorMessage = error.localizedDescription
                statusMessage = "Access to the iCloud Drive folder is required"
                return
            }

            useSelectedFolder(confirmedFolderURL, initialStatus: "Analyzing iCloud Drive...")
        }
    }

    private func useSelectedFolder(_ folderURL: URL, initialStatus: String) {
        do {
            try useFolder(folderURL, initialStatus: initialStatus)
        } catch {
            selectedFolderURL = nil
            clearResults()
            errorMessage = error.localizedDescription
            statusMessage = "Could not open the folder"
        }
    }

    private func useFolder(_ folderURL: URL, initialStatus: String) throws {
        try FileAccess.validateFolder(folderURL)
        CloudFileCache.saveLastFolder(folderURL)

        selectedFolderURL = folderURL
        clearResults()
        errorMessage = nil
        statusMessage = initialStatus
        loadCachedSnapshot(for: folderURL)
        scanSelectedFolder()
    }

    /// Clears scan results and everything derived from them.
    private func clearResults() {
        files = []
        directoryTotals = [:]
        currentFolderPath = nil
        resetDerivedState()
        scannedFileCount = 0
    }

    func scanSelectedFolder() {
        startScan(fullScan: false)
    }

    func scanSelectedFolderWithFileManagerFallback() {
        startScan(fullScan: true)
    }

    /// The fast scan reads attributes straight from disk and keeps the current
    /// results until it finishes; the full scan asks FileManager about every
    /// item and starts from an empty list.
    private func startScan(fullScan: Bool) {
        guard let selectedFolderURL, !isEvicting else {
            return
        }

        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        if fullScan {
            clearResults()
            statusMessage = "Running full scan..."
        } else {
            statusMessage = files.isEmpty ? "Looking for files in the selected folder..." : "Refreshing..."
        }
        isScanning = true
        errorMessage = nil
        scannedFileCount = 0
        progressFileIDs = Set(files.map(\.id))

        scanTask = Task { [weak self] in
            let onProgress: @Sendable (CloudFileScanner.ScanProgress) -> Void = { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.applyScanProgress(progress, generation: generation)
                }
            }

            do {
                let result = fullScan
                    ? try await CloudFileScanner.scan(folderURL: selectedFolderURL, onProgress: onProgress)
                    : try await CloudFileDiskScanner.scan(folderURL: selectedFolderURL, onProgress: onProgress)

                guard !Task.isCancelled else {
                    return
                }

                self?.finishScan(result, generation: generation)
            } catch is CancellationError {
                self?.markScanStopped(generation: generation)
            } catch {
                self?.failScan(
                    error,
                    status: fullScan ? "Could not scan the folder" : "Fast scan is unavailable. Use Full Scan.",
                    generation: generation
                )
            }
        }
    }

    func cancelScan() {
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        statusMessage = "Scan stopped"
    }

    func evictFile(_ file: CloudFile) {
        evict([file])
    }

    func evictCurrentFolderLocalCopies() {
        guard canEvictCurrentFolder, let folder = currentFolder else {
            return
        }

        evict(folder.files)
    }

    private func isEvictable(_ file: CloudFile) -> Bool {
        file.downloadStatus.isStoredLocally && !evictingFileIDs.contains(file.id)
    }

    /// Adds files to the eviction queue, starting it if it is idle. More files
    /// can be queued while it runs.
    private func evict(_ filesToEvict: [CloudFile]) {
        let newFiles = filesToEvict.filter(isEvictable)
        guard !newFiles.isEmpty, !isScanning else {
            return
        }

        evictingFileIDs.formUnion(newFiles.map(\.id))
        evictionQueue.append(contentsOf: newFiles)
        var progress = evictionProgress ?? EvictionProgress()
        progress.totalCount += newFiles.count
        progress.totalByteSize += newFiles.reduce(0) { $0 + $1.localByteSize }
        evictionProgress = progress
        errorMessage = nil
        statusMessage = "Removing local copies..."

        if evictionTask == nil {
            evictionTask = Task {
                await runEvictionQueue()
            }
        }
    }

    /// Evicts queued files one at a time so progress moves per file. Evicted
    /// files leave the list in batches to avoid rebuilding it for every file.
    private func runEvictionQueue() async {
        let folderURL = selectedFolderURL
        var evictedBatch: [CloudFile] = []
        var lastFlush = ContinuousClock.now
        var index = 0

        while index < evictionQueue.count {
            let file = evictionQueue[index]
            index += 1

            let failure = await Task.detached(priority: .userInitiated) {
                CloudFileEvictor.evict([file], accessFolderURL: folderURL)[file.id]
            }.value

            evictionProgress?.completedCount += 1
            if let failure {
                evictionProgress?.failedCount += 1
                if evictionProgress?.firstFailure == nil {
                    evictionProgress?.firstFailure = failure
                }
                evictingFileIDs.remove(file.id)
            } else {
                evictionProgress?.freedByteSize += file.localByteSize
                evictedBatch.append(file)
            }

            if ContinuousClock.now - lastFlush > .milliseconds(300) {
                removeEvictedFiles(evictedBatch)
                evictedBatch = []
                lastFlush = .now
            }
        }

        removeEvictedFiles(evictedBatch)
        evictionQueue = []
        evictionTask = nil
        saveCurrentSnapshot()
        finishEviction()
    }

    private func removeEvictedFiles(_ evictedFiles: [CloudFile]) {
        guard !evictedFiles.isEmpty else {
            return
        }

        let evictedIDs = Set(evictedFiles.map(\.id))
        recordEviction(of: evictedFiles)
        files.removeAll { evictedIDs.contains($0.id) }
        evictingFileIDs.subtract(evictedIDs)
        rebuildDerivedState()
    }

    private func finishEviction() {
        guard let progress = evictionProgress else {
            return
        }

        evictionProgress = nil
        errorMessage = progress.firstFailure
        let evictedCount = progress.completedCount - progress.failedCount
        let freedText = ByteCountFormatter.string(fromByteCount: progress.freedByteSize, countStyle: .file)

        if progress.failedCount == 0 {
            statusMessage = progress.totalCount == 1
                ? "Local copy removed • \(freedText) freed"
                : "Local copies removed: \(evictedCount) • \(freedText) freed"
        } else if evictedCount == 0 {
            statusMessage = progress.totalCount == 1 ? "Could not remove the local copy" : "Could not remove the local copies"
        } else {
            statusMessage = "Removed: \(evictedCount), failed: \(progress.failedCount) • \(freedText) freed"
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

    private func restoreLastFolder() {
        guard let folderURL = CloudFileCache.loadLastFolder() else {
            return
        }

        selectedFolderURL = folderURL
        loadCachedSnapshot(for: folderURL)

        if files.isEmpty {
            statusMessage = "Last folder restored. Press Scan Now."
        } else {
            statusMessage = "Showing the last result. Scan Now refreshes it."
        }
    }

    private func loadCachedSnapshot(for folderURL: URL) {
        snapshotLoadTask?.cancel()
        snapshotLoadTask = Task { [weak self] in
            guard let snapshot = await CloudFileCacheStore.shared.loadSnapshot(for: folderURL) else {
                return
            }

            guard
                let self,
                !Task.isCancelled,
                selectedFolderURL == folderURL,
                scannedFileCount == 0,
                files.isEmpty
            else {
                return
            }

            files = snapshot.files
            directoryTotals = snapshot.directoryTotals ?? [:]
            // A scan may already be running; its batches must not re-add these.
            progressFileIDs = Set(snapshot.files.map(\.id))
            rebuildDerivedState()
            statusMessage = "Showing cached results from \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    private func applyScanProgress(_ progress: CloudFileScanner.ScanProgress, generation: Int) {
        guard generation == scanGeneration, isScanning else {
            return
        }

        appendScannedFiles(progress.candidateBatch)
        scannedFileCount = progress.scannedFileCount
        statusMessage = "Scanning: \(progress.scannedFileCount) files checked, \(progress.candidateFileCount) found"
    }

    private func finishScan(_ result: CloudFileScanner.ScanResult, generation: Int) {
        guard generation == scanGeneration else {
            return
        }

        files = result.files
        directoryTotals = result.directoryTotals
        rebuildDerivedState()
        scannedFileCount = result.scannedFileCount
        statusMessage = result.files.isEmpty ? "No downloaded iCloud files found" : "Found: \(result.files.count)"
        if result.notSyncedFileCount > 0 {
            let notSyncedSize = ByteCountFormatter.string(fromByteCount: result.notSyncedByteSize, countStyle: .file)
            statusMessage += " • not synced with iCloud: \(result.notSyncedFileCount) (\(notSyncedSize))"
        }
        isScanning = false
        scanTask = nil
        saveCurrentSnapshot()
    }

    private func markScanStopped(generation: Int) {
        guard generation == scanGeneration else {
            return
        }

        statusMessage = "Scan stopped"
        isScanning = false
        scanTask = nil
    }

    private func failScan(_ error: Error, status: String, generation: Int) {
        guard generation == scanGeneration else {
            return
        }

        clearResults()
        errorMessage = error.localizedDescription
        statusMessage = status
        isScanning = false
        scanTask = nil
    }

    private func appendScannedFiles(_ newFiles: [CloudFile]) {
        let uniqueFiles = newFiles.filter { progressFileIDs.insert($0.id).inserted }
        guard !uniqueFiles.isEmpty else {
            return
        }

        files.append(contentsOf: uniqueFiles)
        rebuildDerivedState()
    }

    /// Recomputes `derived` after a short pause so bursts of changes (typing,
    /// scan batches) collapse into one pass. The inputs are captured only when
    /// the pause ends, so appending to `files` meanwhile does not copy it.
    private func rebuildDerivedState() {
        derivedStateTask?.cancel()
        derivedStateRevision += 1
        let revision = derivedStateRevision

        derivedStateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else {
                return
            }

            let filesSnapshot = files
            let totalsSnapshot = directoryTotals
            let folderPath = currentFolderPath
            let filter = folderFilter
            let sort = folderSort
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let state = await Task.detached(priority: .userInitiated) {
                Self.makeDerivedState(
                    files: filesSnapshot,
                    directoryTotals: totalsSnapshot,
                    currentFolderPath: folderPath,
                    filter: filter,
                    sort: sort,
                    searchQuery: query
                )
            }.value

            guard !Task.isCancelled, revision == derivedStateRevision else {
                return
            }

            derived = state
            derivedStateTask = nil
            // A rescan or eviction can remove the open folder; fall back to the root.
            if folderPath != nil, state.currentFolder == nil {
                currentFolderPath = nil
            }
        }
    }

    private func resetDerivedState() {
        derivedStateTask?.cancel()
        derivedStateTask = nil
        derivedStateRevision += 1
        derived = DerivedState()
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
        var totalFileByteSize: Int64 = 0
        var currentFolderFiles: [CloudFile] = []
        var filesByChildFolder: [String: [CloudFile]] = [:]
        var levelFiles: [CloudFile] = []

        for file in files {
            if file.downloadStatus.isStoredLocally {
                totalKnownByteSize += file.localByteSize
            }
            totalFileByteSize += file.byteSize ?? 0

            guard file.relativePath.hasPrefix(prefix) else {
                continue
            }

            if currentFolderPath != nil {
                currentFolderFiles.append(file)
            }
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

        return DerivedState(
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
            totalCloudByteSize: max(rootTotal?.byteSize ?? totalFileByteSize, totalKnownByteSize),
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
        let lastModified = [files.lazy.compactMap(\.modificationDate).max(), total?.lastModified].compactMap { $0 }.max()

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

    nonisolated private static let largeFolderThreshold: Int64 = 1_000_000_000

    nonisolated struct DerivedState: Sendable {
        var filteredFolderSummaries: [CloudFolderSummary] = []
        var currentFolder: CloudFolderSummary?
        /// Local files directly inside the current folder.
        var levelFiles: [CloudFile] = []
        var levelCloudOnlyFileCount = 0
        var levelCloudOnlyByteSize: Int64 = 0
        var totalKnownByteSize: Int64 = 0
        var totalCloudByteSize: Int64 = 0
        var totalCloudOnlyByteSize: Int64 = 0
    }
}

#if DEBUG
extension CloudFilesViewModel {
    /// Shows fixed results without touching the disk; used by the README
    /// screenshot renderer in `scripts/readme-images`.
    func showSample(
        folderURL: URL,
        files: [CloudFile],
        directoryTotals: [String: CloudFolderTotal],
        openFolderPath: String? = nil,
        evictingFileIDs: Set<CloudFile.ID> = [],
        evictionProgress: EvictionProgress? = nil,
        statusMessage: String
    ) {
        selectedFolderURL = folderURL
        self.files = files
        self.directoryTotals = directoryTotals
        currentFolderPath = openFolderPath
        self.evictingFileIDs = evictingFileIDs
        self.evictionProgress = evictionProgress
        self.statusMessage = statusMessage
        rebuildDerivedState()
    }
}
#endif
