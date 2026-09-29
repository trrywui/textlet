import AppKit

// Inspect the built edition without launching a window or opening any session.
if CommandLine.arguments.contains("--build-info") {
    let info = ["name": AppEdition.name, "version": AppEdition.version,
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "sessionDirectory": AppEdition.sessionDirectory, "renderer": AppEdition.renderer]
    let data = try! JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self)); exit(0)
}

if CommandLine.arguments.contains("--syntax-test") {
    do { try runSyntaxTests(); exit(0) }
    catch { fputs("\(error)\n", stderr); exit(1) }
}

if CommandLine.arguments.contains("--self-test") {
    do { try runSelfTests(); exit(0) }
    catch { fputs("\(error)\n", stderr); exit(1) }
}

if (["--rendering-comparison", "--real-usage-benchmark", "--rows-check", "--lifecycle-check", "--window-check", "--appearance-check", "--benchmark", "--restore-check", "--feature-benchmark", "--feature-restore", "--interaction-benchmark"].contains(where: CommandLine.arguments.contains))
    && Textlet.argument("--data-dir") == nil {
    fputs("Tests require an isolated --data-dir.\n", stderr)
    exit(2)
}

if (["--real-usage-benchmark", "--rendering-comparison", "--rows-check", "--lifecycle-check", "--appearance-check", "--benchmark", "--feature-benchmark", "--interaction-benchmark"].contains(where: CommandLine.arguments.contains)), let path = Textlet.argument("--data-dir"),
   FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("session.json").path) {
    fputs("Benchmark requires a fresh data directory; existing drafts will not be replaced.\n", stderr)
    exit(2)
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let controller = Textlet()
application.delegate = controller
application.run()
