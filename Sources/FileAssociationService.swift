import AppKit
import UniformTypeIdentifiers

struct FileAssociationItem {
    let identifier: String
    let type: UTType?
    var extensions: [String]
    let resolutionError: String?

    var title: String {
        extensions.map { ".\($0)" }.joined(separator: " / ")
    }

    var isAvailable: Bool { type != nil && resolutionError == nil }
}

enum FileAssociationFailure: LocalizedError {
    case applicationUnavailable
    case typeUnavailable(String)
    case system(String)
    case notEffective

    var errorDescription: String? {
        switch self {
        case .applicationUnavailable:
            return "找不到当前正式版 Textlet 应用，暂时无法修改文件关联。"
        case .typeUnavailable(let detail):
            return detail
        case .system(let detail):
            return detail.isEmpty ? "系统拒绝了这次文件关联设置。" : detail
        case .notEffective:
            return "系统没有确认这次设置已经生效，可能被用户取消或系统拒绝。"
        }
    }
}

enum FileAssociationCatalog {
    enum Parent {
        case sourceCode
        case text
        case plainText
        case script
        case shellScript
    }

    struct Specification {
        let fileExtension: String
        let declaredIdentifier: String
        let parent: Parent
    }

    // The imported identifiers are public format identifiers, not Textlet-owned
    // document formats. Existing non-dynamic system types always take priority.
    static let specifications: [Specification] = [
        Specification(fileExtension: "sql", declaredIdentifier: "public.sql", parent: .sourceCode),
        Specification(fileExtension: "rs", declaredIdentifier: "public.rust-source", parent: .sourceCode),
        Specification(fileExtension: "yml", declaredIdentifier: "public.yaml", parent: .text),
        Specification(fileExtension: "yaml", declaredIdentifier: "public.yaml", parent: .text),
        Specification(fileExtension: "toml", declaredIdentifier: "public.toml", parent: .plainText),
        Specification(fileExtension: "java", declaredIdentifier: "public.java-source", parent: .sourceCode),
        Specification(fileExtension: "txt", declaredIdentifier: "public.plain-text", parent: .text),
        Specification(fileExtension: "py", declaredIdentifier: "public.python-script", parent: .shellScript),
        Specification(fileExtension: "sh", declaredIdentifier: "public.shell-script", parent: .script),
        Specification(fileExtension: "json", declaredIdentifier: "public.json", parent: .text),
        Specification(fileExtension: "md", declaredIdentifier: "net.daringfireball.markdown", parent: .plainText),
        Specification(fileExtension: "log", declaredIdentifier: "public.log", parent: .plainText),
        Specification(fileExtension: "ini", declaredIdentifier: "public.ini", parent: .plainText),
        Specification(fileExtension: "conf", declaredIdentifier: "public.conf", parent: .plainText)
    ]

    static func items() -> [FileAssociationItem] {
        var items: [FileAssociationItem] = []
        var indexes: [String: Int] = [:]
        for specification in specifications {
            let resolved = resolve(specification)
            let identifier = resolved.type?.identifier ?? "unresolved.\(specification.fileExtension)"
            if let index = indexes[identifier] {
                items[index].extensions.append(specification.fileExtension)
            } else {
                indexes[identifier] = items.count
                items.append(FileAssociationItem(identifier: identifier, type: resolved.type,
                    extensions: [specification.fileExtension], resolutionError: resolved.error))
            }
        }
        return items
    }

    private static func resolve(_ specification: Specification) -> (type: UTType?, error: String?) {
        if let systemType = UTType(filenameExtension: specification.fileExtension, conformingTo: .data),
           !isBroad(systemType), !systemType.identifier.hasPrefix("dyn.") {
            return (systemType, nil)
        }

        let imported = UTType(importedAs: specification.declaredIdentifier,
                              conformingTo: parentType(specification.parent))
        guard !isBroad(imported) else {
            return (nil, "系统无法为 .\(specification.fileExtension) 提供可靠的文件类型标识。")
        }
        return (imported, nil)
    }

    private static func parentType(_ parent: Parent) -> UTType {
        switch parent {
        case .sourceCode: return .sourceCode
        case .text: return .text
        case .plainText: return .plainText
        case .script: return .script
        case .shellScript: return .shellScript
        }
    }

    private static func isBroad(_ type: UTType) -> Bool {
        ["public.data", "public.item"].contains(type.identifier)
    }
}

final class FileAssociationService {
    static let formalBundleIdentifier = "io.github.trrywui.textlet"

    let items: [FileAssociationItem]
    let applicationURL: URL
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) throws {
        self.workspace = workspace
        self.applicationURL = try Self.resolveApplicationURL(workspace: workspace)
        self.items = FileAssociationCatalog.items()
    }

    func currentStates() -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.identifier, isTextletDefault(for: $0)) })
    }

    func isTextletDefault(for item: FileAssociationItem) -> Bool {
        guard let type = item.type,
              let defaultURL = workspace.urlForApplication(toOpen: type) else { return false }
        return Self.isTextletApplication(defaultURL, matching: applicationURL)
    }

    func setDefault(for item: FileAssociationItem,
                    completion: @escaping (Result<Void, FileAssociationFailure>) -> Void) {
        guard let type = item.type, item.resolutionError == nil else {
            completion(.failure(.typeUnavailable(item.resolutionError ?? "系统无法识别这个文件类型。")))
            return
        }
        guard Self.isTextletApplication(applicationURL, matching: applicationURL) else {
            completion(.failure(.applicationUnavailable))
            return
        }

        workspace.setDefaultApplication(at: applicationURL, toOpen: type) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(.system(error.localizedDescription)))
                    return
                }
                guard let self else {
                    completion(.failure(.applicationUnavailable))
                    return
                }
                // Launch Services may ask for confirmation asynchronously. The
                // callback alone is not treated as success; query the real state.
                completion(self.isTextletDefault(for: item) ? .success(()) : .failure(.notEffective))
            }
        }
    }

    private static func resolveApplicationURL(workspace: NSWorkspace) throws -> URL {
        guard Bundle.main.bundleIdentifier == formalBundleIdentifier else {
            throw FileAssociationFailure.applicationUnavailable
        }

        let currentURL = canonical(Bundle.main.bundleURL)
        var candidates: [URL] = []
        if let preferred = workspace.urlForApplication(withBundleIdentifier: formalBundleIdentifier) {
            candidates.append(preferred)
        }
        candidates.append(contentsOf: workspace.urlsForApplications(withBundleIdentifier: formalBundleIdentifier))
        candidates.append(currentURL)

        var seen = Set<String>()
        for candidate in candidates {
            let normalized = canonical(candidate)
            guard seen.insert(normalized.path).inserted else { continue }
            guard Bundle(url: normalized)?.bundleIdentifier == formalBundleIdentifier else { continue }
            return normalized
        }
        throw FileAssociationFailure.applicationUnavailable
    }

    private static func isTextletApplication(_ url: URL, matching target: URL) -> Bool {
        guard Bundle(url: url)?.bundleIdentifier == formalBundleIdentifier else { return false }
        return canonical(url).path == canonical(target).path
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
