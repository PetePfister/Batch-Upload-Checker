import Foundation
import WebKit
import SwiftUI

@MainActor
class BatchProcessorViewModel: ObservableObject {
    @Published var processedItems: [ProcessedItem] = []
    @Published var isProcessing = false
    @Published var isCancelled = false
    @Published var progress: Double = 0.0
    @Published var currentStep: String = ""
    @Published var extractedItems: Set<String> = []
    
    @Published var showCompletionDialog = false
    @Published var completionMessage = ""
    
    var webView: WKWebView? // Main WebView for authentication
    private var workerWebViews: [WKWebView] = [] // Multiple WebViews for concurrent processing
    private var itemsToProcess: [String] = []
    private var buildDataCache: [String: BuildData] = [:]
    private var processingStartTime: Date?
    
    // Concurrent processing settings
    private let maxConcurrentItems = 3 // Process 3 items at once
    
    func cancelProcessing() {
        isCancelled = true
        isProcessing = false
        currentStep = "Cancelled by user"
        
        let processedCount = processedItems.filter { $0.status == .completed }.count
        let totalItems = processedItems.count
        
        completionMessage = """
Processing cancelled by user

✅ Completed before cancellation: \(processedCount)
⏹️ Cancelled: \(totalItems - processedCount)
📊 Total Items: \(totalItems)
"""
        
        showCompletionDialog = true
    }
    
    func reset() {
        processedItems = []
        progress = 0.0
        currentStep = ""
        buildDataCache = [:]
        extractedItems = []
        showCompletionDialog = false
        completionMessage = ""
        isCancelled = false
        
        // Clean up worker WebViews
        workerWebViews.removeAll()
    }
    
    func extractItemNumbers(from urls: [URL]) {
        var newItems: Set<String> = []
        
        for url in urls {
            let filename = url.lastPathComponent
            if let itemNumber = extractQVCItemNumber(from: filename) {
                newItems.insert(itemNumber)
            }
        }
        
        extractedItems.formUnion(newItems)
    }
    
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
    
    func processItems(_ items: [String]) async {
        guard !items.isEmpty else { return }
        
        isProcessing = true
        isCancelled = false
        processingStartTime = Date()
        itemsToProcess = items
        processedItems = items.map { ProcessedItem(itemNumber: $0, status: .pending) }
        
        // Step 1: Load and parse the builds page ONCE using main WebView
        currentStep = "Loading builds page..."
        progress = 0.1
        await loadBuildsPage()
        
        if isCancelled {
            cancelProcessing()
            return
        }
        
        // Step 2: Create worker WebViews and process items concurrently
        currentStep = "Setting up concurrent processors..."
        await createWorkerWebViews()
        
        if isCancelled {
            cancelProcessing()
            return
        }
        
        // Step 3: Process items concurrently
        currentStep = "Processing items concurrently..."
        await processItemsConcurrently()
        
        if isCancelled {
            cancelProcessing()
            return
        }
        
        progress = 1.0
        currentStep = "Completed"
        isProcessing = false
        
        generateCompletionMessage()
        
        print("Processing completed. About to show alert with message: \(completionMessage)")
        showCompletionDialog = true
        print("showCompletionDialog set to: \(showCompletionDialog)")
    }
    
    private func createWorkerWebViews() async {
        workerWebViews.removeAll()
        
        // Create multiple WebViews for concurrent processing
        for i in 0..<maxConcurrentItems {
            let configuration = WKWebViewConfiguration()
            let workerWebView = WKWebView(frame: .zero, configuration: configuration)
            
            // Copy cookies/session from main WebView to worker
            await copySessionToWorker(workerWebView)
            print("Created worker WebView \(i + 1) with session")
            
            workerWebViews.append(workerWebView)
            
            // Small delay to avoid overwhelming SharePoint
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms between worker creation
        }
    }
    
    private func copySessionToWorker(_ workerWebView: WKWebView) async {
        // In a real implementation, we'd copy cookies/session from main WebView
        // For now, we'll just navigate to the builds page to establish session
        guard let buildsURL = URL(string: "https://sharepoint.qvcdev.qvc.net/Teams/DistSiteQuality/SitePages/Builds.aspx") else { return }
        
        workerWebView.load(URLRequest(url: buildsURL))
        
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
    }
    
    private func generateCompletionMessage() {
        let totalItems = processedItems.count
        let completed = processedItems.filter { $0.status == .completed }.count
        let notFound = processedItems.filter { $0.status == .notFound }.count
        let updateFailed = processedItems.filter { $0.status == .updateFailed }.count
        let saveFailed = processedItems.filter { $0.status == .saveFailed }.count
        let failed = notFound + updateFailed + saveFailed
        
        let processingTime = processingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let minutes = Int(processingTime) / 60
        let seconds = Int(processingTime) % 60
        let timeString = "\(minutes)m \(seconds)s"
        
        let successRate = totalItems > 0 ? Double(completed) / Double(totalItems) * 100 : 0
        let effectiveTime = processingTime / Double(max(maxConcurrentItems, 1)) // Account for concurrency
        
        completionMessage = """
Batch processing completed in \(timeString)

✅ Completed: \(completed)
❌ Failed: \(failed)
📊 Success Rate: \(String(format: "%.1f", successRate))%

Total Items: \(totalItems)
🚀 Concurrent Workers: \(maxConcurrentItems)
⚡ Effective Speed: \(String(format: "%.1f", effectiveTime / Double(totalItems)))s per item
"""
        
        if failed > 0 {
            var failureDetails = "\n\nFailure Breakdown:"
            if notFound > 0 { failureDetails += "\n• Not found: \(notFound)" }
            if updateFailed > 0 { failureDetails += "\n• Update failed: \(updateFailed)" }
            if saveFailed > 0 { failureDetails += "\n• Save failed: \(saveFailed)" }
            completionMessage += failureDetails
        }
    }
    
    // CONCURRENT: Process multiple items at once using worker WebViews
    private func processItemsConcurrently() async {
        let items = itemsToProcess
        let totalItems = items.count
        
        // Filter to only items that exist in our build data
        let validItems = items.filter { buildDataCache[$0] != nil }
        let invalidItems = items.filter { buildDataCache[$0] == nil }
        
        // Mark invalid items as not found immediately
        for (index, item) in items.enumerated() {
            if invalidItems.contains(item) {
                processedItems[index] = ProcessedItem(itemNumber: item, status: .notFound)
            }
        }
        
        // Use an actor to safely track progress across concurrent tasks
        let progressTracker = ProgressTracker(total: totalItems, invalidCount: invalidItems.count)
        
        // Create local copy of workers to avoid actor isolation issues
        let workers = workerWebViews
        
        // Process items in concurrent batches
        let itemBatches = chunkArray(validItems, into: maxConcurrentItems)
        
        for batch in itemBatches {
            if isCancelled { return }
            
            // FIXED: Collect all results first, then update UI in one go
            var batchResults: [(String, ProcessingStatus)] = []
            
            // Process this batch concurrently
            await withTaskGroup(of: (String, ProcessingStatus).self) { group in
                for (workerIndex, item) in batch.enumerated() {
                    if workerIndex < workers.count {
                        let worker = workers[workerIndex]
                        group.addTask {
                            let status = await self.processItemWithWorker(item, worker: worker)
                            return (item, status)
                        }
                    }
                }
                
                // Collect results from this batch
                for await result in group {
                    if isCancelled { return }
                    batchResults.append(result)
                }
            }
            
            // FIXED: Update UI on MainActor after collecting all results
            for (item, status) in batchResults {
                if let originalIndex = items.firstIndex(of: item) {
                    processedItems[originalIndex] = ProcessedItem(itemNumber: item, status: status)
                }
                
                // Update progress
                let currentProgress = await progressTracker.incrementAndGetProgress()
                progress = 0.1 + (0.9 * currentProgress)
                currentStep = "Processed \(await progressTracker.getProcessedCount())/\(totalItems) items"
            }
            
            // Small delay between batches to avoid overwhelming SharePoint
            if !batch.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms between batches
            }
        }
    }
    
    // Helper function to chunk arrays without conflicting with existing extension
    private func chunkArray<T>(_ array: [T], into size: Int) -> [[T]] {
        return stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<Swift.min($0 + size, array.count)])
        }
    }
    
    // Process a single item using a specific worker WebView
    private func processItemWithWorker(_ itemNumber: String, worker: WKWebView) async -> ProcessingStatus {
        guard let buildData = buildDataCache[itemNumber] else {
            return .notFound
        }
        
        // Navigate to edit page
        await navigateToEditPage(buildData.editUrl, worker: worker)
        
        // Wait for page load - back to 1 second for reliability
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Set status and save
        let success = await setStatusAndSave(worker: worker)
        
        return success ? .completed : .updateFailed
    }
    
    private func navigateToEditPage(_ editUrl: String, worker: WKWebView) async {
        let baseURL = "https://sharepoint.qvcdev.qvc.net/Teams/DistSiteQuality/SitePages/"
        let fullURL = URL(string: baseURL + editUrl.replacingOccurrences(of: "./", with: ""))!
        
        worker.load(URLRequest(url: fullURL))
    }
    
    private func setStatusAndSave(worker: WKWebView) async -> Bool {
        let javascript = """
        function setStatusAndSave() {
            try {
                // Set status
                const statusSelect = document.querySelector('select[title="Status"]');
                if (!statusSelect) return false;
                
                const completedOption = statusSelect.querySelector('option[value="Completed"]');
                if (!completedOption) return false;
                
                statusSelect.value = 'Completed';
                statusSelect.dispatchEvent(new Event('change', { bubbles: true }));
                
                // Delay then save
                setTimeout(() => {
                    const saveButton = document.querySelector('input[value="Save All Changes"]');
                    if (saveButton && !saveButton.disabled) {
                        saveButton.click();
                    }
                }, 100);
                
                return true;
            } catch (error) {
                console.error('Processing error:', error);
                return false;
            }
        }
        
        setStatusAndSave();
        """
        
        do {
            let result = try await worker.evaluateJavaScript(javascript)
            // Wait for the save operation to complete
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            return result as? Bool ?? false
        } catch {
            print("Error in processing: \(error)")
            return false
        }
    }
    
    private func loadBuildsPage() async {
        guard let webView = webView else { return }
        
        let buildsURL = URL(string: "https://sharepoint.qvcdev.qvc.net/Teams/DistSiteQuality/SitePages/Builds.aspx")!
        webView.load(URLRequest(url: buildsURL))
        
        // Wait for page load
        try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2 seconds
        
        await parseBuildData()
    }
    
    private func parseBuildData() async {
        guard let webView = webView else { return }
        
        let javascript = """
        function extractBuildData() {
            const builds = [];
            const rows = document.querySelectorAll('table.table tbody tr');
            
            for (const row of rows) {
                const buildTitleCell = row.querySelector('td.BuildTitle a');
                const dateCell = row.querySelector('td:nth-child(2)');
                
                if (buildTitleCell && dateCell) {
                    const buildNumber = buildTitleCell.textContent.trim();
                    const buildDate = dateCell.textContent.trim();
                    const href = buildTitleCell.getAttribute('href');
                    
                    const itemNumber = buildNumber.split('_')[0];
                    
                    builds.push({
                        itemNumber: itemNumber,
                        buildNumber: buildNumber,
                        buildDate: buildDate,
                        editUrl: href
                    });
                }
            }
            
            return builds;
        }
        
        extractBuildData();
        """
        
        do {
            let result = try await webView.evaluateJavaScript(javascript)
            if let buildsArray = result as? [[String: Any]] {
                for buildDict in buildsArray {
                    if let itemNumber = buildDict["itemNumber"] as? String,
                       let buildNumber = buildDict["buildNumber"] as? String,
                       let buildDate = buildDict["buildDate"] as? String,
                       let editUrl = buildDict["editUrl"] as? String {
                        
                        buildDataCache[itemNumber] = BuildData(
                            itemNumber: itemNumber,
                            buildNumber: buildNumber,
                            buildDate: buildDate,
                            editUrl: editUrl
                        )
                    }
                }
            }
        } catch {
            print("Error parsing build data: \(error)")
        }
    }
    
    func webViewDidFinishLoading() {
        // Handle any post-load logic if needed
    }
}

// MARK: - Progress Tracking Actor (Thread-Safe)

actor ProgressTracker {
    private var processedCount: Int
    private let totalCount: Int
    
    init(total: Int, invalidCount: Int) {
        self.totalCount = total
        self.processedCount = invalidCount // Start with invalid items already "processed"
    }
    
    func incrementAndGetProgress() -> Double {
        processedCount += 1
        return Double(processedCount) / Double(totalCount)
    }
    
    func getProcessedCount() -> Int {
        return processedCount
    }
}

// MARK: - Data Models

struct BuildData {
    let itemNumber: String
    let buildNumber: String
    let buildDate: String
    let editUrl: String
}

struct ProcessedItem {
    let itemNumber: String
    var status: ProcessingStatus
}

enum ProcessingStatus {
    case pending
    case processing
    case completed
    case notFound
    case updateFailed
    case saveFailed
    
    var description: String {
        switch self {
        case .pending: return "Pending"
        case .processing: return "Processing..."
        case .completed: return "Completed"
        case .notFound: return "Not found in builds"
        case .updateFailed: return "Failed to update status"
        case .saveFailed: return "Failed to save changes"
        }
    }
    
    var color: Color {
        switch self {
        case .pending: return .gray
        case .processing: return .blue
        case .completed: return .green
        case .notFound, .updateFailed, .saveFailed: return .red
        }
    }
    
    var iconName: String {
        switch self {
        case .pending: return "clock"
        case .processing: return "arrow.clockwise"
        case .completed: return "checkmark.circle.fill"
        case .notFound: return "questionmark.circle"
        case .updateFailed, .saveFailed: return "xmark.circle.fill"
        }
    }
}
