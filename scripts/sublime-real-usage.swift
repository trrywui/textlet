import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

// Measure a separately launched Sublime Text instance with the same dense-input
// and scroll workload used by Tests/RealUsageBenchmark.swift. Normal mode
// drives editing through Sublime's own `subl --command` interface, which keeps
// the test independent of macOS Accessibility permission for synthetic keys.

private struct Sample: Codable {
    let stage: String
    let seconds: Double
    let cpuPercentOfOneCore: Double
    let cpuSeconds: Double
    let footprintMiB: Double
    let residentMiB: Double
    let familyFootprintMiB: Double
    let familyCPUSeconds: Double
    let frontmost: Bool
    let windowWidth: Double
    let windowHeight: Double
}

private struct StageSummary: Codable {
    let samples: Int
    let avgCpuPercentOfOneCore: Double
    let p50CpuPercentOfOneCore: Double
    let p95CpuPercentOfOneCore: Double
    let maxCpuPercentOfOneCore: Double
    let cpuSecondsMeasured: Double
    let maxFootprintMiB: Double
    let lastFootprintMiB: Double
    let maxFamilyFootprintMiB: Double
    let lastFamilyFootprintMiB: Double
}

private struct ProcessDescription: Codable {
    let pid: Int32
    let parentPID: Int32
    let name: String
    let path: String
}

private struct BenchmarkOutput: Codable {
    let mode: String
    let scope: String
    let appBuild: String
    let windowTarget: String
    let inputSent: Int
    let scrollSent: Int
    let initialFileLength: Int
    let finalFileLength: Int
    let checks: [String: Bool]
    let processes: [ProcessDescription]
    let summaries: [String: StageSummary]
    let samples: [Sample]
}

private struct ProcessUsage {
    let userNanoseconds: UInt64
    let systemNanoseconds: UInt64
    let footprint: UInt64
    let resident: UInt64

    var cpuNanoseconds: UInt64 { userNanoseconds + systemNanoseconds }
}

private struct ProcessRecord {
    let pid: pid_t
    let parentPID: pid_t
    let name: String
    let path: String
}

private struct FamilyUsage {
    let cpuNanoseconds: UInt64
    let footprint: UInt64
    let resident: UInt64
}

private func processPath(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = buffer.withUnsafeMutableBufferPointer { pointer in
        proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
    }
    guard length > 0 else { return "" }
    return String(cString: buffer)
}

private func processRecords() -> [ProcessRecord] {
    let requiredBytes = proc_listallpids(nil, 0)
    guard requiredBytes > 0 else { return [] }
    let capacity = Int(requiredBytes) / MemoryLayout<pid_t>.size + 256
    var pids = [pid_t](repeating: 0, count: capacity)
    let returnedBytes = pids.withUnsafeMutableBytes { rawBuffer in
        proc_listallpids(rawBuffer.baseAddress, Int32(rawBuffer.count))
    }
    guard returnedBytes > 0 else { return [] }
    let count = min(Int(returnedBytes) / MemoryLayout<pid_t>.size, pids.count)
    return pids.prefix(count).compactMap { (pid: pid_t) -> ProcessRecord? in
        guard pid > 0 else { return nil }
        var bsd = proc_bsdinfo()
        let result = withUnsafeMutablePointer(to: &bsd) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0,
                         UnsafeMutableRawPointer(pointer), Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        guard result > 0 else { return nil }
        let path = processPath(pid)
        let nameCapacity = MemoryLayout.size(ofValue: bsd.pbi_name)
        let name = withUnsafePointer(to: &bsd.pbi_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                String(cString: $0)
            }
        }
        return ProcessRecord(pid: pid, parentPID: pid_t(bsd.pbi_ppid), name: name, path: path)
    }
}

private func descendants(of root: pid_t, in records: [ProcessRecord]) -> Set<pid_t> {
    var result: Set<pid_t> = [root]
    var changed = true
    while changed {
        changed = false
        for record in records where result.contains(record.parentPID) && !result.contains(record.pid) {
            result.insert(record.pid)
            changed = true
        }
    }
    return result
}

private func usage(of pid: pid_t) -> ProcessUsage? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, Int32(RUSAGE_INFO_V4), $0)
        }
    }
    guard result == 0 else { return nil }
    return ProcessUsage(userNanoseconds: info.ri_user_time,
                        systemNanoseconds: info.ri_system_time,
                        footprint: info.ri_phys_footprint,
                        resident: info.ri_resident_size)
}

private func familyUsage(root: pid_t) -> FamilyUsage {
    let records = processRecords()
    let pids = descendants(of: root, in: records)
    var cpu: UInt64 = 0
    var footprint: UInt64 = 0
    var resident: UInt64 = 0
    for pid in pids {
        guard let item = usage(of: pid) else { continue }
        cpu += item.cpuNanoseconds
        footprint += item.footprint
        resident += item.resident
    }
    return FamilyUsage(cpuNanoseconds: cpu, footprint: footprint, resident: resident)
}

private func descriptions(for root: pid_t) -> [ProcessDescription] {
    let records = processRecords()
    let pids = descendants(of: root, in: records)
    return records.filter { pids.contains($0.pid) }
        .map { ProcessDescription(pid: $0.pid, parentPID: $0.parentPID, name: $0.name, path: $0.path) }
        .sorted { $0.pid < $1.pid }
}

private func frontmost(_ pid: pid_t) -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
}

private func frontWindowFrame(_ pid: pid_t) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any] ] else {
        return nil
    }
    for item in list {
        guard let ownerPID = item[kCGWindowOwnerPID as String] as? Int,
              ownerPID == Int(pid),
              let rawBounds = item[kCGWindowBounds as String] else {
            continue
        }
        let bounds = rawBounds as! CFDictionary
        var frame = CGRect.zero
        if CGRectMakeWithDictionaryRepresentation(bounds, &frame) {
            return frame
        }
    }
    return nil
}

private func windowFrame(_ pid: pid_t, named name: String? = nil) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any] ] else {
        return nil
    }
    var largest: CGRect?
    for item in list {
        guard let ownerPID = item[kCGWindowOwnerPID as String] as? Int,
              ownerPID == Int(pid),
              let layer = item[kCGWindowLayer as String] as? Int,
              layer == 0,
              let rawBounds = item[kCGWindowBounds as String] else {
            continue
        }
        if let name, (item[kCGWindowName as String] as? String) != name {
            continue
        }
        let bounds = rawBounds as! CFDictionary
        var frame = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(bounds, &frame) else { continue }
        if largest == nil || frame.width * frame.height > largest!.width * largest!.height {
            largest = frame
        }
    }
    return largest
}

private func dumpWindows(_ pid: pid_t) {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any] ] else {
        return
    }
    for item in list {
        guard let ownerPID = item[kCGWindowOwnerPID as String] as? Int,
              ownerPID == Int(pid) else { continue }
        let layer = item[kCGWindowLayer as String] as? Int ?? -1
        let name = item[kCGWindowName as String] as? String ?? ""
        var frame = CGRect.zero
        if let rawBounds = item[kCGWindowBounds as String] {
            let bounds = rawBounds as! CFDictionary
            _ = CGRectMakeWithDictionaryRepresentation(bounds, &frame)
        }
        print("window pid=\(ownerPID) layer=\(layer) frame=\(frame) name=\(name)")
    }
}

private func setWindowSize(_ pid: pid_t, title: String?, width: CGFloat, height: CGFloat) -> Bool {
    let application = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        return false
    }
    let window = title.flatMap { wanted in
        windows.first { element in
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let value = titleValue as? String else { return false }
            return value.contains(wanted)
        }
    } ?? windows.last
    guard let window else { return false }
    var size = CGSize(width: width, height: height)
    guard let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
    let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFTypeRef)
    return result == .success
}

private func pressDefaultButton(_ pid: pid_t) -> Bool {
    let application = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        return false
    }
    for window in windows {
        var buttonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDefaultButtonAttribute as CFString, &buttonValue) == .success,
              let buttonValue else {
            continue
        }
        let button = buttonValue as! AXUIElement
        if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            return true
        }
    }
    return false
}

private func sendKey(_ pid: pid_t, keyCode: CGKeyCode, modifiers: CGEventFlags = [], unicode: String? = nil) {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
        return
    }
    down.flags = modifiers
    up.flags = modifiers
    if let unicode {
        var units = Array(unicode.utf16)
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

private func sendScroll(_ pid: pid_t, delta: Int32) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                              wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else {
        return
    }
    event.post(tap: .cghidEventTap)
}

private func click(_ point: CGPoint) {
    // CGWindow bounds use a top-left origin; CGEvent mouse locations use a
    // bottom-left origin on this macOS display.
    let screenHeight = NSScreen.screens.first?.frame.height ?? 1050
    let eventPoint = CGPoint(x: point.x, y: screenHeight - point.y)
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                             mouseCursorPosition: eventPoint, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                           mouseCursorPosition: eventPoint, mouseButton: .left) else {
        return
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

private func wait(_ seconds: Double) {
    Thread.sleep(forTimeInterval: seconds)
}

private final class Runner {
    let appURL: URL
    let outputURL: URL
    let fixtureURL: URL
    let denseText: String
    let safeMode: Bool
    let cliURL: URL
    let started = ProcessInfo.processInfo.systemUptime
    let launchProcess = Process()
    var app: NSRunningApplication!
    var pid: pid_t = 0
    var stage = "setup"
    var samples: [Sample] = []
    var inputSent = 0
    var scrollSent = 0
    var initialFileLength = 0
    var finalFileLength = 0
    var lastUsage = FamilyUsage(cpuNanoseconds: 0, footprint: 0, resident: 0)
    var lastWall = ProcessInfo.processInfo.systemUptime
    var lastMainUsage = ProcessUsage(userNanoseconds: 0, systemNanoseconds: 0,
                                     footprint: 0, resident: 0)

    init(appURL: URL, outputURL: URL, safeMode: Bool) throws {
        self.appURL = appURL
        self.outputURL = outputURL
        self.safeMode = safeMode
        self.cliURL = appURL.appendingPathComponent("Contents/SharedSupport/bin/subl")
        let directory = URL(fileURLWithPath: "/tmp/textlet-sublime-real-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fixtureURL = directory.appendingPathComponent("textlet-sublime-real-usage-\(UUID().uuidString).txt")
        self.denseText = (1...240).map {
            "第 \($0) 行：中文🙂 English 0123456789 " + String(repeating: "abcdefgh 中文 ", count: 10)
        }.joined(separator: "\n")
        try denseText.write(to: fixtureURL, atomically: true, encoding: .utf8)
        self.initialFileLength = denseText.utf16.count
    }

    func launch() throws {
        let executable = appURL.appendingPathComponent("Contents/MacOS/sublime_text")
        launchProcess.executableURL = executable
        launchProcess.arguments = (safeMode ? ["--safe-mode"] : []) + ["--new-window", fixtureURL.path]
        try launchProcess.run()
        pid = launchProcess.processIdentifier

        for _ in 0..<80 {
            wait(0.25)
            if launchProcess.isRunning,
               let candidate = NSRunningApplication(processIdentifier: pid),
               !candidate.isTerminated {
                app = candidate
                candidate.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                wait(1)
                return
            }
        }
        throw NSError(domain: "SublimeBenchmark", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "没有发现由本次测试新启动的 Sublime Text 进程，已停止以避免碰到用户原有进程"])
    }

    func prepareWindow() {
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        if safeMode, let frame = frontWindowFrame(pid), frame.width < 700 || frame.height < 300 {
            // The first safe-mode launch shows a small modal acknowledgement.
            // Only press Return when that small window is present, so a normal
            // editor window never receives an extra newline.
            click(CGPoint(x: frame.maxX - 70, y: frame.maxY - 35))
            wait(0.3)
            _ = pressDefaultButton(pid)
            sendKey(pid, keyCode: 36)
            wait(0.8)
            sendKey(pid, keyCode: 53)
            wait(0.5)
        } else if let frame = frontWindowFrame(pid), frame.width < 700 || frame.height < 300 {
            // Normal mode can show a small update window. Escape closes it
            // without activating a download button.
            sendKey(pid, keyCode: 53)
            wait(0.5)
        }
        if !safeMode {
            // Re-select this unique fixture through Sublime's own CLI. The
            // user's normal session may have restored several other windows.
            openFixtureThroughCLI()
        }
        _ = setWindowSize(pid, title: fixtureURL.lastPathComponent, width: 1680, height: 940)
        wait(1)
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        wait(0.5)
        if let frame = windowFrame(pid, named: fixtureURL.lastPathComponent) ?? windowFrame(pid) {
            click(CGPoint(x: frame.midX, y: frame.midY))
            wait(0.3)
        }
        sendKey(pid, keyCode: 125, modifiers: .maskCommand)
        wait(0.5)
        if !safeMode {
            runEditorCommand("move_to {\"to\":\"eof\"}")
        }
    }

    @discardableResult
    func runSublimeCLI(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func openFixtureThroughCLI() {
        _ = runSublimeCLI(["-n", fixtureURL.path])
        wait(0.5)
    }

    func runEditorCommand(_ command: String) {
        _ = runSublimeCLI(["--command", command])
    }

    func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let family = familyUsage(root: pid)
        let main = usage(of: pid) ?? lastMainUsage
        let wallDelta = max(0.000001, now - lastWall)
        let cpuDelta = Double(family.cpuNanoseconds >= lastUsage.cpuNanoseconds
                              ? family.cpuNanoseconds - lastUsage.cpuNanoseconds : 0) / 1_000_000_000
        let frame = windowFrame(pid, named: fixtureURL.lastPathComponent) ?? windowFrame(pid) ?? .zero
        samples.append(Sample(
            stage: stage,
            seconds: now - started,
            cpuPercentOfOneCore: cpuDelta / wallDelta * 100,
            cpuSeconds: Double(family.cpuNanoseconds) / 1_000_000_000,
            footprintMiB: Double(main.footprint) / 1_048_576,
            residentMiB: Double(main.resident) / 1_048_576,
            familyFootprintMiB: Double(family.footprint) / 1_048_576,
            familyCPUSeconds: Double(family.cpuNanoseconds) / 1_000_000_000,
            frontmost: frontmost(pid),
            windowWidth: frame.width,
            windowHeight: frame.height
        ))
        lastUsage = family
        lastMainUsage = main
        lastWall = now
    }

    func sampleFor(_ seconds: Double) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            sample()
            wait(0.1)
        }
        sample()
    }

    func beginStage(_ value: String) {
        stage = value
        sample()
    }

    func input() {
        if !safeMode {
            openFixtureThroughCLI()
            runEditorCommand("move_to {\"to\":\"eof\"}")
            wait(0.3)
        }
        beginStage("continuous-input")
        let characters = Array("asdfjklqwertyuiopzxcvbnm ")
        for index in 0..<160 {
            let character = characters[index % characters.count]
            if safeMode {
                let keyCode: CGKeyCode = [
                    "a": 0, "s": 1, "d": 2, "f": 3, "j": 38, "k": 40,
                    "l": 37, "q": 12, "w": 13, "e": 14, "r": 15, "t": 17,
                    "y": 16, "u": 32, "i": 34, "o": 31, "p": 35, "z": 6,
                    "x": 7, "c": 8, "v": 9, "b": 11, "n": 45, "m": 46,
                    " ": 49
                ][character] ?? 0
                sendKey(pid, keyCode: keyCode, unicode: String(character))
            } else {
                runEditorCommand("insert_snippet {\"contents\":\"\(character)\"}")
            }
            inputSent += 1
            sample()
            wait(0.05)
        }
        if safeMode {
            sendKey(pid, keyCode: 1, modifiers: .maskCommand)
        } else {
            runEditorCommand("save")
        }
        wait(1)
        finalFileLength = (try? String(contentsOf: fixtureURL, encoding: .utf8).utf16.count) ?? initialFileLength
        beginStage("input-idle")
        sampleFor(8)
    }

    func scroll() {
        if !safeMode {
            openFixtureThroughCLI()
            runEditorCommand("move_to {\"to\":\"bof\"}")
            wait(0.3)
        }
        beginStage("continuous-scroll")
        if safeMode {
            sendKey(pid, keyCode: 126, modifiers: .maskCommand)
        } else {
            runEditorCommand("show_at_center")
        }
        wait(0.5)
        for index in 0..<160 {
            if safeMode {
                sendScroll(pid, delta: index < 80 ? -55 : 55)
            } else {
                let amount = index < 80 ? -5.0 : 5.0
                runEditorCommand("scroll_lines {\"amount\":\(amount)}")
            }
            scrollSent += 1
            sample()
            wait(0.05)
        }
        wait(1)
        beginStage("scroll-idle")
        sampleFor(8)
    }

    func summary(_ name: String) -> StageSummary {
        let values = samples.filter { $0.stage == name }
        let cpu = values.map(\.cpuPercentOfOneCore).sorted()
        let cpuSeconds = values.map(\.cpuSeconds)
        let footprints = values.map(\.footprintMiB)
        let familyFootprints = values.map(\.familyFootprintMiB)
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            return values[min(values.count - 1, Int(Double(values.count) * fraction))]
        }
        let cpuTime = cpuSeconds.count > 1 ? max(0, cpuSeconds.last! - cpuSeconds.first!) : 0
        return StageSummary(
            samples: values.count,
            avgCpuPercentOfOneCore: cpu.isEmpty ? 0 : cpu.reduce(0, +) / Double(cpu.count),
            p50CpuPercentOfOneCore: percentile(cpu, 0.5),
            p95CpuPercentOfOneCore: percentile(cpu, 0.95),
            maxCpuPercentOfOneCore: cpu.max() ?? 0,
            cpuSecondsMeasured: cpuTime,
            maxFootprintMiB: footprints.max() ?? 0,
            lastFootprintMiB: footprints.last ?? 0,
            maxFamilyFootprintMiB: familyFootprints.max() ?? 0,
            lastFamilyFootprintMiB: familyFootprints.last ?? 0
        )
    }

    func finish() throws {
        sample()
        let measured = samples.filter { $0.stage != "setup" }
        let sizes = measured.map { ($0.windowWidth, $0.windowHeight) }
        let allForeground = measured.allSatisfy(\.frontmost)
        let sizeOK = sizes.contains { $0.0 >= 1600 && $0.1 >= 850 }
        let summaries = ["continuous-input", "input-idle", "continuous-scroll", "scroll-idle"]
            .reduce(into: [String: StageSummary]()) { $0[$1] = summary($1) }
        let checks = [
            "inputOperationCount": inputSent == 160,
            "scrollOperationCount": scrollSent == 160,
            "inputChangedFileAfterSave": finalFileLength > initialFileLength,
            "sublimeCLIPathUsed": !safeMode,
            "allMeasuredSamplesFrontmost": allForeground,
            "largeWindowThroughout": sizeOK,
            "idleSamplesCollected": samples.filter { $0.stage == "input-idle" || $0.stage == "scroll-idle" }.count >= 100
        ]
        let result = BenchmarkOutput(
            mode: safeMode ? "Sublime Text safe mode" : "Sublime Text normal mode via subl --command",
            scope: safeMode
                ? "Main Sublime process and discovered descendant processes; proc_pid_rusage user+system CPU time; synthetic AppKit key events and CGEvent scroll events; no real Chinese IME candidate selection"
                : "Main Sublime process and discovered descendant processes in normal mode, including the user's settings/plugins/session; editing and scrolling driven by Sublime's own subl --command interface; no real Chinese IME candidate selection",
            appBuild: "Build 4215 (subl --version)",
            windowTarget: "1680x940, target Retina 2x where available",
            inputSent: inputSent,
            scrollSent: scrollSent,
            initialFileLength: initialFileLength,
            finalFileLength: finalFileLength,
            checks: checks,
            processes: descriptions(for: pid),
            summaries: summaries,
            samples: samples
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: outputURL)
    }

    func run() throws {
        try launch()
        defer {
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
            if launchProcess.isRunning { launchProcess.terminate() }
        }
        prepareWindow()
        sample()
        input()
        scroll()
        try finish()
    }
}

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--accessibility-status") {
    print(AXIsProcessTrusted())
    exit(0)
}
if arguments.contains("--dismiss-safe-dialog") {
    if let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
       let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) {
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
    exit(0)
}
if arguments.contains("--dump-frontmost-windows"),
   let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
    dumpWindows(pid)
    exit(0)
}
guard let appArgument = option("--app", in: arguments),
      let outputArgument = option("--output", in: arguments) else {
    fputs("usage: sublime-real-usage --app '/Applications/Sublime Text.app' --output result.json\n", stderr)
    exit(2)
}

do {
    let runner = try Runner(appURL: URL(fileURLWithPath: appArgument),
                            outputURL: URL(fileURLWithPath: outputArgument),
                            safeMode: arguments.contains("--safe-mode"))
    try runner.run()
    print("Wrote \(outputArgument)")
} catch {
    fputs("Sublime benchmark failed: \(error)\n", stderr)
    exit(1)
}
