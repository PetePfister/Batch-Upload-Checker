import SwiftUI
import WebKit

struct WebViewContainer: View {
    @ObservedObject var viewModel: BatchProcessorViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack {
            HStack {
                Text("SharePoint Authentication")
                    .font(.headline)
                Spacer()
                Button("Hide") {
                    dismiss()
                }
            }
            .padding()
            
            SharePointWebView(viewModel: viewModel)
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

struct SharePointWebView: NSViewRepresentable {
    @ObservedObject var viewModel: BatchProcessorViewModel
    
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        viewModel.webView = webView
        
        // Load the builds page
        if let url = URL(string: "https://sharepoint.qvcdev.qvc.net/Teams/DistSiteQuality/SitePages/Builds.aspx") {
            webView.load(URLRequest(url: url))
        }
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let viewModel: BatchProcessorViewModel
        
        init(_ viewModel: BatchProcessorViewModel) {
            self.viewModel = viewModel
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Fixed: Use Task to call main actor method from non-isolated context
            Task { @MainActor in
                viewModel.webViewDidFinishLoading()
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("WebView navigation failed: \(error.localizedDescription)")
        }
    }
}
