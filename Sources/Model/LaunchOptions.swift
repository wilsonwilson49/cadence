import Foundation

/// Command-line options (debug and test runs) and where the data file lives. Shared by the Mac and iPhone apps.
enum LaunchOptions {
    static var args: [String] { ProcessInfo.processInfo.arguments }
    static func has(_ flag: String) -> Bool { args.contains(flag) }
    static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var dataDirectory: URL {
        if let custom = value("-dataDir") { return URL(fileURLWithPath: custom, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Cadence", isDirectory: true)
    }
}
