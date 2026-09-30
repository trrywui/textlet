import Foundation

func runFileAssociationTests() throws {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SessionError.invalid("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }

    let items = FileAssociationCatalog.items()
    let extensions = Set(items.flatMap(\.extensions))
    try expect(extensions == Set(FileAssociationCatalog.specifications.map(\.fileExtension)),
               "all supported extensions resolve to a row")
    try expect(items.allSatisfy { $0.identifier != "public.data" && $0.identifier != "public.item" },
               "file association rows never fall back to public.data or public.item")
    let yamlRows = items.filter { $0.extensions.contains("yml") || $0.extensions.contains("yaml") }
    try expect(yamlRows.count == 1 && Set(yamlRows[0].extensions) == ["yml", "yaml"],
               "YAML extensions share one system type row")

    let info = Bundle.main.infoDictionary ?? [:]
    let documentTypes = (info["CFBundleDocumentTypes"] as? [[String: Any]]) ?? []
    let contentTypes = Set(documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
    let declared = Set(FileAssociationCatalog.specifications.map(\.declaredIdentifier))
    try expect(declared.isSubset(of: contentTypes),
               "every supported type is declared as an alternate editor")
    try expect(documentTypes.contains { ($0["CFBundleTypeRole"] as? String) == "Editor"
        && ($0["LSHandlerRank"] as? String) == "Alternate" },
               "document declaration uses Editor and Alternate")
    print("All file association tests passed.")
}
