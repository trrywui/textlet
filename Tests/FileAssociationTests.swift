import AppKit

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
    try expect(documentTypes.contains { ($0["LSItemContentTypes"] as? [String])?.contains("public.data") == true
        && ($0["CFBundleTypeRole"] as? String) == "Editor"
        && ($0["LSHandlerRank"] as? String) == "Alternate" },
               "unknown file types are declared as alternate openers without entering the default-association catalog")
    try expect(contentTypes.contains("public.text"), "known text subtypes are offered as open-with candidates")
    print("All file association tests passed.")
}

private final class FakeFileAssociationService: FileAssociationServicing {
    let items = Array(FileAssociationCatalog.items().prefix(3))
    var defaults = Set<String>()
    var attempts: [String: Int] = [:]
    var failuresRemaining: [String: Int] = [:]
    init() {
        for item in items.prefix(2) { failuresRemaining[item.identifier] = 1 }
    }
    func currentStates() -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.identifier, defaults.contains($0.identifier)) })
    }
    func isTextletDefault(for item: FileAssociationItem) -> Bool { defaults.contains(item.identifier) }
    func setDefault(for item: FileAssociationItem, completion: @escaping (Result<Void, FileAssociationFailure>) -> Void) {
        attempts[item.identifier, default: 0] += 1
        if failuresRemaining[item.identifier, default: 0] > 0 {
            failuresRemaining[item.identifier, default: 0] -= 1
            completion(.failure(.system("模拟设置失败")))
        } else {
            defaults.insert(item.identifier)
            completion(.success(()))
        }
    }
}

func checkFileAssociationRetry() throws -> [String: Bool] {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    var checks: [String: Bool] = [:]
    for cancelFirst in [false, true] {
        let service = FakeFileAssociationService()
        let controller = FileAssociationWindowController(service: service)
        defer { controller.close() }
        let buttons = descendants(controller.window!.contentView!).compactMap { $0 as? NSButton }
        func click(_ title: String) throws {
            guard let button = buttons.first(where: { $0.title == title }), button.isEnabled else {
                throw SessionError.invalid("TEST FAILED: association button unavailable: \(title)")
            }
            button.performClick(nil)
        }
        // Match by type, since the UI presents rows in alphabetical order.
        let toggles = service.items.compactMap { item in
            buttons.first { $0.action == NSSelectorFromString("toggle:")
                && $0.accessibilityLabel() == "选择\(item.title)" }
        }
        guard toggles.count == service.items.count else { throw SessionError.invalid("TEST FAILED: association checkboxes missing") }
        try click("全选")
        try click("设为默认")
        controller.refreshFromApplicationActivation()
        checks["failedAssociationSelectionSurvivesRefresh-\(cancelFirst)"] = toggles.allSatisfy { $0.state == .on }
            && service.items.allSatisfy { service.attempts[$0.identifier] == 1 }
        if cancelFirst { toggles[0].performClick(nil) }
        try click("重试失败项")
        let first = service.items[0].identifier, second = service.items[1].identifier, third = service.items[2].identifier
        checks["associationRetryCallsOnlyPendingFailures-\(cancelFirst)"] = service.attempts[first] == (cancelFirst ? 1 : 2)
            && service.attempts[second] == 2 && service.attempts[third] == 1
            && service.defaults.contains(second) && service.defaults.contains(third)
            && service.defaults.contains(first) == !cancelFirst
        checks["associationRetryRespectsManualDeselection-\(cancelFirst)"] = toggles[0].state == (cancelFirst ? .off : .on)
            && buttons.first { $0.title == "重试失败项" }?.isHidden == true
    }
    return checks
}
