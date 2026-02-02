import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Array Chunking Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Swatch Validation Types

struct SwatchValidationError: Identifiable {
    let id = UUID()
    let itemNumber: String
    let missingType: SwatchType
    let message: String
    
    enum SwatchType {
        case colorBlock // .101
        case productSwatch // .102
        case mainImage // .001
        
        var description: String {
            switch self {
            case .colorBlock: return "Swatch block"
            case .productSwatch: return "Swatch image"
            case .mainImage: return "001"
            }
        }
    }
}

// MARK: - Logic

@MainActor
class Scene7CheckerLogic: ObservableObject {
    @Published var records: [Scene7ImageRecord] = []
    @Published var isLoading: Bool = false
    @Published var isCancelled: Bool = false // NEW: Cancellation support
    @Published var errorMessage: String? = nil
    @Published var swatchValidationErrors: [SwatchValidationError] = []

    let placeholderMD5 = "115485ffcdb7a6419a5751a6045b482f"
    let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "tiff", "tif", "bmp", "webp", "heic"]

    // MARK: - Naming Convention Regex Patterns (updated for slot 001-008 only)
    let swatchBlockPattern = #"^[A-Za-z0-9]+(?:_[A-Za-z0-9]+)*(?:_[A-Za-z0-9]+)*[_.]101!?\.((jpg|jpeg|png|gif|tiff|tif|bmp|webp|heic))$"#
    let swatchImagePattern = #"^[A-Za-z0-9]+(?:_[A-Za-z0-9]+)*(?:_[A-Za-z0-9]+)*[_.]102!?\.((jpg|jpeg|png|gif|tiff|tif|bmp|webp|heic))$"#
    let slotPattern = #"^[A-Za-z0-9]+[_.]00[1-8]\.(jpg|jpeg|png|gif|tiff|tif|bmp|webp|heic)$"#

    // MARK: - Cancellation Support
    
    func cancelChecking() {
        isCancelled = true
        isLoading = false
        errorMessage = "Checking cancelled by user"
    }

    // MARK: - Naming Convention Check
    func checkNamingConvention(filename: String) -> String? {
        let patterns = [
            (swatchBlockPattern, "Swatch block image (101 or 101!)"),
            (swatchImagePattern, "Swatch image (102 or 102!)"),
            (slotPattern, "Product detail/slot image (_001 to _008 or .001 to .008)")
        ]
        let range = NSRange(location: 0, length: (filename as NSString).length)
        for (pattern, _) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: filename, options: [], range: range) != nil {
                return nil // Valid
            }
        }
        return "Invalid Filename"
    }

    // MARK: - Swatch Validation Functions - Now checks Scene7 directly!
    
    func validateSwatchPairs() async {
        if isCancelled { return }
        
        swatchValidationErrors.removeAll()
        
        // First, clear all existing swatch validation issues from records
        for index in records.indices {
            records[index].swatchValidationIssue = nil
            records[index].expandedCheckIssue = nil
        }
        
        // Group files by item number and color from LOCAL files
        var localSwatchGroups: [String: [String: Set<String>]] = [:] // itemNumber -> colorCode -> slots
        var itemNumbers: Set<String> = []
        
        for record in records {
            let filename = record.proposedName
            if let (itemNumber, colorCode, slot) = parseSwatchFilename(filename) {
                if localSwatchGroups[itemNumber] == nil {
                    localSwatchGroups[itemNumber] = [:]
                }
                if localSwatchGroups[itemNumber]![colorCode] == nil {
                    localSwatchGroups[itemNumber]![colorCode] = Set<String>()
                }
                localSwatchGroups[itemNumber]![colorCode]!.insert(slot)
                itemNumbers.insert(itemNumber)
            }
        }
        
        // Now check Scene7 for missing pairs and .001 images
        await withTaskGroup(of: Void.self) { group in
            for (itemNumber, colorGroups) in localSwatchGroups {
                if isCancelled { return }
                for (colorCode, localSlots) in colorGroups {
                    if isCancelled { return }
                    group.addTask {
                        await self.checkSwatchPairOnScene7(itemNumber: itemNumber, colorCode: colorCode, localSlots: localSlots)
                    }
                }
            }
            
            // FIXED: Check for .001 main image for ALL item numbers that have ANY swatch files
            for itemNumber in itemNumbers {
                if isCancelled { return }
                group.addTask {
                    await self.checkMainImageOnScene7(itemNumber: itemNumber)
                }
            }
        }
    }
    
    private func checkSwatchPairOnScene7(itemNumber: String, colorCode: String, localSlots: Set<String>) async {
        if isCancelled { return }
        
        let has101Locally = localSlots.contains("101")
        let has102Locally = localSlots.contains("102")
        
        var missingItems: [String] = []
        
        // Check Scene7 for the missing counterpart
        if has101Locally && !has102Locally {
            if isCancelled { return }
            // We have 101 locally, check if 102 exists on Scene7
            let filename102 = "\(itemNumber)_\(colorCode).102.jpg"
            let scene7URL = Self.scene7URL(for: filename102)
            
            if let url = scene7URL {
                let (exists, _) = await Self.checkScene7Image(url: url, placeholderMD5: placeholderMD5)
                if isCancelled { return }
                if exists != true { // Not found on Scene7 either
                    missingItems.append("Swatch image")
                }
            }
        } else if has102Locally && !has101Locally {
            if isCancelled { return }
            // We have 102 locally, check if 101 exists on Scene7
            let filename101 = "\(itemNumber)_\(colorCode).101.jpg"
            let scene7URL = Self.scene7URL(for: filename101)
            
            if let url = scene7URL {
                let (exists, _) = await Self.checkScene7Image(url: url, placeholderMD5: placeholderMD5)
                if isCancelled { return }
                if exists != true { // Not found on Scene7 either
                    missingItems.append("Swatch block")
                }
            }
        }
        
        // Only create alert if something is actually missing
        if !missingItems.isEmpty && !isCancelled {
            await MainActor.run {
                let missingText = missingItems.joined(separator: ", ")
                let message = "Expanded check. \(missingText) is missing and needs to be loaded."
                
                // Mark affected local files
                self.markExpandedCheckIssue(itemNumber: itemNumber, colorCode: colorCode, message: message)
            }
        }
    }
    
    private func checkMainImageOnScene7(itemNumber: String) async {
        if isCancelled { return }
        
        // Check if we have .001 locally for this specific item number
        let has001Locally = records.contains { record in
            if let (recordItemNumber, slot) = parseMainImageFilename(record.proposedName) {
                return recordItemNumber == itemNumber && slot == "001"
            }
            return false
        }
        
        if !has001Locally {
            if isCancelled { return }
            // Check Scene7 for .001 main image
            let filename001 = "\(itemNumber).001.jpg"
            let scene7URL = Self.scene7URL(for: filename001)
            
            if let url = scene7URL {
                let (exists, _) = await Self.checkScene7Image(url: url, placeholderMD5: placeholderMD5)
                if isCancelled { return }
                
                await MainActor.run {
                    if exists != true && !self.isCancelled {
                        // .001 missing both locally and on Scene7 - this is an issue
                        let message = "Expanded check. 001 is missing and needs to be loaded."
                        
                        // Mark all swatch files for this item with missing main image issue
                        self.markMainImageExpandedCheckIssue(itemNumber: itemNumber, message: message)
                    }
                    // If exists == true, we don't show any alert - everything is fine!
                }
            }
        }
    }
    
    private func markExpandedCheckIssue(itemNumber: String, colorCode: String, message: String) {
        if isCancelled { return }
        
        for index in records.indices {
            if let (recordItemNumber, recordColorCode, _) = parseSwatchFilename(records[index].proposedName),
               recordItemNumber == itemNumber && recordColorCode == colorCode {
                let existingIssue = records[index].expandedCheckIssue
                records[index].expandedCheckIssue = existingIssue != nil ? "\(existingIssue!) & \(message)" : message
            }
        }
    }
    
    private func markMainImageExpandedCheckIssue(itemNumber: String, message: String) {
        if isCancelled { return }
        
        // Mark ALL swatch files for this item number with the missing .001 issue
        for index in records.indices {
            if let (recordItemNumber, _, _) = parseSwatchFilename(records[index].proposedName),
               recordItemNumber == itemNumber {
                let existingIssue = records[index].expandedCheckIssue
                records[index].expandedCheckIssue = existingIssue != nil ? "\(existingIssue!) & \(message)" : message
            }
        }
    }
    
    // Helper function to parse swatch filenames (e.g., "A123456_RED.101.jpg")
    private func parseSwatchFilename(_ filename: String) -> (itemNumber: String, colorCode: String, slot: String)? {
        let base = (filename as NSString).deletingPathExtension.uppercased()
        
        // Pattern for Item_Color.101 or Item_Color.102
        let pattern = #"^([A-Z]\d+)_([A-Z0-9]+)\.(10[12])$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let nsBase = base as NSString
        let range = NSRange(location: 0, length: nsBase.length)
        
        if let match = regex?.firstMatch(in: base, options: [], range: range), match.numberOfRanges == 4 {
            let itemNumber = nsBase.substring(with: match.range(at: 1))
            let colorCode = nsBase.substring(with: match.range(at: 2))
            let slot = nsBase.substring(with: match.range(at: 3))
            return (itemNumber, colorCode, slot)
        }
        
        return nil
    }
    
    // Helper function to parse main image filenames (e.g., "A123456.001.jpg")
    private func parseMainImageFilename(_ filename: String) -> (itemNumber: String, slot: String)? {
        let base = (filename as NSString).deletingPathExtension.uppercased()
        
        // Pattern for Item.001 through Item.008
        let pattern = #"^([A-Z]\d+)\.(\d{3})$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let nsBase = base as NSString
        let range = NSRange(location: 0, length: nsBase.length)
        
        if let match = regex?.firstMatch(in: base, options: [], range: range), match.numberOfRanges == 3 {
            let itemNumber = nsBase.substring(with: match.range(at: 1))
            let slot = nsBase.substring(with: match.range(at: 2))
            return (itemNumber, slot)
        }
        
        return nil
    }

    // MARK: - Import files/folders (recursive for dropped folders)
    static func collectFileURLs(from urls: [URL]) async -> [URL] {
        var allFiles: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if exists {
                if isDir.boolValue {
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
        }
        return allFiles
    }

    func importFiles(from urls: [URL]) {
        Task {
            let allFiles = await Self.collectFileURLs(from: urls)
            let filtered = allFiles.filter { url in
                let ext = url.pathExtension.lowercased()
                return imageExtensions.contains(ext)
            }

            // Custom sort function
            func customSort(lhs: URL, rhs: URL) -> Bool {
                let fileA = lhs.lastPathComponent
                let fileB = rhs.lastPathComponent
                return fileA.localizedStandardCompare(fileB) == .orderedAscending
            }

            let sortedFiles = filtered.sorted(by: customSort)
            let uniqueFiles = Array(Set(sortedFiles))
            let uniqueSortedFiles = uniqueFiles.sorted(by: customSort)

            let imageRecords = uniqueSortedFiles.map { url in
                let filename = url.lastPathComponent
                let normalized = Self.defaultUnderscoreSlotFilename(for: filename)
                let scene7url = Self.scene7URL(for: normalized)
                let warning = self.checkNamingConvention(filename: filename)
                return Scene7ImageRecord(
                    localURL: url,
                    proposedName: filename,
                    scene7URL: scene7url,
                    status: .notChecked,
                    md5Hash: nil,
                    isDuplicate: false,
                    renameError: nil,
                    namingWarning: warning,
                    thumbnail: Self.thumbnail(for: url),
                    usedDetailSlots: nil,
                    availableDetailSlots: nil,
                    detailSlotChecked: false,
                    swatchValidationIssue: nil,
                    expandedCheckIssue: nil
                )
            }
            self.records = imageRecords
            self.errorMessage = records.isEmpty ? "No image files found in selection." : nil
        }
    }

    func clearAllFiles() {
        self.records = []
        self.swatchValidationErrors = []
        self.errorMessage = nil
        self.isCancelled = false
    }

    // MARK: - Enhanced checking function with swatch validation (FIXED: Now properly async with cancellation)
    func checkAllImagesWithSwatchValidation() async {
        self.isLoading = true
        self.isCancelled = false
        self.errorMessage = nil
        
        defer {
            self.isLoading = false
        }
        
        // Run the normal Scene7 check first
        let recordsCopy = self.records
        let maxConcurrent = 10
        let indices = recordsCopy.indices
        var checkedPairs = Array<(Int, Scene7ImageRecord)?>(repeating: nil, count: recordsCopy.count)

        let indexChunks = Array(indices).chunked(into: maxConcurrent)
        for chunk in indexChunks {
            // Check for cancellation
            if isCancelled {
                await MainActor.run {
                    self.errorMessage = "Checking cancelled by user"
                }
                return
            }
            
            await withTaskGroup(of: (Int, Scene7ImageRecord).self) { group in
                for idx in chunk {
                    if isCancelled { return }
                    let record = recordsCopy[idx]
                    group.addTask {
                        let checkedRecord = await self.checkedImageRecord(for: record)
                        return (idx, checkedRecord)
                    }
                }
                for await (idx, checkedRecord) in group {
                    if isCancelled { return }
                    checkedPairs[idx] = (idx, checkedRecord)
                }
            }
        }

        if isCancelled {
            await MainActor.run {
                self.errorMessage = "Checking cancelled by user"
            }
            return
        }
        
        let reassembled = checkedPairs.compactMap { $0?.1 }
        self.records = reassembled
        
        // Then validate swatch pairs against Scene7
        if !isCancelled {
            await validateSwatchPairs()
        }
        
        if isCancelled {
            await MainActor.run {
                self.errorMessage = "Checking cancelled by user"
            }
        }
    }

    func checkAllImages() async {
        self.isLoading = true
        self.isCancelled = false
        self.errorMessage = nil
        
        defer {
            self.isLoading = false
        }
        
        let recordsCopy = self.records
        let maxConcurrent = 10
        let indices = recordsCopy.indices
        var checkedPairs = Array<(Int, Scene7ImageRecord)?>(repeating: nil, count: recordsCopy.count)

        let indexChunks = Array(indices).chunked(into: maxConcurrent)
        for chunk in indexChunks {
            if isCancelled {
                await MainActor.run {
                    self.errorMessage = "Checking cancelled by user"
                }
                return
            }
            
            await withTaskGroup(of: (Int, Scene7ImageRecord).self) { group in
                for idx in chunk {
                    if isCancelled { return }
                    let record = recordsCopy[idx]
                    group.addTask {
                        let checkedRecord = await self.checkedImageRecord(for: record)
                        return (idx, checkedRecord)
                    }
                }
                for await (idx, checkedRecord) in group {
                    if isCancelled { return }
                    checkedPairs[idx] = (idx, checkedRecord)
                }
            }
        }

        if isCancelled {
            await MainActor.run {
                self.errorMessage = "Checking cancelled by user"
            }
            return
        }
        
        let reassembled = checkedPairs.compactMap { $0?.1 }
        self.records = reassembled
    }

    func checkImageForProposedName(recordID: UUID, newProposedName: String) {
        guard let idx = records.firstIndex(where: { $0.id == recordID }) else { return }
        var record = records[idx]
        // Always convert slot pattern to default underscore for URL generation
        let normalized = Self.defaultUnderscoreSlotFilename(for: newProposedName)
        record.proposedName = newProposedName
        record.scene7URL = Self.scene7URL(for: normalized)
        record.status = .notChecked
        record.isDuplicate = false
        record.md5Hash = nil
        record.usedDetailSlots = nil
        record.availableDetailSlots = nil
        record.detailSlotChecked = false
        // Duplicate check: get all other proposed names, case insensitive
        let otherNames = records.enumerated()
            .filter { $0.offset != idx }
            .map { $0.element.proposedName.lowercased() }
        record.renameError = validateRename(proposedName: record.proposedName, existingNames: otherNames)
        record.namingWarning = checkNamingConvention(filename: record.proposedName)
        records[idx] = record
    }

    // MARK: - Single-file rename (async, triggers check)
    func renameFileOnDisk(recordID: UUID) async {
        guard let idx = records.firstIndex(where: { $0.id == recordID }) else { return }
        var record = records[idx]
        let otherNames = records
            .enumerated()
            .filter { $0.offset != idx }
            .map { $0.element.proposedName.lowercased() }
        let error = validateRename(proposedName: record.proposedName, existingNames: otherNames)
        record.renameError = error
        record.namingWarning = checkNamingConvention(filename: record.proposedName)
        if record.filename != record.proposedName && record.renameError == nil {
            let destination = record.localURL.deletingLastPathComponent().appendingPathComponent(record.proposedName)
            do {
                try FileManager.default.moveItem(at: record.localURL, to: destination)
                record.localURL = destination
            } catch {
                record.renameError = "Rename failed: \(error.localizedDescription)"
            }
        }
        records[idx] = record

        if record.renameError == nil {
            let updatedRecord = await self.checkedImageRecord(for: record)
            records[idx] = updatedRecord
        }
    }

    // MARK: - Async check helper - takes/returns value, never inout
    private func checkedImageRecord(for record: Scene7ImageRecord) async -> Scene7ImageRecord {
        if isCancelled { return record }
        
        var updated = record
        // Always use underscore-style filename for slot checks and URL
        let normalized = Self.defaultUnderscoreSlotFilename(for: updated.proposedName)
        guard let url = Self.scene7URL(for: normalized) else {
            updated.status = .error
            updated.usedDetailSlots = nil
            updated.availableDetailSlots = nil
            updated.detailSlotChecked = false
            return updated
        }
        
        if isCancelled { return updated }
        
        let (exists, hash) = await Self.checkScene7Image(url: url, placeholderMD5: placeholderMD5)
        
        if isCancelled { return updated }
        
        if let exists = exists {
            updated.status = exists ? .exists : .error
            updated.isDuplicate = exists
        } else {
            updated.status = .error
        }
        updated.md5Hash = hash

        // --- Detail slot checker for 001...008, always use underscore for filename ---
        let slotNumbers = (1...8).map { String(format: "%03d", $0) }
        var usedSlots: [String] = []
        var availableSlots: [String] = []

        let filenameBase = (normalized as NSString).deletingPathExtension
        let ext = (normalized as NSString).pathExtension
        // Get the "item number" before first _, or whole if no _
        let itemNumber: Substring = filenameBase.split(separator: "_").first ?? Substring(filenameBase)
        
        for slot in slotNumbers {
            if isCancelled { break }
            
            let slotFilename = "\(itemNumber)_\(slot).\(ext)"
            guard let slotURL = Self.scene7URL(for: slotFilename) else { continue }
            let (_, slotHash) = await Self.checkScene7Image(url: slotURL, placeholderMD5: placeholderMD5)
            
            if isCancelled { break }
            
            if let slotHash = slotHash, slotHash == placeholderMD5 {
                availableSlots.append(slot)
            } else {
                usedSlots.append(slot)
            }
        }
        
        updated.usedDetailSlots = usedSlots
        updated.availableDetailSlots = availableSlots
        updated.detailSlotChecked = true

        return updated
    }

    /// Converts any .NNN.ext or _NNN.ext at the end of a filename to _NNN.ext for canonical slot checking.
    static func defaultUnderscoreSlotFilename(for filename: String) -> String {
        // Handles K12345.001.jpg or K12345_001.jpg => K12345_001.jpg
        let pattern = #"^([a-zA-Z0-9]+)[\._](\d{3})\.(jpg|jpeg|png|gif|tiff|tif|bmp|webp|heic)$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let nsFilename = filename as NSString
        let range = NSRange(location: 0, length: nsFilename.length)
        if let match = regex?.firstMatch(in: filename, options: [], range: range), match.numberOfRanges == 4 {
            let base = nsFilename.substring(with: match.range(at: 1))
            let slot = nsFilename.substring(with: match.range(at: 2))
            let ext = nsFilename.substring(with: match.range(at: 3))
            return "\(base)_\(slot).\(ext)"
        }
        return filename
    }

    // MARK: - Scene7 URL Generation (NO file extension in the URL!)
    static func scene7URL(for filename: String) -> URL? {
        let lowerFilename = filename.lowercased()
        let filenameNoExtension = (lowerFilename as NSString).deletingPathExtension
        // Always convert _NNN at end to .NNN for Scene7 path
        let patternUnderscore = #"_(\d{3})$"#
        let regexUnderscore = try? NSRegularExpression(pattern: patternUnderscore, options: [])
        let rangeUnderscore = NSRange(location: 0, length: filenameNoExtension.utf16.count)
        let converted = regexUnderscore?.stringByReplacingMatches(in: filenameNoExtension, options: [], range: rangeUnderscore, withTemplate: ".$1") ?? filenameNoExtension
        let itemNumber = converted.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true).first?
            .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first
        guard let item = itemNumber, let first = item.first else { return nil }
        let itemStr = String(item)
        let lastTwo = itemStr.suffix(2)
        // CRITICAL: Do NOT include the file extension in the final URL!
        return URL(string: "https://qvc.scene7.com/is/image/QVC/\(first)/\(lastTwo)/\(converted)")
    }

    static func checkScene7Image(url: URL, placeholderMD5: String) async -> (Bool?, String?) {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let digest = Insecure.MD5.hash(data: data)
            let hash = digest.map { String(format: "%02hhx", $0) }.joined()
            let isReal = (hash != placeholderMD5)
            return (isReal, hash)
        } catch {
            return (nil, nil)
        }
    }

    static func thumbnail(for url: URL) -> NSImage? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        let targetSize = NSSize(width: 40, height: 40)
        return NSImage(size: targetSize, flipped: false) { rect in
            img.draw(in: rect, from: NSRect(origin: .zero, size: img.size),
                     operation: .copy, fraction: 1.0)
            return true
        }
    }

    // MARK: - Rename Logic (duplicate check included)
    func validateRename(proposedName: String, existingNames: [String]) -> String? {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Filename cannot be empty."
        }
        guard imageExtensions.contains((trimmed as NSString).pathExtension.lowercased()) else {
            return "Not a valid image file extension."
        }
        if existingNames.contains(trimmed.lowercased()) {
            return "Duplicate filename in this batch."
        }
        return nil
    }

    var canExport: Bool {
        records.allSatisfy { $0.renameError == nil } && records.contains(where: { $0.filename != $0.proposedName })
    }

    func handleDrop(providers: [NSItemProvider]) {
        let providerCount = providers.count
        guard providerCount > 0 else { return }
        let dispatchGroup = DispatchGroup()
        let collector = URLCollector()

        for provider in providers {
            dispatchGroup.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    Task {
                        await collector.append(url)
                        dispatchGroup.leave()
                    }
                } else {
                    dispatchGroup.leave()
                }
            }
        }

        dispatchGroup.notify(queue: .main) {
            Task {
                let urls = await collector.collected()
                self.importFiles(from: urls)
            }
        }
    }

    func deleteFileAndRemoveRecord(id: UUID) async {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records[idx]
        do {
            try FileManager.default.trashItem(at: record.localURL, resultingItemURL: nil)
            records.remove(at: idx)
        } catch {
            self.errorMessage = "Failed to delete file: \(error.localizedDescription)"
        }
    }
}

// Thread-Safe Collector for Drag & Drop (Swift 6)
actor URLCollector {
    var list: [URL] = []
    func append(_ url: URL) {
        list.append(url)
    }
    func collected() -> [URL] {
        list
    }
}
