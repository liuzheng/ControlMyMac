import Foundation

public enum MacOSNetworkServiceResolverError: Error, Equatable, Sendable {
    case commandFailed
    case serviceNotFound
}

public struct NetworkServiceOrderParser: Sendable {
    public init() {}

    public func serviceName(for interface: String, output: String) -> String? {
        let lines = output.split(whereSeparator: { $0.isNewline }).map(String.init)
        var pendingService: String?
        let expression = try? NSRegularExpression(pattern: #"^\(\d+\)\s+(.+)$"#)
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = expression?.firstMatch(in: line, range: range),
               let serviceRange = Range(match.range(at: 1), in: line) {
                pendingService = String(line[serviceRange])
            } else if line.contains("Device: \(interface)") {
                return pendingService
            }
        }
        return nil
    }
}

public struct MacOSNetworkServiceResolver: NetworkServiceResolving {
    public typealias CommandRunner = () throws -> String
    private let command: CommandRunner

    public init() {
        command = Self.readNetworkServiceOrder
    }

    public init(command: @escaping CommandRunner) {
        self.command = command
    }

    public func serviceName(for interface: String) throws -> String {
        guard let service = NetworkServiceOrderParser().serviceName(for: interface, output: try command()) else {
            throw MacOSNetworkServiceResolverError.serviceNotFound
        }
        return service
    }

    private static func readNetworkServiceOrder() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listnetworkserviceorder"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MacOSNetworkServiceResolverError.commandFailed }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
