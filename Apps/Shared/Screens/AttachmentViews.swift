import SwiftUI
import QuickLook
import FluxerKit

// Attachment rendering for the transcript. Images stay inline as before,
// text and markdown files get an expandable preview box (issue #36), and
// everything else gets a real download chip with progress, Quick Look and
// save (issue #37).

struct AttachmentContent: View {
    let attachment: Attachment

    @State private var showViewer = false

    private var isImage: Bool {
        attachment.contentType?.hasPrefix("image/") == true
    }

    private var imageURL: URL? {
        (attachment.proxyUrl ?? attachment.url).flatMap(URL.init(string:))
    }

    /// Inline text preview only for files small enough to fetch whole;
    /// bigger text files fall back to the download chip.
    private var showsTextInline: Bool {
        attachment.isTextLike && (attachment.size ?? .max) <= 512 * 1024
    }

    var body: some View {
        if isImage, let url = imageURL {
            RemoteImage(url: url) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay { ProgressView() }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: 320, maxHeight: 320, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.top, 4)
            .onTapGesture { showViewer = true }
            .sheet(isPresented: $showViewer) {
                ImageViewerSheet(url: url, filename: attachment.filename)
            }
        } else if showsTextInline {
            TextAttachmentPreview(attachment: attachment)
        } else {
            FileAttachmentChip(attachment: attachment)
        }
    }

    private var aspectRatio: CGFloat {
        guard let width = attachment.width, let height = attachment.height, height > 0 else {
            return 4 / 3
        }
        return CGFloat(width) / CGFloat(height)
    }
}

// MARK: - Text attachments (issue #36)

/// A txt or md attachment shown in the conversation: capped scrollable box
/// with the content, tap the expand button for the full screen viewer.
private struct TextAttachmentPreview: View {
    let attachment: Attachment

    private enum LoadState {
        case loading
        case loaded(String)
        case failed
    }

    @State private var state: LoadState = .loading
    @State private var expanded = false

    private let previewCharacterLimit = 4000

    private var sourceURL: URL? {
        (attachment.url ?? attachment.proxyUrl).flatMap(URL.init(string:))
    }

    private var loadedText: String? {
        if case .loaded(let text) = state { return text }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            contentBox
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.top, 4)
        .task { await load() }
        .sheet(isPresented: $expanded) {
            TextAttachmentSheet(attachment: attachment, text: loadedText ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.isMarkdownFile ? "doc.richtext" : "doc.text")
                .font(.system(size: 13))
                .foregroundStyle(Theme.icon)
            Text(attachment.filename)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.rowText)
                .lineLimit(1)
            if let size = formatBytes(attachment.size) {
                Text(size)
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            if loadedText != nil {
                Button {
                    expanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.icon)
                }
                .buttonStyle(.plain)
                .help("Expand")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var contentBox: some View {
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .padding(12)
        case .failed:
            Button {
                Task { await load() }
            } label: {
                Label("Couldn't load, tap to retry", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .padding(12)
        case .loaded(let text):
            ScrollView {
                attachmentText(previewText(text), markdown: attachment.isMarkdownFile)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 220)
        }
    }

    private func previewText(_ text: String) -> String {
        guard text.count > previewCharacterLimit else { return text }
        return String(text.prefix(previewCharacterLimit)) + "\n[truncated, expand for the rest]"
    }

    private func load() async {
        guard let source = sourceURL else {
            state = .failed
            return
        }
        if let cached = TextAttachmentCache.text(for: source) {
            state = .loaded(cached)
            return
        }
        state = .loading
        do {
            let text = try await fetchTextAttachment(from: source)
            TextAttachmentCache.store(text, for: source)
            state = .loaded(text)
        } catch {
            state = .failed
        }
    }
}

/// Full screen viewer behind the expand button.
private struct TextAttachmentSheet: View {
    @Environment(\.dismiss) private var dismiss

    let attachment: Attachment
    let text: String

    var body: some View {
        NavigationStack {
            ScrollView {
                attachmentText(text, markdown: attachment.isMarkdownFile)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Theme.bg)
            .navigationTitle(attachment.filename)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if let url = (attachment.url ?? attachment.proxyUrl).flatMap(URL.init(string:)) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Button("Done") { dismiss() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 460)
        #endif
    }
}

/// Shared text styling: rendered markdown for md files, monospaced for
/// everything else. File content skips the message pipeline on purpose,
/// mentions and spoilers don't belong in a file dump.
@ViewBuilder
private func attachmentText(_ text: String, markdown: Bool) -> some View {
    if markdown {
        Text(renderedMarkdown(text))
            .font(.system(size: 14))
            .foregroundStyle(Theme.messageText)
            .textSelection(.enabled)
    } else {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.soft)
            .textSelection(.enabled)
    }
}

private func renderedMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

/// In-memory cache so scrolling back through the transcript doesn't refetch
/// the same files.
@MainActor
private enum TextAttachmentCache {
    private static var cache: [URL: String] = [:]

    static func text(for url: URL) -> String? { cache[url] }

    static func store(_ text: String, for url: URL) { cache[url] = text }
}

private nonisolated func fetchTextAttachment(from url: URL) async throws -> String {
    let (data, response) = try await URLSession.shared.data(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw URLError(.badServerResponse)
    }
    return String(decoding: data.prefix(1024 * 1024), as: UTF8.self)
}

// MARK: - Everything else (issue #37)

/// Chip for attachments the app can't display: filename, size, download
/// with a progress ring, then Quick Look on tap plus share or save.
private struct FileAttachmentChip: View {
    let attachment: Attachment

    private enum Phase {
        case idle
        case downloading(Double)
        case downloaded(URL)
        case failed
    }

    @State private var phase: Phase = .idle
    @State private var quickLookItem: URL?

    private var sourceURL: URL? {
        (attachment.url ?? attachment.proxyUrl).flatMap(URL.init(string:))
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 22))
                .foregroundStyle(Theme.icon)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.messageText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 12)
            trailingControls
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .frame(maxWidth: 340, alignment: .leading)
        .padding(.top, 4)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { primaryAction() }
        .quickLookPreview($quickLookItem)
        .onAppear {
            // A file downloaded earlier this run is still on disk; skip
            // straight to the done state.
            let existing = AttachmentDownloader.destination(
                id: attachment.id.stringValue,
                filename: attachment.filename
            )
            if FileManager.default.fileExists(atPath: existing.path) {
                phase = .downloaded(existing)
            }
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch phase {
        case .idle:
            Button {
                startDownload()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Download")
        case .downloading(let fraction):
            ProgressRing(fraction: fraction)
        case .downloaded(let file):
            HStack(spacing: 10) {
                Button {
                    quickLookItem = file
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.icon)
                }
                .buttonStyle(.plain)
                .help("Preview")
                #if os(macOS)
                Button {
                    saveToDisk(file)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.icon)
                }
                .buttonStyle(.plain)
                .help("Save")
                #else
                ShareLink(item: file) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.icon)
                }
                #endif
            }
        case .failed:
            Button {
                startDownload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.red)
            }
            .buttonStyle(.plain)
            .help("Retry download")
        }
    }

    private var subtitle: String {
        switch phase {
        case .idle:
            return formatBytes(attachment.size) ?? "File"
        case .downloading(let fraction):
            let size = formatBytes(attachment.size).map { " of \($0)" } ?? ""
            return "\(Int(fraction * 100))%\(size)"
        case .downloaded:
            return "Downloaded, tap to preview"
        case .failed:
            return "Download failed"
        }
    }

    private var iconName: String {
        let type = attachment.contentType?.lowercased() ?? ""
        let ext = attachment.fileExtension
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type == "application/pdf" || ext == "pdf" { return "doc.richtext" }
        if type.contains("zip") || type.contains("compressed")
            || ["zip", "gz", "tar", "7z", "rar", "xz"].contains(ext) {
            return "doc.zipper"
        }
        return "doc"
    }

    private func primaryAction() {
        switch phase {
        case .idle, .failed:
            startDownload()
        case .downloaded(let file):
            quickLookItem = file
        case .downloading:
            break
        }
    }

    private func startDownload() {
        guard let source = sourceURL else { return }
        phase = .downloading(0)
        Task {
            do {
                let file = try await AttachmentDownloader.download(
                    from: source,
                    id: attachment.id.stringValue,
                    filename: attachment.filename
                ) { fraction in
                    if case .downloading = phase {
                        phase = .downloading(fraction)
                    }
                }
                phase = .downloaded(file)
            } catch {
                phase = .failed
            }
        }
    }

    #if os(macOS)
    private func saveToDisk(_ source: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.begin { response in
            guard response == .OK, let target = panel.url else { return }
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: source, to: target)
        }
    }
    #endif
}

/// Small determinate ring for the chip while a file streams down.
private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.faint, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, fraction)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 22, height: 22)
        .animation(.linear(duration: 0.2), value: fraction)
    }
}

enum AttachmentDownloader {
    /// Where a finished download lands, keyed by attachment id so two files
    /// with the same name can't clobber each other.
    nonisolated static func destination(id: String, filename: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CornFluxDownloads", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Streams the file down off the main actor, reporting progress as it
    /// goes, and returns the finished file's location.
    nonisolated static func download(
        from source: URL,
        id: String,
        filename: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: source)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let expected = response.expectedContentLength
        var data = Data()
        if expected > 0 { data.reserveCapacity(Int(expected)) }
        var lastReported = 0
        for try await byte in bytes {
            data.append(byte)
            if expected > 0, data.count - lastReported >= 262_144 {
                lastReported = data.count
                let fraction = Double(data.count) / Double(expected)
                await progress(fraction)
            }
        }
        let dest = destination(id: id, filename: filename)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest)
        return dest
    }
}

// MARK: - Shared helpers

private func formatBytes(_ size: Int?) -> String? {
    guard let size else { return nil }
    return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
}

private extension Attachment {
    var fileExtension: String {
        (filename as NSString).pathExtension.lowercased()
    }

    var isMarkdownFile: Bool {
        ["md", "markdown"].contains(fileExtension)
    }

    /// Types worth showing as inline text. Content type when the server
    /// sends one, otherwise a known text extension.
    var isTextLike: Bool {
        if let type = contentType?.lowercased() {
            if type.hasPrefix("text/") { return true }
            if type.hasPrefix("application/json") || type.hasPrefix("application/xml") { return true }
        }
        return [
            "txt", "md", "markdown", "log", "json", "csv", "yaml", "yml",
            "xml", "diff", "patch", "swift", "py", "js", "ts", "sh", "rb",
            "toml", "ini", "cfg",
        ].contains(fileExtension)
    }
}
