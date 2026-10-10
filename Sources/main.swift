import AppKit

// Inspect the built edition without launching a window or opening any session.
if CommandLine.arguments.contains("--build-info") {
    let info = ["name": AppEdition.name, "version": AppEdition.version,
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "sessionDirectory": AppEdition.sessionDirectory, "renderer": AppEdition.renderer]
    let data = try! JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self)); exit(0)
}

#if TEXTLET_TESTING
if CommandLine.arguments.contains("--text-file-test") {
    do { try runTextFileTests(); try runFileAssociationTests(); exit(0) }
    catch { fputs("\(error)\n", stderr); exit(1) }
}

if CommandLine.arguments.contains("--syntax-test") {
    do { try runSyntaxTests(); exit(0) }
    catch { fputs("\(error)\n", stderr); exit(1) }
}

if CommandLine.arguments.contains("--self-test") {
    do { try runSelfTests(); exit(0) }
    catch { fputs("\(error)\n", stderr); exit(1) }
}
#endif

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let controller = Textlet()
application.delegate = controller
application.run()
