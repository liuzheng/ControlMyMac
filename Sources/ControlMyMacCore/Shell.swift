import Foundation

public struct ProcResult {
    public let status: Int32
    public let out: String
    public let err: String

    public init(status: Int32, out: String, err: String) {
        self.status = status
        self.out = out
        self.err = err
    }

    public var ok: Bool { status == 0 }
    public var detail: String {
        let error = err.trimmingCharacters(in: .whitespacesAndNewlines)
        return error.isEmpty ? out.trimmingCharacters(in: .whitespacesAndNewlines) : error
    }
}

@discardableResult
public func run(_ path: String, _ args: [String]) -> ProcResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    do {
        try process.run()
    } catch {
        return ProcResult(status: -1, out: "", err: "无法执行 \(path)：\(error.localizedDescription)")
    }
    let out = output.fileHandleForReading.readDataToEndOfFile()
    let err = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcResult(status: process.terminationStatus,
                      out: String(data: out, encoding: .utf8) ?? "",
                      err: String(data: err, encoding: .utf8) ?? "")
}
