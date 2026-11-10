import SwiftUI
import WebKit

/// The TP-Link's own web page inside Switchyard: it asks for its own account name and password,
/// and everything the router offers works, whatever firmware it runs.
struct TPWebDashboard: View {
    let host: String
    var onForget: () -> Void
    @StateObject private var web = TPWeb()
    @ObservedObject private var capture = TPCapture.shared
    @State private var showReport = false

    private var url: URL? {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.hasPrefix("http") { h = "http://" + h }
        return URL(string: h)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            TPWebRepresentable(web: web)
                .opacity(web.failed == nil ? 1 : 0)
            if let f = web.failed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Theme.bad)
                    Text("Can't open the TP-Link at \(host)").font(.headline)
                    Text(f).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try again") { load() }.buttonStyle(.borderedProminent)
                }
                .padding(30)
            } else if web.loading {
                ProgressView().padding(.top, 80).frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .navigationTitle("TP-Link")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { web.view.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!web.canGoBack)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { load() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    Button { showReport = true } label: { Label("What the page loaded (\(capture.pageCount) pages)", systemImage: "list.bullet.rectangle") }
                    Button { capture.clear() } label: { Label("Clear that list", systemImage: "trash") }
                    if let url { Link(destination: url) { Label("Open in Safari", systemImage: "safari") } }
                    Button("Forget this router", role: .destructive, action: onForget)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { if web.view.url == nil { load() } }
        .sheet(isPresented: $showReport) {
            DiagnosticReportView(title: "TP-Link pages", report: capture.report(host: host), filename: "switchyard-tplink-pages.txt")
        }
    }

    private func load() {
        guard let url else { web.failed = "That address doesn't look right."; return }
        web.failed = nil
        web.view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10))
    }
}

@MainActor
final class TPWeb: NSObject, ObservableObject, WKNavigationDelegate {
    let view: WKWebView
    @Published var loading = false
    @Published var failed: String?
    @Published var canGoBack = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // keeps the router's login between launches when it allows
        config.userContentController.addUserScript(WKUserScript(source: TPCapture.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(TPCaptureHandler(), name: "sy")
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .clear
    }

    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { loading = true }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loading = false; canGoBack = w.canGoBack }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { fail(e) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { fail(e) }

    private func fail(_ e: Error) {
        loading = false
        if (e as NSError).code == NSURLErrorCancelled { return }
        failed = "\(e.localizedDescription) Are you on the same network as the router?"
    }
}

struct TPWebRepresentable: UIViewRepresentable {
    let web: TPWeb
    func makeUIView(context: Context) -> WKWebView { web.view }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
