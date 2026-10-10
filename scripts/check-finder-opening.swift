import AppKit
import CoreServices

// Launch a uniquely identified copy, so file events cannot reach the user's Textlet session.
func checkFinderOpening() throws {
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "FinderOpening", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: swift check-finder-opening.swift <Textlet.app> <output-directory>"])
    }
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let clone = root.appendingPathComponent("FinderProbe.app", isDirectory: true)
    try FileManager.default.copyItem(at: source, to: clone)
    let infoURL = clone.appendingPathComponent("Contents/Info.plist")
    var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
    info["CFBundleIdentifier"] = "io.github.trrywui.textlet.finder-probe.\(UUID().uuidString.lowercased())"
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
    let signer = Process(); signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    signer.arguments = ["--force", "--sign", "-", clone.path]; try signer.run(); signer.waitUntilExit()
    guard signer.terminationStatus == 0 else { throw NSError(domain: "FinderOpening", code: 2) }
    var running: NSRunningApplication?
    defer {
        if let running {
            _ = running.terminate()
            let deadline = Date().addingTimeInterval(5)
            while !running.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            if !running.isTerminated { _ = running.forceTerminate() }
        }
        let unregister = Process()
        unregister.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        unregister.arguments = ["-u", clone.path]
        do { try unregister.run(); unregister.waitUntilExit() } catch {}
    }
    let cold = root.appendingPathComponent("cold.textletprobe")
    let warm = root.appendingPathComponent("warm.xml")
    let extensionless = root.appendingPathComponent("Dockerfile")
    let fixtures = [cold, warm, extensionless] + ["table.csv", ".env", "plain.txt"].map { root.appendingPathComponent($0) }
    for url in fixtures { try Data("plain text 中文🙂\n".utf8).write(to: url) }
    let defaultsBefore = fixtures.map { NSWorkspace.shared.urlForApplication(toOpen: $0)?.path ?? "" }
    let status = LSRegisterURL(clone as CFURL, true)
    guard status == noErr else { throw NSError(domain: "FinderOpening", code: Int(status)) }
    func wait(_ ready: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(15)
        while !ready() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard ready() else { throw NSError(domain: "FinderOpening", code: 3, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for file delivery"] ) }
    }
    let session = root.appendingPathComponent("session", isDirectory: true)
    func openedPaths() -> [String] {
        guard let data = try? Data(contentsOf: session.appendingPathComponent("session.json")),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notes = value["notes"] as? [[String: Any]] else { return [] }
        return notes.compactMap { ($0["file"] as? [String: Any])?["path"] as? String }
    }
    func launch(_ files: [URL], newInstance: Bool) throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = newInstance
        configuration.arguments = ["--data-dir", session.path]
        var delivered = false, result: NSRunningApplication?, failure: Error?
        NSWorkspace.shared.open(files, withApplicationAt: clone, configuration: configuration) { app, error in
            result = app; failure = error; delivered = true
        }
        try wait { delivered }
        if let failure { throw failure }
        guard let result, result.bundleIdentifier == info["CFBundleIdentifier"] as? String else {
            throw NSError(domain: "FinderOpening", code: 4)
        }
        return result
    }
    running = try launch([cold], newInstance: true)
    try wait { openedPaths().contains(cold.resolvingSymlinksInPath().path) }
    let coldPID = running!.processIdentifier
    let warmApp = try launch([warm, extensionless, cold], newInstance: false)
    try wait { openedPaths().count == 3 }
    let paths = openedPaths()
    let defaultsAfter = fixtures.map { NSWorkspace.shared.urlForApplication(toOpen: $0)?.path ?? "" }
    var checks = ["coldFileDelivered": paths.contains(cold.resolvingSymlinksInPath().path),
        "warmFileDelivered": paths.contains(warm.resolvingSymlinksInPath().path),
        "extensionlessFileDelivered": paths.contains(extensionless.resolvingSymlinksInPath().path),
        "warmRequestReusesProcess": warmApp.processIdentifier == coldPID,
        "duplicateReusesTab": paths.count == 3 && Set(paths).count == 3,
        "defaultApplicationsPreserved": defaultsBefore == defaultsAfter]
    // The system's default acceptance policy is also used to filter application choices.
    for url in fixtures {
        var accepts = DarwinBoolean(false)
        let status = LSCanURLAcceptURL(url as CFURL, clone as CFURL, .all, .acceptDefault, &accepts)
        checks["defaultFilterAccepts-\(url.lastPathComponent)"] = status == noErr && accepts.boolValue
    }
    let report: [String: Any] = ["checks": checks, "defaultsBefore": defaultsBefore,
        "defaultsAfter": defaultsAfter, "fixtureNames": fixtures.map(\.lastPathComponent),
        "openedPaths": paths, "isolatedBundleIdentifier": info["CFBundleIdentifier"]!,
        "scope": "real Launch Services cold/warm file events in an isolated app copy; Finder menu visuals are not automated"]
    let output = root.appendingPathComponent("result.json")
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    print(output.path)
    guard checks.values.allSatisfy({ $0 }) else { throw NSError(domain: "FinderOpening", code: 5) }
}

do { try checkFinderOpening() }
catch { fputs("\(error)\n", stderr); exit(1) }
