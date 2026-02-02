import SwiftUI
import AppKit

struct ImageRow: View {
    let record: Scene7ImageRecord
    let onRemove: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isLoadingThumbnail = false

    var isError: Bool {
        record.status == .error
    }
    
    var isVirtualCheck: Bool {
        record.localURL.path.contains("/virtual/")
    }
    
    var hasIssues: Bool {
        isError || record.expandedCheckIssue != nil || record.swatchValidationIssue != nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 14) {
                // Lazy thumbnail loading or virtual indicator
                Group {
                    if isVirtualCheck {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.blue.opacity(0.1))
                                .frame(width: 44, height: 44)
                            Image(systemName: "cloud.fill")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 24, height: 24)
                                .foregroundColor(.blue)
                        }
                    } else if let thumbnail = thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 44, height: 44)
                            .cornerRadius(6)
                            .shadow(radius: 1)
                    } else if isLoadingThumbnail {
                        ProgressView()
                            .frame(width: 44, height: 44)
                            .cornerRadius(6)
                    } else {
                        Image(systemName: "photo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 38, height: 38)
                            .foregroundColor(.gray)
                            .background(Color(.controlBackgroundColor))
                            .cornerRadius(6)
                    }
                }
                .onAppear {
                    if !isVirtualCheck {
                        loadThumbnailIfNeeded()
                    }
                }
                
                VStack(alignment: .leading, spacing: 6) { // Increased spacing from 4 to 6
                    SelectableText(text: record.filename)
                    
                    // Show virtual check indicator
                    if isVirtualCheck {
                        HStack(spacing: 6) {
                            Image(systemName: "cloud.fill")
                                .foregroundColor(.blue)
                                .font(.body) // Increased from caption2
                            Text("Scene7 Check Only")
                                .font(.body) // Increased from caption2
                                .foregroundColor(.blue)
                                .fontWeight(.medium) // Added weight
                                .italic()
                        }
                    }
                    
                    // Show status text for exists and error status only - MADE BIGGER AND MORE PROMINENT
                    if record.status == .exists {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title3) // Increased from caption
                            Text("Image Found on Scene7")
                                .font(.title3) // Increased from caption
                                .foregroundColor(.primary)
                                .fontWeight(.bold) // Increased from medium
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(6)
                    } else if record.status == .error {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.title3) // Increased from caption
                            Text("Image Not Found")
                                .font(.title3) // Increased from caption
                                .foregroundColor(.red) // Changed to red for better visibility
                                .fontWeight(.bold) // Increased from medium
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.15))
                        .cornerRadius(6)
                    }
                    
                    // Show naming warning if present - MADE BIGGER
                    if let warning = record.namingWarning {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.body) // Increased from caption2
                            Text(warning)
                                .font(.body) // Increased from caption2
                                .foregroundColor(.orange)
                                .fontWeight(.bold) // Increased from medium
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(6)
                    }
                    
                    // Legacy swatch validation issue (keeping for backward compatibility) - MADE BIGGER
                    if let swatchIssue = record.swatchValidationIssue {
                        HStack(spacing: 6) {
                            Image(systemName: "paintbrush.fill")
                                .foregroundColor(.orange)
                                .font(.body) // Increased from caption2
                            Text(swatchIssue)
                                .font(.body) // Increased from caption2
                                .foregroundColor(.orange)
                                .fontWeight(.bold) // Increased from medium
                                .italic()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(6)
                    }
                    
                    // NEW: Show expanded check issue if present - MADE MUCH MORE PROMINENT
                    if let expandedIssue = record.expandedCheckIssue {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.purple)
                                .font(.title3) // Increased from caption2
                            Text(expandedIssue)
                                .font(.title3) // Increased from caption2
                                .foregroundColor(.purple)
                                .fontWeight(.bold) // Increased from medium
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.purple.opacity(0.15))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.purple.opacity(0.4), lineWidth: 1)
                        )
                    }
                }
                Spacer()
                statusBadge(for: record)
            }
            .padding(.vertical, 14) // Increased from 12
            .padding(.horizontal, 12)
            .background(backgroundColorForRecord())
            
            // Remove button in upper left corner (don't show for virtual checks)
            if !isVirtualCheck {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .foregroundColor(.gray)
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.gray.opacity(0.2)))
                        .background(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Remove this file from the list")
                .offset(x: 4, y: 4)
            }
        }
    }
    
    // Determine background color based on record state
    private func backgroundColorForRecord() -> Color {
        if isError {
            return Color.red.opacity(0.10)
        } else if record.expandedCheckIssue != nil {
            return Color.purple.opacity(0.10)
        } else if record.swatchValidationIssue != nil {
            return Color.orange.opacity(0.10)
        } else {
            return Color.clear
        }
    }
    
    private func loadThumbnailIfNeeded() {
        guard thumbnail == nil && !isLoadingThumbnail && !isVirtualCheck else { return }
        
        isLoadingThumbnail = true
        
        // Use DispatchQueue to avoid Sendable issues with NSImage
        DispatchQueue.global(qos: .utility).async {
            let loadedThumbnail = self.createThumbnail(for: self.record.localURL)
            
            DispatchQueue.main.async {
                self.thumbnail = loadedThumbnail
                self.isLoadingThumbnail = false
            }
        }
    }
    
    private func createThumbnail(for url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let targetSize = NSSize(width: 44, height: 44)
        
        let thumbnail = NSImage(size: targetSize, flipped: false) { rect in
            image.draw(in: rect, from: NSRect(origin: .zero, size: image.size),
                      operation: .copy, fraction: 1.0)
            return true
        }
        
        return thumbnail
    }

    func statusBadge(for record: Scene7ImageRecord) -> some View {
        switch record.status {
        case .notChecked:
            return Label("Not checked", systemImage: "questionmark.circle")
                .labelStyle(.iconOnly)
                .foregroundColor(.gray)
                .font(.system(size: 24))
        case .exists:
            return Label("Exists", systemImage: "checkmark.seal.fill")
                .labelStyle(.iconOnly)
                .foregroundColor(.green)
                .font(.system(size: 28))
        case .error:
            return Label("Error", systemImage: "xmark.octagon.fill")
                .labelStyle(.iconOnly)
                .foregroundColor(.red)
                .font(.system(size: 24))
        case .unique:
            return Label("Unique", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundColor(.blue)
                .font(.system(size: 24))
        }
    }
}

struct SelectableText: NSViewRepresentable {
    let text: String
    
    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.stringValue = text
        textField.isEditable = false
        textField.isSelectable = true
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        textField.textColor = NSColor.labelColor
        return textField
    }
    
    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
    }
}
