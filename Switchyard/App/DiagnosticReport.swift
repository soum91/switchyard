import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The one way Switchyard hands over a diagnostic report: checked Copy, Share, Save to Files, selectable text.
struct DiagnosticReportView: View {
    let title: String
    let body_: String
    let filename: String
    @Environment(\.dismiss) private var dismiss
    @State private var note: String?
    @State private var noteOK = true
    @State private var saving = false

    init(title: String, report: String, filename: String) {
        self.title = title
        self.filename = filename
        self.body_ = DiagnosticReportView.header() + "\n\n" + report
    }

    static func header() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let date = ISO8601DateFormatter().string(from: Date())
        return "Switchyard \(version) (build \(build))\n\(machine), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)\n\(date)\nPasswords, keys and session tokens are redacted."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let note {
                        Label(note, systemImage: noteOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(noteOK ? Theme.accent : Theme.bad)
                    }
                    Text(body_)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Spacer()
                    ShareLink(item: body_) { Label("Share", systemImage: "square.and.arrow.up") }
                    Spacer()
                    Button { saving = true } label: { Label("Save", systemImage: "folder") }
                }
            }
            .fileExporter(isPresented: $saving, document: PlainTextFile(text: body_), contentType: .plainText, defaultFilename: filename) { result in
                switch result {
                case .success(let url): show("Saved \(url.lastPathComponent) to Files.", ok: true)
                case .failure(let e): show("Couldn't save: \(e.localizedDescription)", ok: false)
                }
            }
        }
    }

    private func copy() {
        UIPasteboard.general.string = body_
        if UIPasteboard.general.string == body_ {
            show("Copied the full report (\(body_.count) characters) and checked the clipboard.", ok: true)
        } else {
            show("The clipboard didn't keep the report. Use Share or Save instead.", ok: false)
        }
    }

    private func show(_ t: String, ok: Bool) {
        note = t
        noteOK = ok
    }
}

struct PlainTextFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
