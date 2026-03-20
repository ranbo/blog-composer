import SwiftUI

// MARK: - Sync Progress Sheet

struct SyncProgressSheet: View {
    let completed: Int
    let total: Int?
    let recentFiles: [String]

    private var isScanning: Bool { total == nil && completed == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Header
            HStack(spacing: 8) {
                if isScanning {
                    ProgressView().controlSize(.small)
                    Text("Scanning files…")
                        .foregroundStyle(.secondary)
                } else if let total {
                    Text("Syncing to GCS")
                        .font(.headline)
                    Spacer()
                    Text("\(completed) / \(total)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("Syncing to GCS")
                        .font(.headline)
                    Spacer()
                    Text("\(completed) files")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            // Progress bar
            if let total {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)  // indeterminate
            }

            // Scrolling file list
            if !recentFiles.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(recentFiles.enumerated()), id: \.offset) { idx, path in
                                Text(path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(height: 130)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor)))
                    .onChange(of: recentFiles.count) { newCount in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(newCount - 1, anchor: .bottom)
                        }
                    }
                }
            } else if !isScanning {
                // Placeholder height so the sheet doesn't jump when first file arrives
                Color.clear.frame(height: 130)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
