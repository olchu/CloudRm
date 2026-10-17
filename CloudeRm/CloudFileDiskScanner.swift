//
//  CloudFileDiskScanner.swift
//  CloudeRm
//
//  Created by olchu on 27. 9. 2026..
//

import Darwin
import Foundation
import Synchronization

/// Finds locally stored iCloud files the way Mole's disk analyzer measures
/// folders: it reads file-system attributes in bulk (the APFS dataless flag and
/// allocated blocks) instead of asking the iCloud daemon about every file.
nonisolated enum CloudFileDiskScanner {
    enum ScanError: LocalizedError, Sendable {
        case folderIsNotInICloud
        case unableToReadFolder(String)

        var errorDescription: String? {
            switch self {
            case .folderIsNotInICloud:
                "Выбранная папка не находится в iCloud Drive."
            case .unableToReadFolder(let reason):
                "Не удалось прочитать папку: \(reason)"
            }
        }
    }

    static func scan(
        folderURL: URL,
        onProgress: (@Sendable (CloudFileScanner.ScanProgress) -> Void)? = nil
    ) async throws -> CloudFileScanner.ScanResult {
        let state = ScanState(onProgress: onProgress)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try FileAccess.withSecurityScopedAccess(to: folderURL) {
                            try scanSynchronously(folderURL: folderURL, state: state)
                        }
                    })
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    private static func scanSynchronously(folderURL: URL, state: ScanState) throws -> CloudFileScanner.ScanResult {
        let rootPath = folderURL.standardizedFileURL.path(percentEncoded: false)
        let roots = try withoutMaterializingDatalessFiles {
            try iCloudRoots(in: rootPath, folderURL: folderURL)
        }
        state.enqueue(roots)

        let workerCount = max(4, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            withoutMaterializingDatalessFiles {
                let reader = DirectoryReader()

                while let directory = state.nextDirectory() {
                    let output = scanDirectory(directory, reader: reader, state: state)
                    state.finish(output)
                }
            }
        }

        if state.isCancelled {
            throw CancellationError()
        }

        return state.result()
    }

    /// By default the kernel blocks a read until iCloud downloads a dataless
    /// item, which can take minutes. With materialization off such reads fail
    /// right away with EDEADLK. The policy is per thread, so it is restored
    /// before the dispatch thread goes back to the pool.
    private static func withoutMaterializingDatalessFiles<Result>(_ operation: () throws -> Result) rethrows -> Result {
        let previousPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previousPolicy >= 0 {
                setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previousPolicy)
            }
        }

        return try operation()
    }

    /// Directories whose contents are iCloud items. A folder inside
    /// `Mobile Documents` (or any ubiquitous folder) is scanned as a whole;
    /// otherwise only its ubiquitous subfolders are, e.g. synced Desktop/Documents.
    private static func iCloudRoots(in rootPath: String, folderURL: URL) throws -> [PendingDirectory] {
        let root = PendingDirectory(path: rootPath, relativePath: "")

        if rootPath.contains("/Library/Mobile Documents") || isUbiquitous(folderURL) {
            return [root]
        }

        var roots: [PendingDirectory] = []
        do {
            try DirectoryReader().readEntries(atPath: rootPath) { entry in
                guard entry.isDirectory, !entry.isHidden, !entry.isDataless else {
                    return
                }

                let childPath = rootPath + "/" + entry.name
                if isUbiquitous(URL(fileURLWithPath: childPath, isDirectory: true)) {
                    roots.append(PendingDirectory(path: childPath, relativePath: entry.name))
                }
            }
        } catch {
            throw ScanError.unableToReadFolder(error.localizedDescription)
        }

        guard !roots.isEmpty else {
            throw ScanError.folderIsNotInICloud
        }

        return roots
    }

    private static func scanDirectory(
        _ directory: PendingDirectory,
        reader: DirectoryReader,
        state: ScanState
    ) -> DirectoryOutput {
        var output = DirectoryOutput()

        do {
            try reader.readEntries(atPath: directory.path) { entry in
                guard !entry.isHidden, !state.isCancelled else {
                    return
                }

                let path = directory.path + "/" + entry.name
                let relativePath = directory.relativePath.isEmpty ? entry.name : directory.relativePath + "/" + entry.name

                if entry.isDirectory {
                    // A dataless directory has nothing on disk; reading it would
                    // make iCloud download its listing, so its size stays unknown.
                    guard !entry.isDataless else {
                        output.directoryTotals.addSubfolder(relativePath: relativePath, isListed: false)
                        return
                    }

                    if isPackage(path: path, name: entry.name) {
                        output.scannedFileCount += 1
                        let usage = packageUsage(atPath: path, reader: reader)
                        output.record(
                            packageFile(entry: entry, path: path, relativePath: relativePath, usage: usage),
                            isLocal: usage.hasLocalContent
                        )
                    } else {
                        output.directoryTotals.addSubfolder(relativePath: relativePath)
                        output.subdirectories.append(PendingDirectory(path: path, relativePath: relativePath))
                    }
                } else if entry.isRegularFile {
                    output.scannedFileCount += 1
                    guard !entry.isDataless else {
                        output.directoryTotals.addFile(
                            relativePath: relativePath,
                            byteSize: entry.logicalSize,
                            isLocal: false,
                            modificationDate: entry.modificationDate
                        )
                        return
                    }

                    output.record(
                        CloudFile(
                            url: URL(fileURLWithPath: path, isDirectory: false),
                            displayName: entry.name,
                            relativePath: relativePath,
                            byteSize: entry.logicalSize,
                            allocatedByteSize: entry.allocatedSize,
                            modificationDate: entry.modificationDate,
                            downloadStatus: .downloaded
                        ),
                        isLocal: true
                    )
                }
            }
        } catch {
            output.skippedFileCount += 1
        }

        return output
    }

    /// Documents such as `.pages` or `.key` are directories on disk but a single
    /// item in iCloud, so their contents are summed into one file.
    private static func packageFile(
        entry: DirectoryEntry,
        path: String,
        relativePath: String,
        usage: PackageUsage
    ) -> CloudFile {
        CloudFile(
            url: URL(fileURLWithPath: path, isDirectory: true),
            displayName: entry.name,
            relativePath: relativePath,
            byteSize: usage.logicalSize,
            allocatedByteSize: usage.allocatedSize,
            modificationDate: entry.modificationDate,
            downloadStatus: .downloaded
        )
    }

    private static func packageUsage(atPath path: String, reader: DirectoryReader) -> PackageUsage {
        var usage = PackageUsage()
        addPackageUsage(atPath: path, reader: reader, into: &usage)
        return usage
    }

    private static func addPackageUsage(atPath path: String, reader: DirectoryReader, into usage: inout PackageUsage) {
        var subdirectories: [String] = []

        try? reader.readEntries(atPath: path) { entry in
            if entry.isDirectory {
                if !entry.isDataless {
                    subdirectories.append(path + "/" + entry.name)
                }
            } else if entry.isRegularFile {
                usage.logicalSize += entry.logicalSize
                if !entry.isDataless {
                    usage.allocatedSize += entry.allocatedSize
                    usage.hasLocalContent = true
                }
            }
        }

        for subdirectory in subdirectories {
            addPackageUsage(atPath: subdirectory, reader: reader, into: &usage)
        }
    }

    private static func isPackage(path: String, name: String) -> Bool {
        guard name.contains(".") else {
            return false
        }

        let values = try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage == true
    }

    fileprivate static func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }
}

// MARK: - Shared scan state

nonisolated private struct PendingDirectory: Sendable {
    let path: String
    let relativePath: String
}

nonisolated private struct DirectoryOutput {
    var subdirectories: [PendingDirectory] = []
    var files: [CloudFile] = []
    var directoryTotals: [String: CloudFolderTotal] = [:]
    var scannedFileCount = 0
    var skippedFileCount = 0
    var notSyncedFileCount = 0
    var notSyncedByteSize: Int64 = 0

    /// Counts the item in the folder totals and keeps it when it is local.
    /// iCloud leaves some local items unsynced (Thumbs.db, .tmp, photo
    /// libraries); they cannot be evicted, so they are only counted apart.
    mutating func record(_ file: CloudFile, isLocal: Bool) {
        if isLocal, !CloudFileDiskScanner.isUbiquitous(file.url) {
            notSyncedFileCount += 1
            notSyncedByteSize += file.localByteSize
            return
        }

        directoryTotals.addFile(
            relativePath: file.relativePath,
            byteSize: file.byteSize ?? 0,
            isLocal: isLocal,
            modificationDate: file.modificationDate
        )
        if isLocal {
            files.append(file)
        }
    }
}

nonisolated private struct PackageUsage {
    var logicalSize: Int64 = 0
    var allocatedSize: Int64 = 0
    var hasLocalContent = false
}

/// Work queue shared by the scan workers. Workers take directories until the
/// queue is empty and no other worker can add more.
nonisolated private final class ScanState: @unchecked Sendable {
    private let condition = NSCondition()
    private let onProgress: (@Sendable (CloudFileScanner.ScanProgress) -> Void)?
    private var pendingDirectories: [PendingDirectory] = []
    private let cancelled = Atomic<Bool>(false)
    private var activeWorkerCount = 0
    private var files: [CloudFile] = []
    private var directoryTotals: [String: CloudFolderTotal] = [:]
    private var candidateBatch: [CloudFile] = []
    private var scannedFileCount = 0
    private var skippedFileCount = 0
    private var notSyncedFileCount = 0
    private var notSyncedByteSize: Int64 = 0
    private var lastReportedScannedFileCount = 0

    init(onProgress: (@Sendable (CloudFileScanner.ScanProgress) -> Void)?) {
        self.onProgress = onProgress
    }

    var isCancelled: Bool {
        cancelled.load(ordering: .relaxed)
    }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    func enqueue(_ directories: [PendingDirectory]) {
        condition.lock()
        pendingDirectories.append(contentsOf: directories)
        condition.broadcast()
        condition.unlock()
    }

    func nextDirectory() -> PendingDirectory? {
        condition.lock()
        defer { condition.unlock() }

        while pendingDirectories.isEmpty && activeWorkerCount > 0 && !isCancelled {
            condition.wait()
        }

        guard !isCancelled, let directory = pendingDirectories.popLast() else {
            condition.broadcast()
            return nil
        }

        activeWorkerCount += 1
        return directory
    }

    func finish(_ output: DirectoryOutput) {
        condition.lock()
        defer { condition.unlock() }

        activeWorkerCount -= 1
        pendingDirectories.append(contentsOf: output.subdirectories)
        files.append(contentsOf: output.files)
        directoryTotals.merge(output.directoryTotals)
        candidateBatch.append(contentsOf: output.files)
        scannedFileCount += output.scannedFileCount
        skippedFileCount += output.skippedFileCount
        notSyncedFileCount += output.notSyncedFileCount
        notSyncedByteSize += output.notSyncedByteSize
        condition.broadcast()

        if candidateBatch.count >= 100 || scannedFileCount - lastReportedScannedFileCount >= 500 {
            reportProgress()
        }
    }

    func result() -> CloudFileScanner.ScanResult {
        condition.lock()
        defer { condition.unlock() }

        reportProgress()
        return CloudFileScanner.ScanResult(
            files: files.sorted(by: CloudFileScanner.sortByLargestSizeFirst),
            directoryTotals: directoryTotals,
            skippedFileCount: skippedFileCount,
            scannedFileCount: scannedFileCount,
            notSyncedFileCount: notSyncedFileCount,
            notSyncedByteSize: notSyncedByteSize
        )
    }

    private func reportProgress() {
        onProgress?(
            CloudFileScanner.ScanProgress(
                scannedFileCount: scannedFileCount,
                candidateFileCount: files.count,
                skippedFileCount: skippedFileCount,
                candidateBatch: candidateBatch
            )
        )
        candidateBatch = []
        lastReportedScannedFileCount = scannedFileCount
    }
}

// MARK: - getattrlistbulk

nonisolated private struct DirectoryEntry {
    let name: String
    let objectType: fsobj_type_t
    let flags: UInt32
    let modificationDate: Date
    let logicalSize: Int64
    let allocatedSize: Int64

    var isDirectory: Bool { objectType == VDIR.rawValue }
    var isRegularFile: Bool { objectType == VREG.rawValue }
    var isHidden: Bool { name.hasPrefix(".") || flags & UInt32(truncatingIfNeeded: UF_HIDDEN) != 0 }
    /// Set by APFS when the content lives only in iCloud (the file was evicted).
    var isDataless: Bool { flags & UInt32(truncatingIfNeeded: SF_DATALESS) != 0 }
}

/// Reads a directory's entries and their attributes in a few system calls,
/// reusing one buffer per worker thread.
nonisolated private final class DirectoryReader {
    private static let bufferSize = 256 * 1024
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)

    deinit {
        buffer.deallocate()
    }

    func readEntries(atPath path: String, _ body: (DirectoryEntry) -> Void) throws {
        let entries: [DirectoryEntry]
        do {
            entries = try bulkEntries(atPath: path)
        } catch let error as POSIXError where error.code == .EDEADLK {
            // Bulk attributes needed iCloud to materialize something. Plain
            // readdir + lstat only reads what is already on disk.
            entries = try statEntries(atPath: path)
        }

        entries.forEach(body)
    }

    private func bulkEntries(atPath path: String) throws -> [DirectoryEntry] {
        let directory = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else {
            throw POSIXError.current
        }
        defer { close(directory) }

        // Attributes come back in this order; FSOPT_PACK_INVAL_ATTRS keeps the
        // layout fixed by zero-filling file sizes for directories.
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_FLAGS)
        attributes.fileattr = attrgroup_t(truncatingIfNeeded: ATTR_FILE_TOTALSIZE)
            | attrgroup_t(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)
        let options = UInt64(truncatingIfNeeded: FSOPT_PACK_INVAL_ATTRS)

        var entries: [DirectoryEntry] = []
        while true {
            let entryCount = getattrlistbulk(directory, &attributes, buffer, Self.bufferSize, options)
            guard entryCount >= 0 else {
                throw POSIXError.current
            }

            guard entryCount > 0 else {
                return entries
            }

            var entryStart = UnsafeRawPointer(buffer)
            for _ in 0..<entryCount {
                let entryLength = entryStart.loadUnaligned(as: UInt32.self)
                var field = entryStart + MemoryLayout<UInt32>.size
                field += MemoryLayout<attribute_set_t>.size

                let nameReference = field.loadUnaligned(as: attrreference_t.self)
                let name = String(cString: (field + Int(nameReference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                field += MemoryLayout<attrreference_t>.size

                let objectType = field.loadUnaligned(as: fsobj_type_t.self)
                field += MemoryLayout<fsobj_type_t>.size

                let modificationTime = field.loadUnaligned(as: timespec.self)
                field += MemoryLayout<timespec>.size

                let flags = field.loadUnaligned(as: UInt32.self)
                field += MemoryLayout<UInt32>.size

                let logicalSize = field.loadUnaligned(as: off_t.self)
                field += MemoryLayout<off_t>.size

                let allocatedSize = field.loadUnaligned(as: off_t.self)

                entries.append(
                    DirectoryEntry(
                        name: name,
                        objectType: objectType,
                        flags: flags,
                        modificationDate: Date(
                            timeIntervalSince1970: TimeInterval(modificationTime.tv_sec)
                                + TimeInterval(modificationTime.tv_nsec) / 1_000_000_000
                        ),
                        logicalSize: Int64(logicalSize),
                        allocatedSize: Int64(allocatedSize)
                    )
                )

                entryStart += Int(entryLength)
            }
        }
    }

    private func statEntries(atPath path: String) throws -> [DirectoryEntry] {
        guard let directory = opendir(path) else {
            throw POSIXError.current
        }
        defer { closedir(directory) }

        let directoryDescriptor = dirfd(directory)
        var entries: [DirectoryEntry] = []

        while let rawEntry = readdir(directory) {
            let name = withUnsafeBytes(of: rawEntry.pointee.d_name) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            guard name != ".", name != ".." else {
                continue
            }

            var fileStatus = stat()
            guard fstatat(directoryDescriptor, name, &fileStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
                continue
            }

            let objectType: fsobj_type_t
            switch fileStatus.st_mode & S_IFMT {
            case S_IFDIR:
                objectType = VDIR.rawValue
            case S_IFREG:
                objectType = VREG.rawValue
            default:
                objectType = VNON.rawValue
            }

            entries.append(
                DirectoryEntry(
                    name: name,
                    objectType: objectType,
                    flags: fileStatus.st_flags,
                    modificationDate: Date(
                        timeIntervalSince1970: TimeInterval(fileStatus.st_mtimespec.tv_sec)
                            + TimeInterval(fileStatus.st_mtimespec.tv_nsec) / 1_000_000_000
                    ),
                    logicalSize: Int64(fileStatus.st_size),
                    allocatedSize: Int64(fileStatus.st_blocks) * 512
                )
            )
        }

        return entries
    }
}

nonisolated private extension POSIXError {
    static var current: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
