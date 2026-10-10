import AppKit
import Darwin

// Reader-only measurements exclude the existing full-file log index and window rendering.
func runTextOpeningBenchmark(output: URL) throws {
    guard let path = Textlet.argument("--opening-fixture"),
          let kind = Textlet.argument("--opening-kind"), ["document", "log"].contains(kind) else {
        throw SessionError.invalid("Opening benchmark requires a fixture and document/log kind")
    }
    let url = URL(fileURLWithPath: path)
    let iterations = Int(Textlet.argument("--opening-iterations") ?? "100") ?? 100
    guard iterations > 0, iterations <= 10_000 else { throw SessionError.invalid("Invalid benchmark iterations") }
    func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    func read() -> Bool {
        autoreleasepool {
            do {
                if kind == "document" { _ = try DocumentFile.open(url) }
                else { _ = try LogFile(url: url) }
                return true
            } catch { return false }
        }
    }
    for _ in 0..<3 { _ = read() }
    let before = memorySample(), startedCPU = cpu()
    var elapsed: [Double] = [], accepted = 0
    for _ in 0..<iterations {
        let started = ProcessInfo.processInfo.systemUptime
        if read() { accepted += 1 }
        elapsed.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
    }
    let usedCPU = cpu() - startedCPU
    let after = memorySample()
    elapsed.sort()
    let report: [String: Any] = ["kind": kind, "size": try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
        "iterations": iterations, "accepted": accepted, "cpuMillisecondsPerOpen": usedCPU * 1000 / Double(iterations),
        "medianMilliseconds": elapsed[elapsed.count / 2], "before": before, "after": after]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
}
