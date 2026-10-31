import Foundation
import CryptoKit

public struct PythonRuntimeManifest: Codable, Hashable {
    public var runtimeVersion: String
    public var architectures: [String]
    public var executable: String
    public var home: String
    public var files: [String: String]
    public var licenseFiles: [String]

    public init(runtimeVersion: String, architectures: [String], executable: String,
                home: String, files: [String: String], licenseFiles: [String] = []) {
        self.runtimeVersion = runtimeVersion
        self.architectures = architectures
        self.executable = executable
        self.home = home
        self.files = files
        self.licenseFiles = licenseFiles
    }
}

public struct PythonRuntimeStatus: Codable, Hashable {
    public var available: Bool
    public var version: String
    public var architecture: String
    public var runtimePath: String
    public var manifestValid: Bool
    public var lastError: String

    public init(available: Bool = false, version: String = "", architecture: String = "",
                runtimePath: String = "", manifestValid: Bool = false, lastError: String = "") {
        self.available = available
        self.version = version
        self.architecture = architecture
        self.runtimePath = runtimePath
        self.manifestValid = manifestValid
        self.lastError = lastError
    }
}

public enum PythonRuntimeError: LocalizedError {
    case missingManifest
    case invalidManifest(String)
    case unsupportedVersion(String)
    case unsupportedArchitecture(String)
    case missingFile(String)
    case hashMismatch(String)
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .missingManifest: return "Python runtime manifest 不存在"
        case .invalidManifest(let detail): return "Python runtime manifest 无效：\(detail)"
        case .unsupportedVersion(let version): return "不支持的 Python 版本：\(version)"
        case .unsupportedArchitecture(let arch): return "Python runtime 不支持当前架构：\(arch)"
        case .missingFile(let path): return "Python runtime 文件缺失：\(path)"
        case .hashMismatch(let path): return "Python runtime 文件校验失败：\(path)"
        case .unsafePath(let path): return "Python runtime 路径不安全：\(path)"
        }
    }
}

public struct PythonRuntime {
    public static let manifestRelativePath = "Contents/Resources/python-runtime.json"
    public static var userPackagesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".controlmymac/python-packages")
    }
    public let bundleURL: URL
    public let manifestURL: URL

    public init(bundleURL: URL = URL(fileURLWithPath: "/Applications/ControlMyMac.app")) {
        self.bundleURL = bundleURL
        self.manifestURL = bundleURL.appendingPathComponent(Self.manifestRelativePath)
    }

    public var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    public func validate() -> Result<(manifest: PythonRuntimeManifest, executable: URL, home: URL), Error> {
        guard let data = try? Data(contentsOf: manifestURL) else {
            return .failure(PythonRuntimeError.missingManifest)
        }
        let manifest: PythonRuntimeManifest
        do {
            manifest = try JSONDecoder().decode(PythonRuntimeManifest.self, from: data)
        } catch {
            return .failure(PythonRuntimeError.invalidManifest(error.localizedDescription))
        }
        guard manifest.runtimeVersion.hasPrefix("3.14.") else {
            return .failure(PythonRuntimeError.unsupportedVersion(manifest.runtimeVersion))
        }
        guard manifest.architectures.contains(currentArchitecture) else {
            return .failure(PythonRuntimeError.unsupportedArchitecture(currentArchitecture))
        }
        guard let executable = safeURL(manifest.executable),
              let home = safeURL(manifest.home) else {
            return .failure(PythonRuntimeError.unsafePath(manifest.executable))
        }
        for (relative, expectedHash) in manifest.files {
            guard let url = safeURL(relative), let bytes = try? Data(contentsOf: url) else {
                return .failure(PythonRuntimeError.missingFile(relative))
            }
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(expectedHash) == .orderedSame else {
                return .failure(PythonRuntimeError.hashMismatch(relative))
            }
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .failure(PythonRuntimeError.missingFile(manifest.executable))
        }
        return .success((manifest, executable, home))
    }

    public func status() -> PythonRuntimeStatus {
        switch validate() {
        case .success(let result):
            return PythonRuntimeStatus(available: true, version: result.manifest.runtimeVersion,
                                       architecture: currentArchitecture,
                                       runtimePath: result.executable.path,
                                       manifestValid: true)
        case .failure(let error):
            return PythonRuntimeStatus(available: false, architecture: currentArchitecture,
                                       runtimePath: manifestURL.deletingLastPathComponent().path,
                                       manifestValid: false,
                                       lastError: error.localizedDescription)
        }
    }

    private func safeURL(_ relative: String) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !relative.contains(".."),
              !relative.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return bundleURL.appendingPathComponent(relative).standardizedFileURL
    }
}
