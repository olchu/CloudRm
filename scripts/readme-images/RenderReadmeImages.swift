//
//  RenderReadmeImages.swift
//  CloudeRm
//
//  Renders the README hero banner and app screenshots. The screenshots use
//  the real ContentView filled with made-up sample data, so no personal files
//  ever end up in the repository. Run it through scripts/readme-images/render.sh.
//

import AppKit
import SwiftUI

@main
struct RenderReadmeImages {
    static let windowSize = CGSize(width: 1240, height: 780)

    static func main() {
        let arguments = CommandLine.arguments
        // Extra arguments (e.g. -AppleLocale en_US) go to UserDefaults.
        guard arguments.count >= 3 else {
            print("usage: render <icon.png> <output directory>")
            exit(64)
        }

        let outputURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
        guard let icon = NSImage(contentsOfFile: arguments[1]) else {
            print("cannot read icon at \(arguments[1])")
            exit(66)
        }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        do {
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

            let library = SampleLibrary()

            let overview = CloudFilesViewModel()
            overview.showSample(
                folderURL: library.rootURL,
                files: library.files,
                directoryTotals: library.totals,
                statusMessage: "Found: \(library.files.count)"
            )
            try save(WindowFrame(screenshot: snapshot(of: overview)), to: outputURL.appending(path: "screenshot-overview.png"))

            let openFolder = "Video Edits"
            let evicting = library.files.filter {
                $0.relativePath.hasPrefix("Video Edits/Travel 2025/") || $0.displayName == "final-cut-export.mov"
            }
            let queuedBytes = evicting.reduce(Int64(0)) { $0 + $1.localByteSize }
            let folder = CloudFilesViewModel()
            folder.showSample(
                folderURL: library.rootURL,
                files: library.files,
                directoryTotals: library.totals,
                openFolderPath: openFolder,
                evictingFileIDs: Set(evicting.map(\.id)),
                evictionProgress: EvictionProgress(
                    totalCount: evicting.count + 9,
                    completedCount: 9,
                    totalByteSize: queuedBytes + 7_400_000_000,
                    freedByteSize: 7_400_000_000
                ),
                statusMessage: "Removing local copies..."
            )
            try save(WindowFrame(screenshot: snapshot(of: folder)), to: outputURL.appending(path: "screenshot-folder.png"))

            // The banner's soft gradients compress poorly, so it gets a lower scale.
            try save(HeroBanner(icon: icon), to: outputURL.appending(path: "hero.png"), scale: 1.5)
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    /// Draws ContentView offscreen at 2x after its derived state has settled.
    static func snapshot(of viewModel: CloudFilesViewModel) -> NSImage {
        // Draw as the active window so controls keep their accent tint.
        let hostingView = NSHostingView(
            rootView: ContentView(viewModel: viewModel)
                .environment(\.controlActiveState, .key)
        )
        hostingView.frame = CGRect(origin: .zero, size: windowSize)

        let window = KeyWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView

        // The view model rebuilds its derived state asynchronously.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        hostingView.layoutSubtreeIfNeeded()

        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(windowSize.width * 2),
            pixelsHigh: Int(windowSize.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        representation.size = windowSize
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)

        let image = NSImage(size: windowSize)
        image.addRepresentation(representation)
        return image
    }

    static func save(_ view: some View, to url: URL, scale: CGFloat = 2) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard
            let cgImage = renderer.cgImage,
            let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        try data.write(to: url)
        print("wrote \(url.path(percentEncoded: false))")
    }
}

private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// A screenshot with window corners, a hairline border and a soft shadow.
private struct WindowFrame: View {
    let screenshot: NSImage

    var body: some View {
        Image(nsImage: screenshot)
            .resizable()
            .frame(width: screenshot.size.width, height: screenshot.size.height)
            .clipShape(.rect(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 28, y: 14)
            .padding(48)
    }
}

private struct HeroBanner: View {
    let icon: NSImage

    var body: some View {
        HStack(spacing: 44) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 236, height: 236)

            VStack(alignment: .leading, spacing: 16) {
                Text("CloudeRm")
                    .font(.system(size: 68, weight: .bold, design: .rounded))

                Text("Free up Mac storage taken by iCloud Drive\nwithout deleting anything from iCloud.")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineSpacing(4)

                HStack(spacing: 10) {
                    badge("macOS 26.5+")
                    badge("SwiftUI")
                    badge("Sandboxed")
                }
                .padding(.top, 8)
            }
            .foregroundStyle(.white)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 72)
        .frame(width: 1280, height: 420)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.07, blue: 0.16),
                    Color(red: 0.03, green: 0.20, blue: 0.42)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color(red: 0.20, green: 0.60, blue: 1.0).opacity(0.28))
                .frame(width: 520, height: 520)
                .blur(radius: 90)
                .offset(x: 140, y: -180)
        }
        .clipShape(.rect(cornerRadius: 28))
    }

    private func badge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.white.opacity(0.10), in: .capsule)
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
    }
}

/// A made-up iCloud Drive with a mix of downloaded, partial and cloud-only folders.
private struct SampleLibrary {
    let rootURL = URL(fileURLWithPath: "/Users/demo/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    private(set) var files: [CloudFile] = []
    private(set) var totals: [String: CloudFolderTotal] = [:]
    private var knownFolders: Set<String> = []
    private var random = SeededRandom(seed: 7)
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    init() {
        let gb: Double = 1_000_000_000
        let mb: Double = 1_000_000

        add("Video Edits/final-cut-export.mov", bytes: 3.4 * gb, isLocal: true, daysAgo: 2)
        add("Video Edits/trailer-v3.mp4", bytes: 0.85 * gb, isLocal: true, daysAgo: 3)
        add("Video Edits/grade-teal-orange.cube", bytes: 4 * mb, isLocal: true, daysAgo: 30)
        add("Video Edits/b-roll-raw.mov", bytes: 2.6 * gb, isLocal: false, daysAgo: 90)
        add("Video Edits/Travel 2025/drone-01.mov", bytes: 6.2 * gb, isLocal: true, daysAgo: 12)
        add("Video Edits/Travel 2025/drone-02.mov", bytes: 4.8 * gb, isLocal: true, daysAgo: 12)
        add("Video Edits/Travel 2025/timelapse-sunset.mov", bytes: 2.1 * gb, isLocal: false, daysAgo: 14)
        addMany("Video Edits/Travel 2025", count: 38, averageBytes: 180 * mb, localShare: 0.5) { "clip-\(String(format: "%03d", $0)).mov" }
        add("Video Edits/Wedding/ceremony-cam-a.mov", bytes: 9.4 * gb, isLocal: false, daysAgo: 200)
        add("Video Edits/Wedding/ceremony-cam-b.mov", bytes: 8.7 * gb, isLocal: false, daysAgo: 200)
        add("Video Edits/Wedding/speech.mov", bytes: 1.9 * gb, isLocal: true, daysAgo: 190)
        addMany("Video Edits/Wedding", count: 60, averageBytes: 120 * mb, localShare: 0.3) { "guest-\(String(format: "%03d", $0)).mov" }

        for year in 2019...2024 {
            addMany("Photos Archive/\(year)", count: 900, averageBytes: 11 * mb, localShare: 0) { "IMG_\(4000 + $0).HEIC" }
        }

        addMany("Music Production/Stems", count: 300, averageBytes: 45 * mb, localShare: 0.6) { "stem-\($0).wav" }
        addMany("Music Production/Sessions", count: 80, averageBytes: 120 * mb, localShare: 0.4) { "session-\($0).logicx" }

        addMany("Projects/cloude-rm", count: 2400, averageBytes: 20_000, localShare: 1) { "source-\($0).swift" }
        addMany("Projects/website", count: 900, averageBytes: 60_000, localShare: 1) { "page-\($0).html" }
        addMany("Projects/design-system", count: 600, averageBytes: 1.5 * mb, localShare: 1) { "token-\($0).json" }

        addMany("Documents/Taxes", count: 40, averageBytes: 2 * mb, localShare: 1) { "statement-\($0).pdf" }
        addMany("Documents/Contracts", count: 25, averageBytes: 1 * mb, localShare: 1) { "contract-\($0).pdf" }
        addMany("Documents", count: 60, averageBytes: 3 * mb, localShare: 1) { "note-\($0).pages" }

        addMany("Books", count: 140, averageBytes: 18 * mb, localShare: 0) { "book-\($0).epub" }

        addMany("Design Assets/Mockups", count: 120, averageBytes: 60 * mb, localShare: 0.7) { "mockup-\($0).psd" }
        addMany("Design Assets/Fonts", count: 300, averageBytes: 0.3 * mb, localShare: 1) { "font-\($0).otf" }

        addMany("Backups", count: 6, averageBytes: 7 * gb, localShare: 0) { "macbook-backup-\($0).sparsebundle" }

        addMany("Desktop", count: 80, averageBytes: 4 * mb, localShare: 0.5) { "screenshot-\($0).png" }

        files.sort(by: CloudFileScanner.sortByLargestSizeFirst)
    }

    private mutating func add(_ relativePath: String, bytes: Double, isLocal: Bool, daysAgo: Double) {
        for folder in CloudFolderTotal.ancestorPaths(of: relativePath) where !folder.isEmpty && !knownFolders.contains(folder) {
            knownFolders.insert(folder)
            totals.addSubfolder(relativePath: folder)
        }

        let byteSize = Int64(bytes)
        let modificationDate = now.addingTimeInterval(-daysAgo * 86_400)
        totals.addFile(relativePath: relativePath, byteSize: byteSize, isLocal: isLocal, modificationDate: modificationDate)

        if isLocal {
            files.append(
                CloudFile(
                    url: rootURL.appending(path: relativePath),
                    displayName: (relativePath as NSString).lastPathComponent,
                    relativePath: relativePath,
                    byteSize: byteSize,
                    allocatedByteSize: byteSize,
                    modificationDate: modificationDate,
                    downloadStatus: .downloaded
                )
            )
        }
    }

    private mutating func addMany(
        _ folder: String,
        count: Int,
        averageBytes: Double,
        localShare: Double,
        name: (Int) -> String
    ) {
        for index in 1...count {
            let bytes = averageBytes * (0.3 + 1.4 * random.next())
            let isLocal = random.next() < localShare
            add("\(folder)/\(name(index))", bytes: bytes, isLocal: isLocal, daysAgo: 400 * random.next())
        }
    }
}

/// Deterministic numbers so the images do not change between runs.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// A value in 0..<1.
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}
