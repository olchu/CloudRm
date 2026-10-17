//
//  ContentView.swift
//  CloudeRm
//
//  Created by olchu on 28. 5. 2026..
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = CloudFilesViewModel()
    @State private var isConfirmingFolderEviction = false

    var body: some View {
        ZStack {
            StudioBackground()

            HStack(spacing: 0) {
                mainPanel

                if let folder = viewModel.currentFolder {
                    Divider()
                        .overlay(AppPalette.stroke)

                    detailsPanel(folder)
                }
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.font, .system(size: 13, design: .monospaced))
        .frame(minWidth: 900, minHeight: 680)
        .alert("Выгрузить локальные копии?", isPresented: $isConfirmingFolderEviction) {
            Button("Отмена", role: .cancel) {}
            Button("Выгрузить", role: .destructive) {
                viewModel.evictCurrentFolderLocalCopies()
            }
        } message: {
            if let folder = viewModel.currentFolder {
                Text("Файлы останутся в iCloud, но локальная копия папки \(folder.name) будет удалена с этого Mac.")
            }
        }
    }

    private var mainPanel: some View {
        VStack(spacing: 18) {
            topBar
            filtersBar

            if viewModel.currentFolderPath != nil {
                breadcrumbBar
            }

            if let progress = viewModel.evictionProgress {
                EvictionBanner(progress: progress)
            }

            if viewModel.isScanning && viewModel.files.isEmpty {
                scanningState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isCurrentLevelEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                folderList
            }

            summaryStrip
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.contentBackground)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            OlchuStudioMark()
                .frame(width: 118, alignment: .leading)

            Rectangle()
                .fill(AppPalette.stroke)
                .frame(width: 1, height: 28)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppPalette.secondaryText)

                TextField("Search folders...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))

                Text("⌘F")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppPalette.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .cardChrome(AppPalette.controlBackground)

            Spacer()

            if viewModel.isScanning {
                Button {
                    viewModel.cancelScan()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Button(action: viewModel.scanOrAnalyze) {
                Label(viewModel.primaryScanTitle, systemImage: "arrow.triangle.2.circlepath.icloud")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.isEvicting)

            Menu {
                Group {
                    Button {
                        viewModel.analyzeDefaultICloudDriveFolder()
                    } label: {
                        Label("Analyze iCloud Drive", systemImage: "icloud")
                    }

                    Button {
                        viewModel.chooseFolder()
                    } label: {
                        Label("Choose Folder", systemImage: "folder")
                    }

                    Button {
                        viewModel.scanSelectedFolderWithFileManagerFallback()
                    } label: {
                        Label("Full Scan", systemImage: "folder.badge.gearshape")
                    }
                    .disabled(!viewModel.hasSelectedFolder || viewModel.isScanning)
                }
                .disabled(viewModel.isEvicting)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(IconButtonStyle())
        }
    }

    private var filtersBar: some View {
        HStack(spacing: 10) {
            ForEach(CloudFolderFilter.allCases) { filter in
                filterChip(filter)
            }

            Spacer()

            Picker("Sort by", selection: $viewModel.folderSort) {
                ForEach(CloudFolderSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 150)
        }
    }

    private func filterChip(_ filter: CloudFolderFilter) -> some View {
        Button {
            viewModel.folderFilter = filter
        } label: {
            HStack(spacing: 6) {
                if filter == .all {
                    Image(systemName: "globe")
                        .font(.caption)
                }

                Text(filter.title)
                    .font(.callout.weight(viewModel.folderFilter == filter ? .semibold : .regular))
            }
            .padding(.horizontal, 13)
            .frame(height: 36)
            .cardChrome(
                viewModel.folderFilter == filter ? AppPalette.accent : AppPalette.controlBackground,
                stroke: viewModel.folderFilter == filter ? AppPalette.accent : AppPalette.stroke
            )
        }
        .buttonStyle(.plain)
    }

    private var folderList: some View {
        VStack(spacing: 10) {
            if viewModel.isScanning {
                scanningBanner
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.derived.filteredFolderSummaries) { folder in
                        FolderListRow(folder: folder) {
                            viewModel.openFolder(folder.id)
                        }
                    }

                    ForEach(viewModel.derived.levelFiles) { file in
                        FolderFileRow(file: file, isEvicting: viewModel.evictingFileIDs.contains(file.id)) {
                            viewModel.evictFile(file)
                        }
                    }

                    if viewModel.derived.levelCloudOnlyFileCount > 0 {
                        Label(
                            "Ещё \(viewModel.derived.levelCloudOnlyFileCount) в iCloud • \(byteCountText(viewModel.derived.levelCloudOnlyByteSize))",
                            systemImage: "icloud"
                        )
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.automatic)
            .id(viewModel.currentFolderPath)
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 8) {
            Button(action: viewModel.openParentFolder) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut("[", modifiers: .command)
            .help("Назад")

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    breadcrumbButton("iCloud Drive", isCurrent: false, action: viewModel.openRootFolder)

                    ForEach(Array(viewModel.currentFolderTrail.enumerated()), id: \.offset) { index, item in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppPalette.secondaryText)

                        breadcrumbButton(item.title, isCurrent: index == viewModel.currentFolderTrail.count - 1) {
                            viewModel.openFolder(item.path)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func breadcrumbButton(_ title: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(isCurrent ? AppPalette.primaryText : AppPalette.secondaryText)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    private var scanningBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text(viewModel.statusMessage)
                .font(.callout)
                .foregroundStyle(AppPalette.secondaryText)
                .lineLimit(1)

            Spacer()

            Text("\(viewModel.scannedFileCount)")
                .font(.callout)
                .foregroundStyle(AppPalette.secondaryText)
                .monospacedDigit()
        }
        .padding(12)
        .background(AppPalette.panelBackground)
        .clipShape(.rect(cornerRadius: 8))
    }

    private var scanningState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)

            Text(viewModel.statusMessage)
                .font(.title3.weight(.semibold))

            Text("Проверено файлов: \(viewModel.scannedFileCount)")
                .font(.callout)
                .foregroundStyle(AppPalette.secondaryText)
                .monospacedDigit()

            Button {
                viewModel.cancelScan()
            } label: {
                Label("Остановить сканирование", systemImage: "stop.circle")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.hasSelectedFolder ? "folder" : "icloud")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(AppPalette.cloudBlue)

            Text(viewModel.hasSelectedFolder ? "No folders match this view" : "Choose an iCloud Drive folder")
                .font(.title3.weight(.semibold))

            Text(viewModel.hasSelectedFolder ? viewModel.statusMessage : "Scan Now reads iCloud Drive straight from disk.")
                .font(.body)
                .foregroundStyle(AppPalette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button(action: viewModel.scanOrAnalyze) {
                Label(viewModel.primaryScanTitle, systemImage: "icloud")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 4)
        }
    }

    private var summaryStrip: some View {
        HStack(spacing: 0) {
            summaryMetric(icon: "cloud", title: "Total in Cloud", value: byteCountText(viewModel.derived.totalCloudByteSize), tint: AppPalette.cloudBlue)
            summaryDivider
            summaryMetric(icon: "externaldrive", title: "On Mac · Can Free Up", value: byteCountText(viewModel.derived.totalKnownByteSize), tint: AppPalette.warning)
            summaryDivider
            summaryMetric(icon: "icloud.and.arrow.down", title: "Only in Cloud", value: byteCountText(viewModel.derived.totalCloudOnlyByteSize), tint: AppPalette.secondaryText)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .cardChrome(AppPalette.panelBackground)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(AppPalette.stroke)
            .frame(width: 1, height: 36)
            .padding(.horizontal, 18)
    }

    private func summaryMetric(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(AppPalette.secondaryText)
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }

            Spacer()
        }
    }

    private func detailsPanel(_ folder: CloudFolderSummary) -> some View {
        FolderDetailsPanel(
            folder: folder,
            statusMessage: viewModel.statusMessage,
            errorMessage: viewModel.errorMessage,
            canFreeUpSpace: viewModel.canEvictCurrentFolder,
            isFreeingUp: viewModel.isEvictingCurrentFolder,
            onFreeUp: { isConfirmingFolderEviction = true },
            onReveal: revealSelectedFolder
        )
        .padding(20)
        .frame(width: 300)
        .background(AppPalette.detailsBackground)
    }

    private func revealSelectedFolder() {
        guard let folder = viewModel.currentFolder, let rootURL = viewModel.selectedFolderURL else {
            return
        }

        let url = rootURL.appending(path: folder.relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct FolderListRow: View {
    let folder: CloudFolderSummary
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(AppPalette.folderHighlight)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text(folder.name)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppPalette.primaryText)
                        .lineLimit(1)

                    Text(folder.relativePath)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(AppPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)

                listMetric(folder.fileCount.formatted(), label: "FILES")
                    .frame(width: 62, alignment: .trailing)

                listMetric(byteCountText(folder.localByteSize), label: "ON MAC")
                    .frame(width: 90, alignment: .trailing)

                status
                    .frame(width: 104, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppPalette.secondaryText)
                    .frame(width: 18)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 68)
            .contentShape(.rect)
            .cardChrome(AppPalette.cardBackground)
        }
        .buttonStyle(.plain)
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(folder.downloadState.tint)
                .frame(width: 6, height: 6)

            Text(statusText)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(folder.downloadState.tint)
                .lineLimit(1)
        }
    }

    private func listMetric(_ value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppPalette.primaryText)
                .monospacedDigit()
                .lineLimit(1)

            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(AppPalette.secondaryText)
                .tracking(0.4)
        }
    }

    private var statusText: String {
        switch folder.downloadState {
        case .downloaded:
            "LOCAL"
        case .cloudOnly:
            "CLOUD"
        case .partial:
            "PARTIAL"
        }
    }
}

private struct FolderFileRow: View {
    let file: CloudFile
    let isEvicting: Bool
    let onEvict: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.downloadStatus.isStoredLocally ? "doc.fill" : "doc")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(file.downloadStatus.isStoredLocally ? AppPalette.success : AppPalette.secondaryText)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(file.relativePath)
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(byteCountText(file.localByteSize))
                .font(.caption)
                .foregroundStyle(AppPalette.secondaryText)
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
                .help(fileSizeHelpText)

            Text(isEvicting ? "Выгружается" : file.downloadStatus.displayName)
                .font(.caption)
                .foregroundStyle(isEvicting ? AppPalette.accent : statusTint)
                .frame(width: 92, alignment: .trailing)

            if isEvicting {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 28)
            } else {
                Button(action: onEvict) {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(IconButtonStyle())
                .disabled(!file.downloadStatus.isStoredLocally)
                .help(file.downloadStatus.isStoredLocally ? "Выгрузить локальную копию" : "Файл уже только в iCloud")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .background(AppPalette.controlBackground)
        .clipShape(.rect(cornerRadius: 8))
    }

    private var statusTint: Color {
        file.downloadStatus.isStoredLocally ? AppPalette.success : AppPalette.cloudBlue
    }

    private var fileSizeHelpText: String {
        let local = byteCountText(file.localByteSize)
        let cloud = byteCountText(file.byteSize)
        return "На Mac: \(local) • Размер файла: \(cloud)"
    }
}

private struct EvictionBanner: View {
    let progress: EvictionProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.up")
                    .foregroundStyle(AppPalette.accent)

                Text("Выгружаем локальные копии")
                    .font(.callout.weight(.semibold))

                Spacer()

                Text("\(progress.completedCount) / \(progress.totalCount)")
                    .font(.callout)
                    .foregroundStyle(AppPalette.secondaryText)
                    .monospacedDigit()
            }

            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .tint(AppPalette.accent)
                .animation(.easeOut(duration: 0.2), value: progress.fraction)

            Text("Освобождено \(byteCountText(progress.freedByteSize)) из \(byteCountText(progress.totalByteSize))")
                .font(.caption)
                .foregroundStyle(AppPalette.secondaryText)
                .monospacedDigit()
        }
        .padding(12)
        .cardChrome(AppPalette.panelBackground)
    }
}

private struct FolderDetailsPanel: View {
    let folder: CloudFolderSummary
    let statusMessage: String
    let errorMessage: String?
    let canFreeUpSpace: Bool
    let isFreeingUp: Bool
    let onFreeUp: () -> Void
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Spacer()
                Image(systemName: "star")
                    .foregroundStyle(AppPalette.favorite)
            }

            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 78, weight: .regular))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(AppPalette.folderHighlight, AppPalette.folderBase)
                    .frame(maxWidth: .infinity)

                Text(folder.name)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)

                Text((["iCloud Drive"] + folder.relativePath.split(separator: "/").map(String.init)).joined(separator: "  ›  "))
                    .font(.callout)
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(2)
            }

            storageBox

            VStack(alignment: .leading, spacing: 12) {
                Text("Information")
                    .font(.callout.weight(.semibold))

                infoRow("Status", folder.downloadState.title, tint: folder.downloadState.tint)
                infoRow("Files", "\(folder.fileCount)")
                infoRow("Folders", "\(folder.folderCount)")
                infoRow("Last opened", folder.lastModified?.formatted(date: .abbreviated, time: .shortened) ?? "-")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(AppPalette.danger)
                        .lineLimit(3)
                } else {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryText)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Actions")
                    .font(.callout.weight(.semibold))

                Button(action: onFreeUp) {
                    Label(
                        isFreeingUp && !canFreeUpSpace ? "Freeing Up..." : "Free Up Space",
                        systemImage: "icloud.and.arrow.up"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canFreeUpSpace)

                Button(action: onReveal) {
                    Label("Reveal in Finder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Spacer()
        }
    }

    private var storageBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                storageMetric("On Mac", byteCountText(folder.localByteSize), AppPalette.success)
                Spacer()
                storageMetric("In Cloud", byteCountText(folder.cloudByteSize), AppPalette.primaryText)
            }

            ProgressView(value: folder.downloadedFraction)
                .progressViewStyle(.linear)
                .tint(folder.downloadState.tint)

            Text(folder.downloadedFraction.formatted(.percent.precision(.fractionLength(0))) + " downloaded")
                .font(.caption)
                .foregroundStyle(AppPalette.secondaryText)
                .monospacedDigit()
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .cardChrome(AppPalette.panelBackground)
    }

    private func storageMetric(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppPalette.secondaryText)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
    }

    private func infoRow(_ title: String, _ value: String, tint: Color = AppPalette.primaryText) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(AppPalette.secondaryText)
            Spacer()
            Text(value)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .textCase(.uppercase)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(AppPalette.accent.opacity(configuration.isPressed ? 0.76 : 1))
            .clipShape(.rect(cornerRadius: 8))
            .shadow(color: AppPalette.accent.opacity(0.20), radius: 12, y: 5)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(AppPalette.primaryText)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .cardChrome(AppPalette.controlBackground.opacity(configuration.isPressed ? 0.72 : 1))
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppPalette.primaryText)
            .background(AppPalette.controlBackground.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(.rect(cornerRadius: 8))
    }
}

private struct OlchuStudioMark: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("> OLCHU_")
                    .font(.system(size: 8, weight: .light, design: .monospaced))
                    .foregroundStyle(AppPalette.secondaryText)
                    .tracking(0.8)

                HStack(spacing: 3) {
                    Text("STUDI")
                        .font(.system(size: 13, weight: .black))
                        .tracking(0.5)

                    Circle()
                        .fill(AppPalette.accent)
                        .frame(width: 16, height: 16)
                        .shadow(color: AppPalette.accent.opacity(0.42), radius: 7)
                }
            }

            Text("CLOUD")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppPalette.secondaryText)
                .padding(.bottom, 2)
        }
        .foregroundStyle(AppPalette.primaryText)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Olchu Studio Cloud")
    }
}

private struct StudioBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.075, green: 0.075, blue: 0.070),
                    Color(red: 0.025, green: 0.025, blue: 0.023)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    AppPalette.accent.opacity(0.10),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 520
            )

            StudioGrid()
                .opacity(0.22)
        }
        .ignoresSafeArea()
    }
}

private struct StudioGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let spacing: CGFloat = 48

            for x in stride(from: CGFloat.zero, through: size.width, by: spacing) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }

            for y in stride(from: CGFloat.zero, through: size.height, by: spacing) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }

            context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

private enum AppPalette {
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.48)
    static let stroke = Color.white.opacity(0.11)
    static let accent = Color(red: 1.00, green: 0.22, blue: 0.24)
    static let success = Color(red: 0.25, green: 0.82, blue: 0.48)
    static let warning = Color(red: 1.00, green: 0.68, blue: 0.20)
    static let danger = accent
    static let favorite = warning
    static let cloudBlue = Color(red: 0.32, green: 0.64, blue: 1.00)
    static let folderBase = Color(red: 0.22, green: 0.30, blue: 0.42)
    static let folderHighlight = Color(red: 0.46, green: 0.70, blue: 1.00)
    static let controlBackground = Color.white.opacity(0.055)
    static let panelBackground = Color.black.opacity(0.30)
    static let cardBackground = Color.white.opacity(0.045)
    static let contentBackground = Color.black.opacity(0.12)
    static let detailsBackground = Color.black.opacity(0.24)
}

private extension CloudFolderDownloadState {
    var tint: Color {
        switch self {
        case .downloaded:
            AppPalette.success
        case .cloudOnly:
            AppPalette.cloudBlue
        case .partial:
            AppPalette.warning
        }
    }
}

private extension View {
    /// Rounded 8pt card: fill, hairline stroke and clipping.
    func cardChrome(_ fill: some ShapeStyle, stroke: Color = AppPalette.stroke) -> some View {
        background(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(stroke, lineWidth: 1)
            )
            .clipShape(.rect(cornerRadius: 8))
    }
}

private func byteCountText(_ byteSize: Int64?) -> String {
    guard let byteSize, byteSize > 0 else {
        return "-"
    }

    return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
}

#Preview {
    ContentView()
}
