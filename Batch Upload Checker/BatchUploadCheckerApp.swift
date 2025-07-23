import SwiftUI

@main
struct BatchUploadCheckerApp: App {
    var body: some Scene {
        Window("Batch Upload Checker", id: "main") {
            ContentView()
                .frame(width: 600, height: 700)
        }
        .windowResizability(.contentSize) // disables resizing
    }
}
