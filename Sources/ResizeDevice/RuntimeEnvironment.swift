import Foundation
import Darwin

public struct RuntimeEnvironment: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case palera1n
        case checkra1n
        case standalone
        case fixture
    }

    public var kind: Kind
    public var osVersion: String
    public var majorVersion: Int
    public var machine: String
    public var uid: UInt32
    public var prefersCLI: Bool

    public init(kind: Kind, osVersion: String, majorVersion: Int, machine: String, uid: UInt32, prefersCLI: Bool) {
        self.kind = kind; self.osVersion = osVersion; self.majorVersion = majorVersion
        self.machine = machine; self.uid = uid; self.prefersCLI = prefersCLI
    }

    public static func detect(isFixture: Bool = false) -> RuntimeEnvironment {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let machine = sysctlString("hw.machine") ?? "Unknown"
        let uid = UInt32(geteuid())
        if isFixture {
            return RuntimeEnvironment(kind: .fixture, osVersion: osVersion, majorVersion: version.majorVersion,
                                      machine: machine, uid: uid, prefersCLI: true)
        }
        #if os(iOS)
        let fm = FileManager.default
        let isPalera1n = fm.fileExists(atPath: "/cores/binpack/Applications/palera1nLoader.app")
            || fm.fileExists(atPath: "/cores/jbloader")
            || fm.fileExists(atPath: "/cores/binpack")
        if isPalera1n && version.majorVersion >= 15 {
            return RuntimeEnvironment(kind: .palera1n, osVersion: osVersion, majorVersion: version.majorVersion,
                                      machine: machine, uid: uid, prefersCLI: false)
        }
        let isCheckra1n = fm.fileExists(atPath: "/.bootstrapped")
            || fm.fileExists(atPath: "/var/binpack")
            || fm.fileExists(atPath: "/checkra1n")
            || fm.fileExists(atPath: "/Library/dpkg")
            || version.majorVersion < 15
        let kind: Kind = isCheckra1n ? .checkra1n : .standalone
        return RuntimeEnvironment(kind: kind, osVersion: osVersion, majorVersion: version.majorVersion,
                                  machine: machine, uid: uid, prefersCLI: version.majorVersion < 15 || !isPalera1n)
        #else
        return RuntimeEnvironment(kind: .fixture, osVersion: osVersion, majorVersion: version.majorVersion,
                                  machine: machine, uid: uid, prefersCLI: true)
        #endif
    }

    public var summary: String {
        switch kind {
        case .palera1n: return "palera1n (iOS \(osVersion), \(machine))"
        case .checkra1n: return "checkra1n rootful (iOS \(osVersion), \(machine))"
        case .standalone: return "iOS root shell (iOS \(osVersion), \(machine))"
        case .fixture: return "host fixture (\(machine))"
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var length = 0
        guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 0, length < 256 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard sysctlbyname(name, &buffer, &length, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
