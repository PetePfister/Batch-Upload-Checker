import SwiftUI
import UniformTypeIdentifiers
import AppKit
import CryptoKit
import WebKit

struct BatchUploadCheckerView: View {
    @StateObject private var viewModel = Scene7CheckerLogic()
    @StateObject private var batchProcessor = BatchProcessorViewModel()
    @State private var dropIsTargeted = false
    @State private var showErrorsOnly = false
    @State private var showSwatchIssuesOnly = false // Legacy swatch validation issues
    @State private var showExpandedIssuesOnly = false // Toggle for expanded check issues - NOW ALWAYS VISIBLE
    @State private var isChecking = false
    @State private var checkingProgress = 0.0
    @State private var checkedCount = 0
    @State private var totalToCheck = 0
    @State private var showingClearAllAlert = false
    @State private var isImporting = false
    @State private var importProgress = 0.0
    @State private var importedCount = 0
    @State private var totalToImport = 0
    @State private var progressTimer: Timer? // For cancelling progress updates
    
    // EA Batch Complete integration
    @State private var showingWebView = false // Show on startup for initial auth
    @State private var showingEAItemsDialog = false
    @State private var eaItemNumbers = "" // For manual EA item entry
    @State private var backgroundWebView: BackgroundWebView? // Background WebView for SharePoint
    @State private var isInitialAuthComplete = false // Track if user has authenticated

    var hasCompletedCheck: Bool {
        !viewModel.records.isEmpty && viewModel.records.allSatisfy { $0.status != .notChecked }
    }
    
    var hasMatchingImages: Bool {
        viewModel.records.contains { $0.status == .exists }
    }
    
    var hasSwatchValidationIssues: Bool {
        viewModel.records.contains { $0.swatchValidationIssue != nil }
    }
    
    // REMOVED: No longer needed since we always show the toggle and count
    // var hasExpandedCheckIssues: Bool {
    //     viewModel.records.contains { $0.expandedCheckIssue != nil }
    // }
    
    var isAnyOperationRunning: Bool {
        isImporting || isChecking || viewModel.isLoading || batchProcessor.isProcessing
    }
    
    var matchingItemNumbers: [String] {
        let matchingRecords = viewModel.records.filter { $0.status == .exists }
        var itemNumbers: Set<String> = []
        
        for record in matchingRecords {
            if let itemNumber = extractQVCItemNumber(from: record.filename) {
                itemNumbers.insert(itemNumber)
            }
        }
        
        return Array(itemNumbers).sorted()
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Batch Upload Checker + EA Batch Complete")
                .font(.largeTitle.bold())
                .foregroundColor(.accentColor)
                .padding(.top, 8)

            HStack(spacing: 10) {
                ButtonWithTooltip(
                    title: "Import Images/Folders",
                    tooltip: "Select image files or folders to import for Scene7 checking. Supports drag & drop and recursive folder scanning.",
                    isProminent: viewModel.records.isEmpty,
                    isDisabled: isAnyOperationRunning
                ) {
                    importFilesDialog()
                }

                ButtonWithTooltip(
                    title: "Run Checker",
                    tooltip: "Check all imported images against Scene7 database. Validates existence, checks swatch pairs, and identifies missing components.",
                    isProminent: false,
                    isDisabled: viewModel.records.isEmpty || isAnyOperationRunning
                ) {
                    checkAllImagesWithProgress()
                }

                // EA Batch Complete button - shows auth window on first use, then runs in background
                ButtonWithTooltip(
                    title: "EA Batch Complete",
                    tooltip: isInitialAuthComplete ? "Automatically update SharePoint builds to 'Completed' status for all loaded images. Runs in background." : "Automatically update SharePoint builds to 'Completed' status for all loaded images. Will show authentication window on first use.",
                    isProminent: false,
                    tintColor: .green,
                    isDisabled: isAnyOperationRunning
                ) {
                    startEABatchComplete()
                }

                // Stop button - only show when operations are running
                if isAnyOperationRunning {
                    ButtonWithTooltip(
                        title: "Stop",
                        tooltip: "Cancel all currently running operations (import, checking, or SharePoint processing).",
                        isProminent: false,
                        tintColor: .red,
                        isDisabled: false
                    ) {
                        stopAllOperations()
                    }
                }

                ButtonWithTooltip(
                    title: "Clear All",
                    tooltip: "Remove all imported files from the list. This will not delete files from disk, only clear the current session.",
                    isProminent: false,
                    tintColor: .red,
                    isDisabled: viewModel.records.isEmpty || isAnyOperationRunning
                ) {
                    showingClearAllAlert = true
                }
            }

            // Filter toggles with tooltips - UPDATED: Always show all three toggles
            HStack(spacing: 20) {
                ToggleWithTooltip(
                    title: "Show Only Errors",
                    tooltip: "Filter to display only images that were not found on Scene7 or had checking errors.",
                    isOn: $showErrorsOnly,
                    isDisabled: viewModel.records.isEmpty || isAnyOperationRunning
                )
                
                // Legacy swatch validation issues toggle - only show if there are issues
                if hasSwatchValidationIssues {
                    ToggleWithTooltip(
                        title: "Show Only Swatch Issues",
                        tooltip: "Filter to display only images with swatch validation problems (legacy feature).",
                        isOn: $showSwatchIssuesOnly,
                        isDisabled: viewModel.records.isEmpty || isAnyOperationRunning
                    )
                }
                
                // UPDATED: Always show Missing Items toggle (not conditional anymore)
                ToggleWithTooltip(
                    title: "Show Only Missing Items",
                    tooltip: "Filter to display only images where companion files (swatch pairs, main images) are missing and need to be uploaded.",
                    isOn: $showExpandedIssuesOnly,
                    isDisabled: viewModel.records.isEmpty || isAnyOperationRunning
                )
                
                Spacer()
            }
            .padding(.horizontal, 18)

            // Import progress
            if isImporting {
                VStack(spacing: 8) {
                    ProgressView("Importing files...", value: importProgress, total: 1.0)
                    Text("Imported \(importedCount) of \(totalToImport) files")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            }

            // Checking progress
            if isChecking || viewModel.isLoading {
                VStack(spacing: 8) {
                    ProgressView("Checking images...", value: checkingProgress, total: 1.0)
                    HStack {
                        Text("Checked \(checkedCount) of \(totalToCheck) images")
                        Spacer()
                        Text("\(Int(checkingProgress * 100))%")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            }

            // EA Batch Complete progress
            if batchProcessor.isProcessing {
                VStack(spacing: 8) {
                    ProgressView("Processing SharePoint builds...", value: batchProcessor.progress, total: 1.0)
                    HStack {
                        Text(batchProcessor.currentStep)
                        Spacer()
                        Text("\(Int(batchProcessor.progress * 100))%")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            }

            // UPDATED: Results summary after checking - Always show Missing Items count
            if hasCompletedCheck {
                HStack(spacing: 20) {
                    VStack {
                        Text("\(viewModel.records.filter { $0.status == .exists }.count)")
                            .font(.title2.bold())
                            .foregroundColor(.green)
                        Text("Found on Scene7")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack {
                        Text("\(viewModel.records.filter { $0.status == .error }.count)")
                            .font(.title2.bold())
                            .foregroundColor(.red)
                        Text("Not Found/Errors")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Legacy swatch validation issues - only show if there are issues
                    if hasSwatchValidationIssues {
                        VStack {
                            Text("\(viewModel.records.filter { $0.swatchValidationIssue != nil }.count)")
                                .font(.title2.bold())
                                .foregroundColor(.orange)
                            Text("Swatch Issues")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // UPDATED: Always show Missing Items count (even if 0)
                    VStack {
                        Text("\(viewModel.records.filter { $0.expandedCheckIssue != nil }.count)")
                            .font(.title2.bold())
                            .foregroundColor(.purple)
                        Text("Missing Items")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if hasMatchingImages {
                        VStack {
                            Text("\(matchingItemNumbers.count)")
                                .font(.title2.bold())
                                .foregroundColor(.blue)
                            Text("Item Numbers")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(10)
            }

            // EA Batch Complete status section
            if !batchProcessor.processedItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SharePoint Build Status")
                        .font(.headline)
                    
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(batchProcessor.processedItems.indices, id: \.self) { index in
                                eaBatchStatusRow(for: batchProcessor.processedItems[index])
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
                }
            }

            if viewModel.records.isEmpty && !isImporting {
                DropzoneEmptyView(dropIsTargeted: $dropIsTargeted) { providers in
                    handleDrop(providers: providers)
                }
                .frame(maxHeight: 200)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredRecords.enumerated()), id: \.element.id) { _, record in
                            VStack(spacing: 0) {
                                ImageRow(record: record) {
                                    removeRecord(record)
                                }
                                if record.id != filteredRecords.last?.id {
                                    Divider()
                                        .background(Color.gray.opacity(0.3))
                                        .padding(.horizontal, 12)
                                }
                            }
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.windowBackgroundColor)))
                .padding(.vertical, 8)
            }

            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .foregroundColor(.red)
                }
                .padding(.top, 8)
            }

            Spacer()
        }
        .padding(24)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropIsTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .frame(minWidth: 600, minHeight: 700)
        .sheet(isPresented: $showingWebView) {
            InitialAuthWebViewContainer(viewModel: batchProcessor) {
                // Called when initial auth is complete
                isInitialAuthComplete = true
                showingWebView = false
                setupBackgroundWebView()
            }
        }
        .sheet(isPresented: $showingEAItemsDialog) {
            EAItemNumbersDialog(
                itemNumbers: $eaItemNumbers,
                onProcess: { items in
                    Task {
                        await batchProcessor.processItems(items)
                    }
                    showingEAItemsDialog = false
                },
                onCancel: {
                    showingEAItemsDialog = false
                }
            )
        }
        .alert("Clear All Files", isPresented: $showingClearAllAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                viewModel.clearAllFiles()
                batchProcessor.reset()
            }
        } message: {
            Text("Are you sure you want to remove all files from the list? This action cannot be undone.")
        }
        .alert("EA Batch Processing Complete", isPresented: $batchProcessor.showCompletionDialog) {
            Button("Copy Results") {
                copyEAResultsToClipboard()
                batchProcessor.showCompletionDialog = false
            }
            Button("OK") {
                batchProcessor.showCompletionDialog = false
            }
        } message: {
            Text(batchProcessor.completionMessage)
        }
        .onAppear {
            // Show WebView on first load for SharePoint authentication
            if !isInitialAuthComplete {
                showingWebView = true
            }
        }
        .onChange(of: showErrorsOnly) { newValue in
            if newValue {
                showSwatchIssuesOnly = false
                showExpandedIssuesOnly = false
            }
        }
        .onChange(of: showSwatchIssuesOnly) { newValue in
            if newValue {
                showErrorsOnly = false
                showExpandedIssuesOnly = false
            }
        }
        .onChange(of: showExpandedIssuesOnly) { newValue in
            if newValue {
                showErrorsOnly = false
                showSwatchIssuesOnly = false
            }
        }
        .onChange(of: viewModel.isLoading) { newValue in
            if !newValue {
                // When Scene7 checking completes, reset our progress state
                isChecking = false
                checkingProgress = 1.0
                checkedCount = totalToCheck
                progressTimer?.invalidate()
                progressTimer = nil
            }
        }
    }

    // MARK: - Background WebView Setup
    
    func setupBackgroundWebView() {
        // Create background WebView for SharePoint authentication (after initial auth)
        backgroundWebView = BackgroundWebView(viewModel: batchProcessor)
    }

    // MARK: - Stop Operations Function
    
    func stopAllOperations() {
        // Stop checking operations
        if isChecking || viewModel.isLoading {
            viewModel.cancelChecking()
            isChecking = false
            progressTimer?.invalidate()
            progressTimer = nil
        }
        
        // Stop import operations
        if isImporting {
            isImporting = false
            // Import operations are harder to cancel mid-stream, but we can reset the UI
        }
        
        // Stop EA Batch Complete operations
        if batchProcessor.isProcessing {
            batchProcessor.cancelProcessing()
        }
        
        // Reset all progress states
        checkingProgress = 0.0
        checkedCount = 0
        importProgress = 0.0
        importedCount = 0
    }

    // MARK: - EA Batch Complete Functions
    
    func startEABatchComplete() {
        // First, try to extract item numbers from ANY loaded images (checked or not)
        var itemNumbers: Set<String> = []
        
        for record in viewModel.records {
            if let itemNumber = extractQVCItemNumber(from: record.filename) {
                itemNumbers.insert(itemNumber)
            }
        }
        
        let sortedItemNumbers = Array(itemNumbers).sorted()
        
        // If we have any item numbers from loaded images, use those
        if !sortedItemNumbers.isEmpty {
            // Check if user has completed initial authentication
            if !isInitialAuthComplete {
                // Show authentication window first
                showingWebView = true
                // Store the item numbers to process after auth
                Task {
                    // Wait for auth to complete, then process
                    while !isInitialAuthComplete {
                        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                    }
                    // Small additional delay to ensure background WebView is ready
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    await batchProcessor.processItems(sortedItemNumbers)
                }
            } else {
                // Already authenticated, use background WebView
                Task {
                    // Small delay to ensure WebView is ready
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                    await batchProcessor.processItems(sortedItemNumbers)
                }
            }
        } else {
            // No images loaded at all, show manual entry dialog
            showingEAItemsDialog = true
        }
    }
    
    func copyEAResultsToClipboard() {
        let results = batchProcessor.processedItems.map { "\($0.itemNumber): \($0.status.description)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(results, forType: .string)
    }
    
    func eaBatchStatusRow(for item: ProcessedItem) -> some View {
        HStack {
            Image(systemName: item.status.iconName)
                .foregroundColor(item.status.color)
                .frame(width: 20)
            
            Text(item.itemNumber)
                .font(.system(.body, design: .monospaced))
                .fontWeight(item.status == .completed ? .medium : .regular)
            
            Text("-")
                .foregroundColor(.secondary)
            
            Text(item.status.description)
                .foregroundColor(item.status.color)
                .fontWeight(item.status == .completed ? .medium : .regular)
            
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            item.status == .completed ? Color.green.opacity(0.05) :
            item.status == .notFound || item.status == .updateFailed || item.status == .saveFailed ? Color.red.opacity(0.05) : Color.clear
        )
        .cornerRadius(4)
    }
    
    // Extract QVC item number from filename using various patterns
    private func extractQVCItemNumber(from filename: String) -> String? {
        let baseFilename = (filename as NSString).deletingPathExtension
        
        // Pattern 1: Item_slot format (A709346_001)
        let pattern1 = #"^([A-Za-z]+\d+)_\d{3}$"#
        if let regex1 = try? NSRegularExpression(pattern: pattern1, options: []) {
            let range = NSRange(location: 0, length: baseFilename.utf16.count)
            if let match = regex1.firstMatch(in: baseFilename, options: [], range: range) {
                if match.numberOfRanges > 1 {
                    let capturedRange = match.range(at: 1)
                    if let swiftRange = Range(capturedRange, in: baseFilename) {
                        let itemNumber = String(baseFilename[swiftRange])
                        return itemNumber.uppercased()
                    }
                }
            }
        }
        
        // Pattern 2: Item.slot format (A709346.001)
        let pattern2 = #"^([A-Za-z]+\d+)\.\d{3}$"#
        if let regex2 = try? NSRegularExpression(pattern: pattern2, options: []) {
            let range = NSRange(location: 0, length: baseFilename.utf16.count)
            if let match = regex2.firstMatch(in: baseFilename, options: [], range: range) {
                if match.numberOfRanges > 1 {
                    let capturedRange = match.range(at: 1)
                    if let swiftRange = Range(capturedRange, in: baseFilename) {
                        let itemNumber = String(baseFilename[swiftRange])
                        return itemNumber.uppercased()
                    }
                }
            }
        }
        
        // Pattern 3: Item_color_slot format (A709346_RED_101)
        let pattern3 = #"^([A-Za-z]+\d+)_[A-Za-z0-9]+_\d{3}$"#
        if let regex3 = try? NSRegularExpression(pattern: pattern3, options: []) {
            let range = NSRange(location: 0, length: baseFilename.utf16.count)
            if let match = regex3.firstMatch(in: baseFilename, options: [], range: range) {
                if match.numberOfRanges > 1 {
                    let capturedRange = match.range(at: 1)
                    if let swiftRange = Range(capturedRange, in: baseFilename) {
                        let itemNumber = String(baseFilename[swiftRange])
                        return itemNumber.uppercased()
                    }
                }
            }
        }
        
        // Pattern 4: Item_color.slot format (A709346_RED.101)
        let pattern4 = #"^([A-Za-z]+\d+)_[A-Za-z0-9]+\.\d{3}$"#
        if let regex4 = try? NSRegularExpression(pattern: pattern4, options: []) {
            let range = NSRange(location: 0, length: baseFilename.utf16.count)
            if let match = regex4.firstMatch(in: baseFilename, options: [], range: range) {
                if match.numberOfRanges > 1 {
                    let capturedRange = match.range(at: 1)
                    if let swiftRange = Range(capturedRange, in: baseFilename) {
                        let itemNumber = String(baseFilename[swiftRange])
                        return itemNumber.uppercased()
                    }
                }
            }
        }
        
        // Pattern 5: Just the item number (A709346)
        let pattern5 = #"^[A-Za-z]+\d+$"#
        if let regex5 = try? NSRegularExpression(pattern: pattern5, options: []) {
            let range = NSRange(location: 0, length: baseFilename.utf16.count)
            if regex5.firstMatch(in: baseFilename, options: [], range: range) != nil {
                if baseFilename.count >= 6 {
                    return baseFilename.uppercased()
                }
            }
        }
        
        return nil
    }

    // MARK: - Scene7 Checker Functions (keeping all existing functionality)
    
    var filteredRecords: [Scene7ImageRecord] {
        if showErrorsOnly {
            return viewModel.records.filter { $0.status == .error }
        } else if showSwatchIssuesOnly {
            return viewModel.records.filter { $0.swatchValidationIssue != nil }
        } else if showExpandedIssuesOnly {
            return viewModel.records.filter { $0.expandedCheckIssue != nil }
        } else {
            return viewModel.records
        }
    }

    func importFilesDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "Select Images or Folders"
        if panel.runModal() == .OK {
            importFilesAsync(from: panel.urls)
        }
    }

    func handleDrop(providers: [NSItemProvider]) {
        let providerCount = providers.count
        guard providerCount > 0 else { return }
        
        isImporting = true
        importedCount = 0
        totalToImport = providerCount
        importProgress = 0.0
        
        var urls: [URL] = []
        let dispatchGroup = DispatchGroup()
        
        for provider in providers {
            dispatchGroup.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer {
                    dispatchGroup.leave()
                    DispatchQueue.main.async {
                        self.importedCount += 1
                        self.importProgress = Double(self.importedCount) / Double(self.totalToImport)
                    }
                }
                
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            importFilesAsync(from: urls)
        }
    }

    func importFilesAsync(from urls: [URL]) {
        if !isImporting {
            isImporting = true
            importedCount = 0
            totalToImport = 0
            importProgress = 0.0
        }
        
        Task {
            // First, collect all file URLs with progress updates
            let allFiles = await collectFileURLsWithProgress(from: urls)
            let imageFiles = allFiles.filter { url in
                let ext = url.pathExtension.lowercased()
                return viewModel.imageExtensions.contains(ext)
            }
            
            await MainActor.run {
                totalToImport = imageFiles.count
                importedCount = 0
                importProgress = 0.0
            }
            
            // Process files in smaller batches for more responsive progress
            let batchSize = 10
            var processedRecords: [Scene7ImageRecord] = []
            
            for batch in imageFiles.chunked(into: batchSize) {
                let batchRecords = await processBatch(batch)
                processedRecords.append(contentsOf: batchRecords)
                
                await MainActor.run {
                    importedCount = min(processedRecords.count, totalToImport)
                    importProgress = Double(importedCount) / Double(max(totalToImport, 1))
                    
                    // Update the view model with new records incrementally
                    viewModel.records = processedRecords
                }
                
                // Very small delay to keep UI responsive
                try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
            }
            
            await MainActor.run {
                isImporting = false
                viewModel.errorMessage = processedRecords.isEmpty ? "No image files found in selection." : nil
            }
        }
    }
    
    func collectFileURLsWithProgress(from urls: [URL]) async -> [URL] {
        var allFiles: [URL] = []
        var processedCount = 0
        
        for url in urls {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            
            if exists {
                if isDir.boolValue {
                    // Process directories
                    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                        for case let fileURL as URL in enumerator {
                            var isFileDir: ObjCBool = false
                            let subExists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isFileDir)
                            if subExists && !isFileDir.boolValue {
                                allFiles.append(fileURL)
                            }
                        }
                    }
                } else {
                    allFiles.append(url)
                }
            }
            
            processedCount += 1
            await MainActor.run {
                importedCount = processedCount
                importProgress = Double(processedCount) / Double(urls.count)
            }
        }
        
        return allFiles
    }
    
    func processBatch(_ urls: [URL]) async -> [Scene7ImageRecord] {
        var results: [Scene7ImageRecord] = []
        
        // Process each URL
        for url in urls {
            let filename = url.lastPathComponent
            let normalized = Scene7CheckerLogic.defaultUnderscoreSlotFilename(for: filename)
            let scene7url = Scene7CheckerLogic.scene7URL(for: normalized)
            let warning = viewModel.checkNamingConvention(filename: filename)
            
            let record = Scene7ImageRecord(
                localURL: url,
                proposedName: filename,
                scene7URL: scene7url,
                status: .notChecked,
                md5Hash: nil,
                isDuplicate: false,
                renameError: nil,
                namingWarning: warning,
                thumbnail: nil, // Will be loaded lazily
                usedDetailSlots: nil,
                availableDetailSlots: nil,
                detailSlotChecked: false,
                swatchValidationIssue: nil,
                expandedCheckIssue: nil
            )
            results.append(record)
        }
        
        return results.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }

    // Properly coordinate progress between ContentView and viewModel
    func checkAllImagesWithProgress() {
        isChecking = true
        checkedCount = 0
        totalToCheck = viewModel.records.count
        checkingProgress = 0.0
        
        // Start checking with progress updates
        Task {
            // Call the Scene7 checker with swatch validation (now properly async)
            await viewModel.checkAllImagesWithSwatchValidation()
            
            // Update progress as checking completes
            await MainActor.run {
                self.isChecking = false
                self.checkingProgress = 1.0
                self.checkedCount = self.totalToCheck
                self.progressTimer?.invalidate()
                self.progressTimer = nil
            }
        }
        
        // Optional: Add a timer to simulate progress updates if needed
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if !isChecking && !viewModel.isLoading {
                timer.invalidate()
                progressTimer = nil
            } else if viewModel.isLoading {
                // Estimate progress based on processing time
                let estimatedProgress = min(0.9, checkingProgress + 0.02)
                checkingProgress = estimatedProgress
                checkedCount = Int(Double(totalToCheck) * estimatedProgress)
            }
        }
    }

    func removeRecord(_ record: Scene7ImageRecord) {
        withAnimation(.easeInOut(duration: 0.3)) {
            if let index = viewModel.records.firstIndex(where: { $0.id == record.id }) {
                viewModel.records.remove(at: index)
            }
        }
    }
}

// MARK: - Initial Authentication WebView Container

struct InitialAuthWebViewContainer: View {
    let viewModel: BatchProcessorViewModel
    let onAuthComplete: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("SharePoint Authentication")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    onAuthComplete()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            
            Text("Please log in to SharePoint to enable EA Batch Complete functionality.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            WebViewRepresentable(viewModel: viewModel)
        }
        .frame(width: 800, height: 600)
    }
}

// MARK: - WebView Representable for Initial Auth

struct WebViewRepresentable: NSViewRepresentable {
    let viewModel: BatchProcessorViewModel
    
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        
        // Set the webView on the main actor
        Task { @MainActor in
            viewModel.webView = webView
        }
        
        // Load SharePoint page
        if let url = URL(string: "https://sharepoint.qvcdev.qvc.net/Teams/DistSiteQuality/SitePages/Builds.aspx") {
            webView.load(URLRequest(url: url))
        }
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No updates needed
    }
}

// MARK: - Background WebView for SharePoint Authentication (for subsequent operations)

class BackgroundWebView: NSObject, WKNavigationDelegate {
    private var webView: WKWebView
    private var viewModel: BatchProcessorViewModel
    
    init(viewModel: BatchProcessorViewModel) {
        self.viewModel = viewModel
        
        // Create WebView with configuration
        let configuration = WKWebViewConfiguration()
        self.webView = WKWebView(frame: CGRect.zero, configuration: configuration)
        
        super.init()
        
        // Set up WebView
        self.webView.navigationDelegate = self
        
        // Set the webView on the main actor
        Task { @MainActor in
            self.viewModel.webView = self.webView
        }
        
        // Load SharePoint page for authentication
        if let url = URL(string: "https://sharepoint.qvcdev.qvc.net/Teams/DistSiteQuality/SitePages/Builds.aspx") {
            self.webView.load(URLRequest(url: url))
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            viewModel.webViewDidFinishLoading()
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("Background WebView navigation failed: \(error.localizedDescription)")
    }
}

// MARK: - EA Item Numbers Dialog

struct EAItemNumbersDialog: View {
    @Binding var itemNumbers: String
    let onProcess: ([String]) -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("EA Batch Complete - Manual Entry")
                .font(.headline)
            
            Text("Enter item numbers (one per line) to mark as completed in SharePoint:")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            TextEditor(text: $itemNumbers)
                .frame(minHeight: 150)
                .padding(8)
                .background(Color(.textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .font(.system(.body, design: .monospaced))
            
            if itemNumbers.isEmpty {
                Text("Example:\nA123456\nB789012\nC345678")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            } else {
                let count = itemNumbers.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.count
                
                Text("\(count) item numbers entered")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button("Process Items") {
                    let items = itemNumbers
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    
                    onProcess(items)
                }
                .buttonStyle(.borderedProminent)
                .disabled(itemNumbers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 400, height: 350)
    }
}

// MARK: - Custom Button Component with Tooltip

struct ButtonWithTooltip: View {
    let title: String
    let tooltip: String
    let isProminent: Bool
    var tintColor: Color = .accentColor
    let isDisabled: Bool
    let action: () -> Void
    
    var body: some View {
        HStack(spacing: 4) {
            Button(title) {
                action()
            }
            .if(isProminent) { view in
                view.buttonStyle(BorderedProminentButtonStyle())
            }
            .if(!isProminent) { view in
                view.buttonStyle(BorderedButtonStyle())
            }
            .tint(tintColor)
            .disabled(isDisabled)
            
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundColor(.secondary)
                .help(tooltip)
        }
    }
}

// MARK: - Custom Toggle Component with Tooltip

struct ToggleWithTooltip: View {
    let title: String
    let tooltip: String
    @Binding var isOn: Bool
    let isDisabled: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(SwitchToggleStyle())
                .disabled(isDisabled)
            
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundColor(.secondary)
                .help(tooltip)
        }
    }
}

// Thread-safe actors for managing shared state
actor CheckingProgressActor {
    private var count = 0
    
    func increment() -> Int {
        count += 1
        return count
    }
}

actor ResultsActor {
    private var records: [Scene7ImageRecord]
    
    init(initialRecords: [Scene7ImageRecord]) {
        self.records = initialRecords
    }
    
    func updateRecord(at index: Int, with record: Scene7ImageRecord) {
        if index < records.count {
            records[index] = record
        }
    }
    
    func getAllRecords() -> [Scene7ImageRecord] {
        return records
    }
}

struct DropzoneEmptyView: View {
    @Binding var dropIsTargeted: Bool
    var onDrop: ([NSItemProvider]) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 52))
                .foregroundColor(.accentColor)
            Text("Drag and drop images or folders here to begin")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.controlBackgroundColor).opacity(dropIsTargeted ? 0.22 : 0.13))
        )
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: $dropIsTargeted,
            perform: { providers in
                onDrop(providers)
                return true
            }
        )
    }
}

// Extension for conditional view modifiers
extension View {
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// Use this in BatchUploadCheckerApp.swift or Batch_Upload_CheckerApp.swift
struct ContentView: View {
    var body: some View {
        BatchUploadCheckerView()
    }
}
