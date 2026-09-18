import Foundation

/// ChatGPT 网页附件的类别。类别只用于校验大小和 UI 展示，实际解析仍由 ChatGPT 完成。
public enum DiscussionAttachmentKind: String, Codable, Sendable, CaseIterable {
    case document
    case spreadsheet
    case presentation
    case text
    case image

    public var displayName: String {
        switch self {
        case .document: return "文档"
        case .spreadsheet: return "表格"
        case .presentation: return "演示文稿"
        case .text: return "文本/代码"
        case .image: return "图片"
        }
    }
}

/// 一项由用户选中的本地文件。
///
/// 只保存路径和文件元数据，不把文件内容复制进 AIRunner 数据库；发送时由真实
/// Chrome 会话把这个路径交给网页文件选择器。路径是用户主动选择的本地文件，
/// 运行前仍会重新检查文件是否存在、类型和大小。
public struct DiscussionAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let fileName: String
    public let byteSize: Int64
    public let kind: DiscussionAttachmentKind

    public init(
        id: String? = nil,
        path: String,
        fileName: String? = nil,
        byteSize: Int64,
        kind: DiscussionAttachmentKind
    ) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        self.id = id ?? standardized
        self.path = standardized
        self.fileName = fileName ?? URL(fileURLWithPath: standardized).lastPathComponent
        self.byteSize = byteSize
        self.kind = kind
    }

    public var url: URL { URL(fileURLWithPath: path) }

    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

/// 与 ChatGPT 网页文件上传保持一致的本地筛选策略。
///
/// 官方文档明确列出 XLSX、XLS、CSV、TSV、DOCX、PPTX、PDF、TXT，并说明支持
/// 常见文本、表格、演示文稿和文档扩展名。这里额外纳入常见代码/图片扩展名，
/// 但明确排除 .gdoc、压缩包、可执行文件和媒体文件，避免把 ChatGPT 未承诺支持
/// 的内容静默送入网页。
public enum ChatGPTAttachmentPolicy {
    public static let maxFilesPerMessage = 20
    public static let maxFileBytes: Int64 = 512 * 1024 * 1024
    public static let maxImageBytes: Int64 = 20 * 1024 * 1024
    public static let maxSpreadsheetBytes: Int64 = 50 * 1024 * 1024

    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "dot", "dotx", "rtf", "odt"
    ]
    private static let spreadsheetExtensions: Set<String> = [
        "xls", "xlsx", "xlsm", "csv", "tsv", "ods"
    ]
    private static let presentationExtensions: Set<String> = [
        "ppt", "pptx", "pps", "ppsx", "odp"
    ]
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "log", "json", "jsonl", "xml", "yaml", "yml", "toml",
        "html", "htm", "css", "js", "jsx", "mjs", "ts", "tsx", "py", "ipynb",
        "java", "c", "h", "cc", "cpp", "cxx", "hpp", "cs", "go", "rs", "rb",
        "php", "swift", "sh", "bash", "zsh", "fish", "sql", "graphql", "ini", "conf"
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff"
    ]

    public static func kind(for url: URL) -> DiscussionAttachmentKind? {
        let ext = url.pathExtension.lowercased()
        if documentExtensions.contains(ext) { return .document }
        if spreadsheetExtensions.contains(ext) { return .spreadsheet }
        if presentationExtensions.contains(ext) { return .presentation }
        if textExtensions.contains(ext) { return .text }
        if imageExtensions.contains(ext) { return .image }
        return nil
    }

    public static func validationError(
        for url: URL,
        byteSize: Int64,
        kind: DiscussionAttachmentKind? = nil
    ) -> String? {
        guard let kind = kind ?? self.kind(for: url) else {
            return "ChatGPT 网页不支持此文件格式：\(url.lastPathComponent)"
        }
        if byteSize > maxFileBytes {
            return "文件超过 512 MB：\(url.lastPathComponent)"
        }
        if kind == .image, byteSize > maxImageBytes {
            return "图片超过 20 MB：\(url.lastPathComponent)"
        }
        if kind == .spreadsheet, byteSize > maxSpreadsheetBytes {
            return "表格超过约 50 MB：\(url.lastPathComponent)"
        }
        return nil
    }

    public static func attachment(for url: URL) throws -> DiscussionAttachment {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw AppError.invalidRequest("不是普通文件：\(url.lastPathComponent)")
        }
        let byteSize = Int64(values.fileSize ?? 0)
        guard let kind = kind(for: url) else {
            throw AppError.invalidRequest("ChatGPT 网页不支持此文件格式：\(url.lastPathComponent)")
        }
        if let error = validationError(for: url, byteSize: byteSize, kind: kind) {
            throw AppError.invalidRequest(error)
        }
        return DiscussionAttachment(path: url.path, byteSize: byteSize, kind: kind)
    }
}

public struct DiscussionAttachmentScanResult: Sendable, Equatable {
    public let attachments: [DiscussionAttachment]
    public let skippedFileNames: [String]
    public let truncated: Bool

    public init(
        attachments: [DiscussionAttachment],
        skippedFileNames: [String] = [],
        truncated: Bool = false
    ) {
        self.attachments = attachments
        self.skippedFileNames = skippedFileNames
        self.truncated = truncated
    }
}

/// 递归扫描用户选择的目录，只返回 ChatGPT 网页支持且通过大小检查的文件。
public enum DiscussionAttachmentScanner {
    public static func scan(folder: URL) -> DiscussionAttachmentScanResult {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return DiscussionAttachmentScanResult(attachments: [], skippedFileNames: [folder.lastPathComponent])
        }

        var accepted: [DiscussionAttachment] = []
        var skipped: [String] = []
        var truncated = false
        for case let url as URL in enumerator {
            guard accepted.count < ChatGPTAttachmentPolicy.maxFilesPerMessage else {
                truncated = true
                break
            }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            guard let kind = ChatGPTAttachmentPolicy.kind(for: url) else {
                skipped.append(url.lastPathComponent)
                continue
            }
            let byteSize = Int64(values.fileSize ?? 0)
            if ChatGPTAttachmentPolicy.validationError(
                for: url, byteSize: byteSize, kind: kind
            ) != nil {
                skipped.append(url.lastPathComponent)
                continue
            }
            accepted.append(
                DiscussionAttachment(path: url.path, byteSize: byteSize, kind: kind)
            )
        }
        accepted.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return DiscussionAttachmentScanResult(
            attachments: accepted,
            skippedFileNames: skipped.sorted(),
            truncated: truncated
        )
    }
}
