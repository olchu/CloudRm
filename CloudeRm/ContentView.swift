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

                if viewModel.selectedFolderSummary != nil {
                    Divider()
                        .overlay(AppPalette.stroke)

                    detailsPanel
                }
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.font, .system(size: 13, design: .monospaced))
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
            OlchuStudioMark()
                .frame(width: 118, alignment: .leading)

            Rectangle()
                .fill(AppPalette.stroke)
                .frame(width: 1, height: 28)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppPalette.secondaryText)

                TextField("Search folders...", text: searchTextBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))

                Text("⌘F")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
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
        VStack(spacing: 10) {
            if viewModel.isScanning {
                scanningBanner
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.filteredFolderSummaries) { folder in
                        FolderListRow(
                            folder: folder,
                            isSelected: viewModel.selectedFolderSummary?.id == folder.id
                        ) {
                            viewModel.selectedFolderID = folder.id
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.automatic)
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

private struct FolderListRow: View {
    let folder: CloudFolderSummary
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(isSelected ? AppPalette.accent : AppPalette.folderHighlight)
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
                    .foregroundStyle(isSelected ? AppPalette.accent : AppPalette.secondaryText)
                    .frame(width: 18)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 68)
            .contentShape(.rect)
            .background(isSelected ? AppPalette.selectedCardBackground : AppPalette.cardBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? AppPalette.accent.opacity(0.62) : AppPalette.stroke, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(statusText)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor)
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

    private var statusColor: Color {
        switch folder.downloadState {
        case .downloaded:
            AppPalette.success
        case .cloudOnly:
            AppPalette.cloudBlue
        case .partial:
            AppPalette.warning
        }
    }
}

private struct FolderBubbleCloud: View {
    let folders: [CloudFolderSummary]
    let selectedFolderID: CloudFolderSummary.ID?
    let onSelect: (CloudFolderSummary) -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = makeLayout(for: folders, width: proxy.size.width)

            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    ForEach(layout.placements) { placement in
                        FolderBubble(
                            folder: placement.folder,
                            diameter: placement.diameter,
                            tint: placement.tint,
                            bubbleImageName: placement.imageName,
                            isSelected: placement.folder.id == selectedFolderID,
                            onSelect: {
                                onSelect(placement.folder)
                            }
                        )
                        .frame(width: placement.diameter, height: placement.diameter)
                        .position(x: placement.center.x, y: placement.center.y)
                    }
                }
                .frame(width: proxy.size.width, height: max(layout.height, proxy.size.height))
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func makeLayout(for folders: [CloudFolderSummary], width: CGFloat) -> BubbleLayout {
        guard !folders.isEmpty else {
            return BubbleLayout(placements: [], height: 0)
        }

        let availableWidth = max(width, 560)
        let maxSize = max(folders.map(\.cloudByteSize).max() ?? 1, 1)
        let minDiameter: CGFloat = availableWidth < 760 ? 150 : 170
        let maxDiameter: CGFloat = availableWidth < 760 ? 255 : 330
        let spacing: CGFloat = 22
        let horizontalStepFactor: CGFloat = 0.82
        let rowStepFactor: CGFloat = 0.76
        let rowOffsets: [CGFloat] = [0, 58, 20, 92]
        let verticalOffsets: [CGFloat] = [0, 26, -18, 34, -10, 18]
        let tints = AppPalette.bubbleTints
        let imageNames = AppPalette.bubbleImageNames

        var placements: [BubblePlacement] = []
        var cursorX: CGFloat = rowOffsets[0]
        var cursorY: CGFloat = 16
        var rowHeight: CGFloat = 0
        var rowIndex = 0
        var totalHeight: CGFloat = 0

        for (index, folder) in folders.enumerated() {
            let diameter = bubbleDiameter(
                for: folder,
                maxSize: maxSize,
                minDiameter: minDiameter,
                maxDiameter: maxDiameter
            )

            if cursorX + diameter > availableWidth, cursorX > rowOffsets[rowIndex % rowOffsets.count] {
                rowIndex += 1
                cursorX = rowOffsets[rowIndex % rowOffsets.count]
                cursorY += max(rowHeight * rowStepFactor, minDiameter + spacing)
                rowHeight = 0
            }

            let verticalOffset = verticalOffsets[index % verticalOffsets.count]
            let center = CGPoint(
                x: cursorX + diameter / 2,
                y: max(cursorY + diameter / 2 + verticalOffset, cursorY + diameter / 2)
            )
            let tint = tints[index % tints.count]

            placements.append(
                BubblePlacement(
                    folder: folder,
                    diameter: diameter,
                    center: center,
                    tint: tint,
                    imageName: imageNames[index % imageNames.count]
                )
            )

            cursorX += diameter * horizontalStepFactor + spacing
            rowHeight = max(rowHeight, diameter + abs(verticalOffset))
            totalHeight = max(totalHeight, center.y + diameter / 2 + 28)
        }

        return BubbleLayout(placements: placements, height: totalHeight)
    }

    private func bubbleDiameter(
        for folder: CloudFolderSummary,
        maxSize: Int64,
        minDiameter: CGFloat,
        maxDiameter: CGFloat
    ) -> CGFloat {
        guard maxSize > 0 else {
            return minDiameter
        }

        let size = max(folder.cloudByteSize, 1)
        let normalized = sqrt(Double(size) / Double(maxSize))
        return minDiameter + (maxDiameter - minDiameter) * normalized
    }
}

private struct BubbleLayout {
    let placements: [BubblePlacement]
    let height: CGFloat
}

private struct BubblePlacement: Identifiable {
    var id: CloudFolderSummary.ID { folder.id }

    let folder: CloudFolderSummary
    let diameter: CGFloat
    let center: CGPoint
    let tint: Color
    let imageName: String
}

private struct FolderBubble: View {
    let folder: CloudFolderSummary
    let diameter: CGFloat
    let tint: Color
    let bubbleImageName: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                bubbleSurface

                VStack(spacing: contentSpacing) {
                    folderIcon

                    VStack(spacing: 5) {
                        Text(folder.name)
                            .font(titleFont)
                            .foregroundStyle(AppPalette.primaryText)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)

                        Text(primaryMetricText)
                            .font(metricFont)
                            .foregroundStyle(AppPalette.secondaryText)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)

                        Text(itemCountText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppPalette.secondaryText)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }

                    VStack(spacing: 6) {
                        Text(statusText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppPalette.secondaryText)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)

                        if folder.downloadState == .partial {
                            ProgressView(value: folder.downloadedFraction)
                                .progressViewStyle(.linear)
                                .tint(progressTint)
                                .frame(width: progressWidth)
                        }
                    }
                }
                .padding(contentPadding)

                Image(systemName: "star.fill")
                    .font(.system(size: starSize, weight: .semibold))
                    .foregroundStyle(AppPalette.favorite)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(.ultraThinMaterial)
                    .background(Color.white.opacity(0.42))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))
                    .offset(x: -diameter * 0.08, y: diameter * 0.08)
                    .opacity(isSelected ? 1 : 0.82)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var bubbleSurface: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.58),
                            tint.opacity(0.18),
                            Color.white.opacity(0.06)
                        ],
                        center: .topLeading,
                        startRadius: diameter * 0.08,
                        endRadius: diameter * 0.62
                    )
                )
                .blur(radius: 0.4)

            Image(bubbleImageName)
                .resizable()
                .scaledToFit()
                .opacity(isSelected ? 0.86 : 0.72)
                .saturation(1.02)
                .allowsHitTesting(false)

            Circle()
                .stroke(Color.white.opacity(0.34), lineWidth: diameter * 0.012)
                .blur(radius: 1.2)
                .padding(diameter * 0.05)
        }
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(
                    isSelected ? AppPalette.accent.opacity(0.52) : Color.white.opacity(0.18),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
        .shadow(color: tint.opacity(isSelected ? 0.38 : 0.18), radius: isSelected ? 26 : 16, y: 12)
    }

    private var folderIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "folder.fill")
                .font(.system(size: folderIconSize, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(AppPalette.folderHighlight, AppPalette.folderBase)

            Image(systemName: providerBadgeIcon)
                .font(.system(size: badgeIconSize, weight: .semibold))
                .foregroundStyle(AppPalette.cloudBlue)
                .frame(width: iconBadgeSize, height: iconBadgeSize)
                .background(.white.opacity(0.92))
                .clipShape(Circle())
                .shadow(color: AppPalette.cloudBlue.opacity(0.18), radius: 8, y: 4)
                .offset(x: diameter * 0.04, y: diameter * 0.04)
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
            AppPalette.cloudBlue
        case .partial:
            AppPalette.warning
        }
    }

    private var primaryMetricText: String {
        if folder.localByteSize > 0 {
            return "Освободить \(byteCountText(folder.localByteSize))"
        }

        return "В iCloud \(byteCountText(folder.cloudByteSize))"
    }

    private var itemCountText: String {
        let files = localizedCount(folder.fileCount, one: "файл", few: "файла", many: "файлов")
        guard folder.folderCount > 0 else {
            return files
        }

        let folders = localizedCount(folder.folderCount, one: "папка", few: "папки", many: "папок")
        return "\(files) • \(folders)"
    }

    private var statusText: String {
        switch folder.downloadState {
        case .downloaded:
            "На Mac"
        case .cloudOnly:
            "Только в iCloud"
        case .partial:
            "\(folder.downloadedFraction.formatted(.percent.precision(.fractionLength(0)))) на Mac"
        }
    }

    private func localizedCount(_ value: Int, one: String, few: String, many: String) -> String {
        let mod10 = value % 10
        let mod100 = value % 100
        let word: String

        if mod10 == 1 && mod100 != 11 {
            word = one
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            word = few
        } else {
            word = many
        }

        return "\(value) \(word)"
    }

    private var titleFont: Font {
        diameter > 250 ? .title3.weight(.bold) : .headline.weight(.bold)
    }

    private var metricFont: Font {
        diameter > 220 ? .callout : .caption
    }

    private var contentSpacing: CGFloat {
        diameter > 230 ? 14 : 9
    }

    private var contentPadding: CGFloat {
        diameter * 0.14
    }

    private var progressWidth: CGFloat {
        min(diameter * 0.45, 128)
    }

    private var folderIconSize: CGFloat {
        min(diameter * 0.30, 82)
    }

    private var iconBadgeSize: CGFloat {
        min(diameter * 0.16, 42)
    }

    private var badgeIconSize: CGFloat {
        min(diameter * 0.085, 22)
    }

    private var badgeSize: CGFloat {
        min(diameter * 0.14, 44)
    }

    private var starSize: CGFloat {
        min(diameter * 0.07, 20)
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
        .background(.regularMaterial)
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
        .background(.ultraThinMaterial)
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
        .background(.ultraThinMaterial)
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
    static let selectedCardBackground = accent.opacity(0.11)
    static let contentBackground = Color.black.opacity(0.12)
    static let detailsBackground = Color.black.opacity(0.24)
    static let bubbleTints = [
        accent,
        Color(red: 0.36, green: 0.62, blue: 1),
        Color(red: 0.54, green: 0.38, blue: 0.92),
        Color(red: 0.94, green: 0.55, blue: 0.20),
        Color(red: 0.20, green: 0.68, blue: 0.58),
        Color(red: 0.88, green: 0.30, blue: 0.52)
    ]
    static let bubbleImageNames = ["BubbleReference"]

    static var windowOverlay: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.025),
                Color.clear,
                Color.black.opacity(0.12)
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
