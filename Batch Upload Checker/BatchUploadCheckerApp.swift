import SwiftUI

@main
struct BatchUploadCheckerApp: App {
    var body: some Scene {
        Window("Batch Upload Checker", id: "main") {
            ContentView()
                .frame(minWidth: 600, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
    }
}
