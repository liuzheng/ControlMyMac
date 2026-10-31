import Foundation

public struct PythonDependencyStatus: Hashable {
    public var state: String
    public var updatedAt: String
    public var error: String

    public init(state: String = "missing", updatedAt: String = "", error: String = "") {
        self.state = state
        self.updatedAt = updatedAt
        self.error = error
    }

    public static func read(from url: URL = PythonRuntime.userPackagesURL
        .deletingLastPathComponent().appendingPathComponent("python-packages.status")) -> PythonDependencyStatus {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return PythonDependencyStatus() }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return PythonDependencyStatus(state: values["state"] ?? "missing",
                                      updatedAt: values["updated_at"] ?? "",
                                      error: values["error"] ?? "")
    }
}
