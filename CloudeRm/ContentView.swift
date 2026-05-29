//
//  ContentView.swift
//  CloudeRm
//
//  Created by olchu on 28. 5. 2026..
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = CloudFilesViewModel()

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            if viewModel.isScanning && viewModel.files.isEmpty {
                scanningState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.files.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if viewModel.isScanning {
                    scanningBanner
                }

                filesTable(selection: $viewModel.selectedFileIDs)

                actionBar
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.statusMessage)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text(viewModel.selectedFolderDisplayPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let fileSummary = viewModel.fileSummary {
                    Label(fileSummary, systemImage: "externaldrive")
                        .font(.callout)
                        .foregroundStyle(.primary)
                }

                if viewModel.skippedFileCount > 0 {
                    Text("Пропущено файлов: \(viewModel.skippedFileCount)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            if viewModel.isScanning {
                Button {
                    viewModel.cancelScan()
                } label: {
                    Label("Остановить", systemImage: "stop.circle")
                }
            } else {
                Button {
                    viewModel.chooseFolder()
                } label: {
                    Label("Выбрать папку", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var scanningState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)

            Text(viewModel.statusMessage)
                .font(.title3)
                .fontWeight(.semibold)

            Text("Проверено файлов: \(viewModel.scannedFileCount)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                viewModel.cancelScan()
            } label: {
                Label("Остановить сканирование", systemImage: "stop.circle")
            }
            .padding(.top, 4)
        }
    }

    private var scanningBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text(viewModel.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
                viewModel.cancelScan()
            } label: {
                Label("Остановить", systemImage: "stop.circle")
            }
        }
        .padding(.vertical, 4)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.evictSelectedFile()
            } label: {
                Label("Выгрузить выбранный", systemImage: "icloud.and.arrow.up")
            }
            .disabled(!viewModel.canEvictSingleSelectedFile)

            Divider()
                .frame(height: 20)

            Button {
                viewModel.selectAllFiles()
            } label: {
                Label("Выбрать все", systemImage: "checklist.checked")
            }
            .disabled(viewModel.files.isEmpty || viewModel.selectedFileIDs.count == viewModel.files.count)

            Button {
                viewModel.clearSelection()
            } label: {
                Label("Снять выбор", systemImage: "xmark.circle")
            }
            .disabled(viewModel.selectedFileIDs.isEmpty)

            Spacer()

            Text(viewModel.selectionSummary)
                .font(.callout)
                .foregroundStyle(viewModel.selectedFileIDs.isEmpty ? .secondary : .primary)
                .monospacedDigit()
        }
    }

    private func filesTable(selection: Binding<Set<CloudFile.ID>>) -> some View {
        Table(viewModel.files, selection: selection) {
            TableColumn("Имя") { file in
                Label {
                    Text(file.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 160, ideal: 220)

            TableColumn("Путь") { file in
                Text(file.relativePath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.relativePath)
            }
            .width(min: 220, ideal: 360)

            TableColumn("Размер") { file in
                Text(byteCountText(for: file.byteSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 92, ideal: 112)

            TableColumn("Изменён") { file in
                Text(modificationDateText(for: file.modificationDate))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .width(min: 132, ideal: 150)

            TableColumn("Статус") { file in
                Text(file.downloadStatus.displayName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 96, ideal: 120)

            TableColumn("Результат") { file in
                Text(evictionResultText(for: file.evictionResult))
                    .foregroundStyle(evictionResultStyle(for: file.evictionResult))
                    .lineLimit(1)
                    .help(evictionResultText(for: file.evictionResult))
            }
            .width(min: 120, ideal: 180)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)

            Text(viewModel.hasSelectedFolder ? "В этой папке пока нет скачанных iCloud-файлов" : "Выберите папку iCloud Drive")
                .font(.title3)
                .fontWeight(.semibold)

            Text("CloudeRm показывает только iCloud-файлы, у которых сейчас есть локальная копия на этом Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
    }

    private func byteCountText(for byteSize: Int64?) -> String {
        guard let byteSize else {
            return "-"
        }

        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    private func modificationDateText(for date: Date?) -> String {
        guard let date else {
            return "-"
        }

        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func evictionResultText(for result: EvictionResult?) -> String {
        result?.displayName ?? "-"
    }

    private func evictionResultStyle(for result: EvictionResult?) -> Color {
        switch result {
        case .success:
            .green
        case .failure:
            .red
        case .pending:
            .secondary
        case .skipped, nil:
            .secondary
        }
    }
}

#Preview {
    ContentView()
}
