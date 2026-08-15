import Foundation

struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(string: String) {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionText = normalized.hasPrefix("v") ? String(normalized.dropFirst()) : normalized
        let components = versionText.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

struct SoftwareUpdate: Identifiable, Equatable, Sendable {
    let version: SemanticVersion
    let downloadURL: URL
    let releaseURL: URL
    let expectedSHA256: String
    let expectedSize: Int

    var id: String { version.description }
}

struct PreparedSoftwareUpdate: Identifiable, Sendable {
    let update: SoftwareUpdate
    let appURL: URL
    let workingDirectory: URL

    var id: String { update.id }
}

enum SoftwareUpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(SoftwareUpdate)
    case downloading(SoftwareUpdate)
    case readyToInstall(SoftwareUpdate)
    case failed(String)
}
