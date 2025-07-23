import SwiftUI
import AppKit
import UniformTypeIdentifiers

actor AtomicInt {
    private var value: Int = 0
    func increment() -> Int {
        value += 1
        return value
    }
    func get() -> Int { value }
}

struct AnimatedGIFView: NSViewRepresentable {
    let gifName: String
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.canDrawSubviewsIntoLayer = true
        imageView.animates = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        if let url = Bundle.main.url(forResource: gifName, withExtension: "gif") {
            if let image = NSImage(contentsOf: url) {
                imageView.image = image
            }
        }
        return imageView
    }
    func updateNSView(_ nsView: NSImageView, context: Context) {}
}

struct ContentView: View {
    @State private var isHovering = false
    @State private var csvURL: URL?
    @State private var destinationFolder: URL?
    @State private var isDownloading = false
    @State private var progressText = ""
    @State private var downloadComplete = false
    @State private var totalImages: Int = 0
    @State private var imagesChecked: Int = 0
    @State private var cancelDownload = false
    @State private var lastUIUpdate = Date()
    let uiUpdateInterval: TimeInterval = 0.25

    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [
                Color(red: 0.96, green: 0.96, blue: 1.0),
                Color(red: 0.85, green: 0.90, blue: 1.00),
                Color(red: 0.98, green: 0.98, blue: 0.95)
            ]), startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Text("Batch Upload Checker")
                    .font(.custom("Menlo", size: 32).weight(.bold))
                    .foregroundColor(.accentColor)
                    .shadow(color: .gray.opacity(0.23), radius: 2, x: 2, y: 2)
                    .padding(.top, 8)

                VStack(spacing: 20) {
                    if let csvURL = csvURL {
                        Label {
                            Text(csvURL.lastPathComponent)
                                .font(.title2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.accentColor)
                        }
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(isHovering ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: 2)
                                .background(
                                    isHovering ? Color.accentColor.opacity(0.08) : Color(NSColor.windowBackgroundColor).opacity(0.7)
                                )
                                .animation(.easeInOut(duration: 0.18), value: isHovering)
                            VStack {
                                Image(systemName: "tray.and.arrow.down.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(isHovering ? .accentColor : .gray)
                                Text("Drop CSV File Here")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(height: 70)
                        .onDrop(of: ["public.file-url"], isTargeted: $isHovering) { providers in
                            if let provider = providers.first {
                                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                    if let fileURL = url, fileURL.pathExtension.lowercased() == "csv" {
                                        DispatchQueue.main.async {
                                            self.csvURL = fileURL
                                            // Automatically set destination folder to CSV's directory
                                            self.destinationFolder = fileURL.deletingLastPathComponent()
                                        }
                                    }
                                }
                                return true
                            }
                            return false
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            if csvURL == nil {
                                if let file = openFileDialog(allowedTypes: ["csv"]) {
                                    csvURL = file
                                    // Automatically set destination folder to CSV's directory
                                    destinationFolder = file.deletingLastPathComponent()
                                }
                            } else {
                                csvURL = nil
                                destinationFolder = nil
                            }
                        } label: {
                            Label(csvURL == nil ? "Select CSV File" : "Clear CSV File",
                                  systemImage: csvURL == nil ? "doc" : "xmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(csvURL == nil ? .accentColor : .red)
                        .controlSize(.large)
                        .disabled(isDownloading)

                        // Optional: Let user override the auto-selected folder
                        Button {
                            if let folder = openFolderDialog() {
                                destinationFolder = folder
                            }
                        } label: {
                            Label("Destination", systemImage: "folder.fill")
                                .labelStyle(.titleAndIcon)
                                .frame(minWidth: 120)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isDownloading)
                    }

                    if let destinationFolder = destinationFolder {
                        Label(destinationFolder.path, systemImage: "externaldrive")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.top, -4)
                    }

                    if isDownloading {
                                            Button {
                                                cancelDownload = true
                                                progressText = "Cancelling Checker..."
                                            } label: {
                                                Label("Stop Checker", systemImage: "stop.fill")
                                                    .labelStyle(.titleAndIcon)
                                                    .frame(minWidth: 120)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(.red)
                                            .controlSize(.large)
                                        } else {
                                            Button {
                                                guard let csv = csvURL, let folder = destinationFolder else { return }
                                                isDownloading = true
                                                cancelDownload = false
                                                progressText = "Starting Checker..."
                                                imagesChecked = 0
                                                totalImages = 0

                                                Task {
                                                    await downloadImagesAsync(
                                                        fromCSV: csv,
                                                        to: folder,
                                                        update: { message, checked, total in
                                                            maybeUpdateUI(message: message, checked: checked, total: total)
                                                        },
                                                        cancelled: { cancelDownload }
                                                    )
                                                    isDownloading = false
                                                    if cancelDownload {
                                                        progressText = "Checker Stopped."
                                                    } else {
                                                        downloadComplete = true
                                                    }
                                                }
                                            } label: {
                                                Label("Start Checker", systemImage: "arrow.down.circle.fill")
                                                    .labelStyle(.titleAndIcon)
                                                    .frame(minWidth: 140)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(.blue)
                                            .controlSize(.large)
                                            .disabled(isDownloading || csvURL == nil || destinationFolder == nil)
                                        }

                    if isDownloading && totalImages > 0 {
                        VStack(spacing: 8) {
                            ProgressView(value: Double(imagesChecked), total: Double(totalImages))
                                .progressViewStyle(.linear)
                                .accentColor(.blue)
                                .frame(maxWidth: .infinity)
                            HStack {
                                Text("Processed")
                                Text("\(imagesChecked)")
                                    .font(.system(.body, design: .monospaced))
                                Text("of \(totalImages) images")
                                Spacer()
                                Text("\(progressPercent)%")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .font(.caption)
                        }
                        .padding([.leading, .trailing])
                    }

                    if isDownloading || !progressText.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: isDownloading ? "hourglass" : "checkmark.seal.fill")
                                .foregroundColor(isDownloading ? .accentColor : .green)
                            Text(progressText)
                                .font(.callout)
                        }
                        .padding(.top, 2)
                        .transition(.opacity)
                    }

                    if isDownloading {
                        AnimatedGIFView(gifName: "loading", width: 220, height: 220)
                            .frame(width: 220, height: 220)
                            .padding(.top, 8)
                    }
                }
                .padding(28)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 8)

                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .frame(width: 600, height: 700)
        .alert(isPresented: $downloadComplete) {
            Alert(
                title: Text("Checker Complete"),
                message: Text("All visually matching images have been downloaded."),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    func maybeUpdateUI(message: String, checked: Int, total: Int) {
        // Update UI on every image for more accurate progress
        progressText = message
        imagesChecked = checked
        totalImages = total
    }

    var progressPercent: Int {
        guard totalImages > 0 else { return 0 }
        return Int((Double(imagesChecked) / Double(totalImages)) * 100)
    }

    func openFileDialog(allowedTypes: [String]) -> URL? {
        let panel = NSOpenPanel()
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = allowedTypes.compactMap { UTType(filenameExtension: $0) }
        } else {
            panel.allowedFileTypes = allowedTypes
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func openFolderDialog() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func downloadImagesAsync(
        fromCSV csvURL: URL,
        to destination: URL,
        update: @escaping (String, Int, Int) -> Void,
        cancelled: @escaping () -> Bool
    ) async {
        guard let content = try? String(contentsOf: csvURL) else {
            await MainActor.run { update("Failed to read CSV file.", 0, 0) }
            return
        }
        guard let referenceImage = NSImage(named: "ReferenceImage"),
              let referenceCGImage = referenceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            await MainActor.run { update("Reference image not found in assets. Check Assets.xcassets for 'ReferenceImage'!", 0, 0) }
            return
        }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count > 1 else {
            await MainActor.run { update("CSV has no data rows.", 0, 0) }
            return
        }

        let urlIndex = 1
        let imageLines = Array(lines.dropFirst())
        let total = imageLines.count

        await MainActor.run {
            update("Preparing to download...", 0, total)
        }

        let checkedCounter = AtomicInt()
        let matchedCounter = AtomicInt()

        await withTaskGroup(of: Void.self) { group in
            for line in imageLines {
                if cancelled() { break }
                group.addTask {
                    if cancelled() { return }
                    let columns = line.components(separatedBy: ",")
                    guard columns.indices.contains(urlIndex) else { return }

                    let urlString = columns[urlIndex].replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                    guard let url = URL(string: urlString) else { return }

                    do {
                        if cancelled() { return }
                        let (data, _) = try await URLSession.shared.data(from: url)
                        if cancelled() { return }
                        guard let downloadedImage = NSImage(data: data),
                              let downloadedCGImage = downloadedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                            return
                        }
                        if cancelled() { return }
                        let similarity = tinyThumbnailSimilarity(downloadedCGImage, referenceCGImage, thumbSize: 8)
                        if cancelled() { return }
                        if similarity >= 0.90 {
                            var fileName = url.lastPathComponent.components(separatedBy: "?").first ?? "image_\(UUID().uuidString).jpg"
                            fileName = fileName.replacingOccurrences(of: "[^a-zA-Z0-9_.-]", with: "_", options: .regularExpression)
                            if !fileName.hasSuffix(".jpg") && !fileName.hasSuffix(".jpeg") && !fileName.hasSuffix(".png") {
                                fileName += ".jpg"
                            }
                            let destinationURL = destination.appendingPathComponent(fileName)
                            try? data.write(to: destinationURL)
                            if cancelled() { return }
                            _ = await matchedCounter.increment()
                        }
                    } catch {
                        // Ignore errors, just continue
                    }
                    let checked = await checkedCounter.increment()
                    // Always update UI on every image
                    await MainActor.run {
                        update("Processed \(checked) of \(total) images...", checked, total)
                    }
                }
            }
        }

        let checked = await checkedCounter.get()
        let matched = await matchedCounter.get()

        await MainActor.run {
            update("Downloaded \(matched) matching images out of \(checked).", checked, total)
        }
    }
}

// You still need your own implementation of tinyThumbnailSimilarity elsewhere!
