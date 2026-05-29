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
            AppPalette.windowBackground
                .ignoresSafeArea()

            HStack(spacing: 0) {
                mainPanel

                if viewModel.selectedFolderSummary != nil {
                    Divider()
                        .overlay(AppPalette.stroke)

                    detailsPanel
                }
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 680)
        .alert("Выгрузить локальные копии?", isPresented: $isConfirmingFolderEviction) {
            Button("Отмена", role: .cancel) {}
            Button("Выгрузить", role: .destructive) {
                viewModel.evictSelectedFolderLocalCopies()
            }
        } message: {
            if let folder = viewModel.selectedFolderSummary {
                Text("Файлы останутся в iCloud, но локальная копия папки \(folder.name) будет удалена с этого Mac.")
            }
        }
    }

    private var mainPanel: some View {
        VStack(spacing: 18) {
            topBar
            filtersBar

            if viewModel.isScanning && viewModel.files.isEmpty {
                scanningState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.filteredFolderSummaries.isEmpty {
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
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppPalette.secondaryText)

                TextField("Search folders...", text: searchTextBinding)
                    .textFieldStyle(.plain)
                    .font(.callout)

                Text("⌘F")
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(AppPalette.controlBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppPalette.stroke, lineWidth: 1)
            )
            .clipShape(.rect(cornerRadius: 8))

            Spacer()

            if viewModel.isScanning {
                Button {
                    viewModel.cancelScan()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Button {
                if viewModel.hasSelectedFolder {
                    viewModel.refreshSelectedFolder()
                } else {
                    viewModel.chooseFolder()
                }
            } label: {
                Label("Scan Now", systemImage: "arrow.triangle.2.circlepath.icloud")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.isEvicting)

            Menu {
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

            Picker("Sort by", selection: sortBinding) {
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
            .background(viewModel.folderFilter == filter ? AppPalette.accent : AppPalette.controlBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(viewModel.folderFilter == filter ? AppPalette.accent : AppPalette.stroke, lineWidth: 1)
            )
            .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var folderList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if viewModel.isScanning {
                    scanningBanner
                }

                ForEach(viewModel.filteredFolderSummaries) { folder in
                    FolderCard(
                        folder: folder,
                        isSelected: folder.id == viewModel.selectedFolderSummary?.id,
                        onSelect: {
                            viewModel.selectedFolderID = folder.id
                        },
                        onFreeUp: {
                            viewModel.selectedFolderID = folder.id
                            isConfirmingFolderEviction = true
                        },
                        onEvictFile: { file in
                            viewModel.evictFile(file)
                        }
                    )
                }
            }
            .padding(.vertical, 2)
        }
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

            Text(viewModel.hasSelectedFolder ? viewModel.statusMessage : "Scan Now will use the fast macOS metadata index first.")
                .font(.body)
                .foregroundStyle(AppPalette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button {
                viewModel.hasSelectedFolder ? viewModel.refreshSelectedFolder() : viewModel.chooseFolder()
            } label: {
                Label(viewModel.hasSelectedFolder ? "Scan Now" : "Choose Folder", systemImage: "folder")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 4)
        }
    }

    private var summaryStrip: some View {
        HStack(spacing: 0) {
            summaryMetric(icon: "cloud", title: "Total in Cloud", value: byteCountText(viewModel.totalCloudByteSize), tint: AppPalette.cloudBlue)
            summaryDivider
            summaryMetric(icon: "externaldrive", title: "Total on Mac", value: byteCountText(viewModel.totalKnownByteSize), tint: AppPalette.secondaryText)
            summaryDivider
            summaryMetric(icon: "clock.arrow.circlepath", title: "Potential to Free Up", value: byteCountText(viewModel.potentialFreeUpByteSize), tint: AppPalette.warning)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(AppPalette.panelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.stroke, lineWidth: 1)
        )
        .clipShape(.rect(cornerRadius: 8))
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
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryText)
                Text(value)
                    .font(.headline.weight(.semibold))
                    .monospacedDigit()
            }

            Spacer()
        }
    }

    private var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let folder = viewModel.selectedFolderSummary {
                FolderDetailsPanel(
                    folder: folder,
                    statusMessage: viewModel.statusMessage,
                    errorMessage: viewModel.errorMessage,
                    canFreeUpSpace: viewModel.canEvictSelectedFolder,
                    isBusy: viewModel.isEvicting,
                    onFreeUp: { isConfirmingFolderEviction = true },
                    onReveal: revealSelectedFolder
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 34))
                        .foregroundStyle(AppPalette.secondaryText)

                    Text("No folder selected")
                        .font(.headline)
                        .foregroundStyle(AppPalette.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: 300)
        .background(AppPalette.detailsBackground)
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { viewModel.searchText },
            set: { newValue in
                viewModel.searchText = newValue
            }
        )
    }

    private var sortBinding: Binding<CloudFolderSort> {
        Binding(
            get: { viewModel.folderSort },
            set: { newValue in
                viewModel.folderSort = newValue
            }
        )
    }

    private func revealSelectedFolder() {
        guard let folder = viewModel.selectedFolderSummary, let rootURL = viewModel.selectedFolderURL else {
            return
        }

        let url = rootURL.appending(path: folder.relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct FolderCard: View {
    let folder: CloudFolderSummary
    let isSelected: Bool
    let onSelect: () -> Void
    let onFreeUp: () -> Void
    let onEvictFile: (CloudFile) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                folderIcon

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(folder.name)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)

                        if folder.downloadState == .downloaded {
                            Image(systemName: "star")
                                .font(.caption)
                                .foregroundStyle(AppPalette.favorite)
                        }
                    }

                    Text(folderSubtitle)
                        .font(.callout)
                        .foregroundStyle(AppPalette.secondaryText)
                        .lineLimit(1)

                    HStack(alignment: .center, spacing: 10) {
                        ProgressView(value: folder.downloadedFraction)
                            .progressViewStyle(.linear)
                            .tint(progressTint)

                        Text(progressText)
                            .font(.caption)
                            .foregroundStyle(AppPalette.primaryText)
                            .monospacedDigit()
                            .frame(width: 104, alignment: .trailing)
                    }
                }

                Spacer(minLength: 10)

                metric(title: "In Cloud", value: byteCountText(folder.cloudByteSize), tint: AppPalette.primaryText)
                metric(title: "On Mac", value: folder.localByteSize > 0 ? byteCountText(folder.localByteSize) : "-", tint: folder.localByteSize > 0 ? AppPalette.success : AppPalette.secondaryText)

                Button(action: onFreeUp) {
                    Text(actionTitle)
                        .font(.callout)
                        .frame(width: 110)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!folder.canFreeUpSpace)

                Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(AppPalette.controlBackground)
                    .clipShape(.rect(cornerRadius: 8))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(minHeight: 110)
            .contentShape(.rect)
            .onTapGesture(perform: onSelect)

            if isSelected {
                Divider()
                    .overlay(AppPalette.stroke)
                    .padding(.horizontal, 18)

                expandedFiles
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
        }
        .background(isSelected ? AppPalette.selectedCardBackground : AppPalette.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? AppPalette.accent.opacity(0.55) : AppPalette.stroke, lineWidth: 1)
        )
        .clipShape(.rect(cornerRadius: 8))
    }

    private var expandedFiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Files in this folder")
                    .font(.callout.weight(.semibold))

                Spacer()

                Text("\(localFiles.count) on Mac / \(folder.fileCount) total")
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryText)
                    .monospacedDigit()
            }

            if folder.files.isEmpty {
                Text("No indexed files")
                    .font(.callout)
                    .foregroundStyle(AppPalette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 6) {
                    ForEach(folder.files.prefix(60), id: \.id) { file in
                        FolderFileRow(file: file, onEvict: { onEvictFile(file) })
                    }

                    if folder.files.count > 60 {
                        Text("Showing first 60 files")
                            .font(.caption)
                            .foregroundStyle(AppPalette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var localFiles: [CloudFile] {
        folder.files.filter { $0.downloadStatus.isStoredLocally }
    }

    private var folderIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "folder.fill")
                .font(.system(size: 62, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(AppPalette.folderHighlight, AppPalette.folderBase)
                .frame(width: 80, height: 72)

            Image(systemName: providerBadgeIcon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppPalette.cloudBlue)
                .frame(width: 32, height: 32)
                .background(.white)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
    }

    private var providerBadgeIcon: String {
        switch folder.downloadState {
        case .downloaded:
            "checkmark.icloud"
        case .cloudOnly:
            "icloud"
        case .partial:
            "icloud.and.arrow.down"
        }
    }

    private var progressTint: Color {
        switch folder.downloadState {
        case .downloaded:
            AppPalette.success
        case .cloudOnly:
            AppPalette.secondaryText
        case .partial:
            AppPalette.warning
        }
    }

    private var actionTitle: String {
        switch folder.downloadState {
        case .cloudOnly:
            "Download"
        case .downloaded, .partial:
            "Free Up Space"
        }
    }

    private var progressText: String {
        folder.downloadedFraction.formatted(.percent.precision(.fractionLength(0))) + " downloaded"
    }

    private var folderSubtitle: String {
        let dateText = folder.lastModified?.formatted(date: .abbreviated, time: .shortened) ?? "not indexed yet"
        return "iCloud Drive  ›  \(folder.relativePath)  •  Updated \(dateText)"
    }

    private func metric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)

            Text(title)
                .font(.caption)
                .foregroundStyle(AppPalette.secondaryText)
        }
        .frame(width: 88, alignment: .leading)
    }
}

private struct FolderFileRow: View {
    let file: CloudFile
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

            Text(byteCountText(file.byteSize))
                .font(.caption)
                .foregroundStyle(AppPalette.secondaryText)
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)

            Text(file.downloadStatus.displayName)
                .font(.caption)
                .foregroundStyle(statusTint)
                .frame(width: 92, alignment: .trailing)

            Button(action: onEvict) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(IconButtonStyle())
            .disabled(!file.downloadStatus.isStoredLocally)
            .help(file.downloadStatus.isStoredLocally ? "Выгрузить локальную копию" : "Файл уже только в iCloud")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AppPalette.controlBackground)
        .clipShape(.rect(cornerRadius: 8))
    }

    private var statusTint: Color {
        file.downloadStatus.isStoredLocally ? AppPalette.success : AppPalette.cloudBlue
    }
}

private struct FolderDetailsPanel: View {
    let folder: CloudFolderSummary
    let statusMessage: String
    let errorMessage: String?
    let canFreeUpSpace: Bool
    let isBusy: Bool
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

                Text("iCloud Drive  ›  \(folder.relativePath)")
                    .font(.callout)
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(2)
            }

            storageBox

            VStack(alignment: .leading, spacing: 12) {
                Text("Information")
                    .font(.callout.weight(.semibold))

                infoRow("Status", folder.downloadState.title, tint: statusTint)
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
                    Label(isBusy ? "Working..." : "Free Up Space", systemImage: "icloud.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canFreeUpSpace || isBusy)

                Button(action: onReveal) {
                    Label("Reveal in Finder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {} label: {
                    Label("More", systemImage: "ellipsis")
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
                .tint(statusTint)

            Text(folder.downloadedFraction.formatted(.percent.precision(.fractionLength(0))) + " downloaded")
                .font(.caption)
                .foregroundStyle(AppPalette.secondaryText)
                .monospacedDigit()
        }
        .padding(14)
        .background(AppPalette.panelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.stroke, lineWidth: 1)
        )
        .clipShape(.rect(cornerRadius: 8))
    }

    private var statusTint: Color {
        switch folder.downloadState {
        case .downloaded:
            AppPalette.success
        case .cloudOnly:
            AppPalette.cloudBlue
        case .partial:
            AppPalette.warning
        }
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
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(AppPalette.accent.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(.rect(cornerRadius: 8))
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundStyle(AppPalette.primaryText)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(AppPalette.controlBackground.opacity(configuration.isPressed ? 0.72 : 1))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppPalette.stroke, lineWidth: 1)
            )
            .clipShape(.rect(cornerRadius: 8))
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

private enum AppPalette {
    static let primaryText = Color(red: 0.96, green: 0.97, blue: 1)
    static let secondaryText = Color(red: 0.66, green: 0.68, blue: 0.76)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.22, green: 0.42, blue: 0.96)
    static let success = Color(red: 0.42, green: 0.88, blue: 0.38)
    static let warning = Color(red: 0.95, green: 0.68, blue: 0.12)
    static let danger = Color(red: 1, green: 0.36, blue: 0.32)
    static let favorite = Color(red: 1, green: 0.79, blue: 0.18)
    static let cloudBlue = Color(red: 0.26, green: 0.68, blue: 1)
    static let folderBase = Color(red: 0.17, green: 0.64, blue: 0.88)
    static let folderHighlight = Color(red: 0.37, green: 0.82, blue: 1)
    static let controlBackground = Color.white.opacity(0.055)
    static let panelBackground = Color.white.opacity(0.055)
    static let cardBackground = Color.white.opacity(0.055)
    static let selectedCardBackground = Color.white.opacity(0.085)
    static let contentBackground = Color.black.opacity(0.08)
    static let detailsBackground = Color.black.opacity(0.14)

    static var windowBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.15, green: 0.13, blue: 0.24),
                Color(red: 0.07, green: 0.10, blue: 0.17),
                Color(red: 0.12, green: 0.14, blue: 0.22)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
