import CryptoKit
import Foundation
import Security

enum SoftwareUpdateError: LocalizedError, Sendable {
    case invalidResponse
    case httpError(Int)
    case invalidReleaseMetadata
    case noMatchingAsset
    case missingDigest
    case unsafeAssetSize
    case downloadSizeMismatch
    case checksumMismatch
    case archiveExtractionFailed(String)
    case invalidAppBundle
    case invalidAppSignature

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Die Antwort des Update-Servers konnte nicht gelesen werden."
        case .httpError(let status):
            "Der Update-Server antwortete mit HTTP-Status \(status)."
        case .invalidReleaseMetadata:
            "Die Metadaten des veröffentlichten Updates sind ungültig."
        case .noMatchingAsset:
            "Das aktuelle Release enthält kein passendes Apple-Silicon-Update."
        case .missingDigest:
            "Das Update enthält keine SHA-256-Prüfsumme und wird deshalb nicht geladen."
        case .unsafeAssetSize:
            "Die angegebene Größe des Update-Downloads ist ungültig."
        case .downloadSizeMismatch:
            "Der Download hat nicht die erwartete Dateigröße."
        case .checksumMismatch:
            "Die Prüfsumme des Downloads stimmt nicht mit dem GitHub-Release überein."
        case .archiveExtractionFailed(let message):
            "Das Update-Archiv konnte nicht entpackt werden: \(message)"
        case .invalidAppBundle:
            "Das Update enthält keine passende RAW-Viewer-App."
        case .invalidAppSignature:
            "Die Signatur des Updates konnte nicht als RAW Viewer von R3D42 bestätigt werden."
        }
    }
}

final class SoftwareUpdateService: @unchecked Sendable {
    private static let repository = "c5vcpq5gsr-alt/R3Ds_RAW-Viewer"
    private static let bundleIdentifier = "de.r3d.rawviewer"
    private static let signingTeamIdentifier = "G6JH37W285"
    private static let maximumAssetSize = 1_000_000_000

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchLatestUpdate(currentVersion: SemanticVersion) async throws -> SoftwareUpdate? {
        let endpoint = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("RAW-Viewer/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SoftwareUpdateError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SoftwareUpdateError.httpError(httpResponse.statusCode)
        }
        return try Self.update(fromReleaseData: data, currentVersion: currentVersion)
    }

    func downloadAndPrepare(_ update: SoftwareUpdate) async throws -> PreparedSoftwareUpdate {
        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("RAWViewerUpdate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        do {
            var request = URLRequest(url: update.downloadURL, timeoutInterval: 60)
            request.setValue("RAW-Viewer/\(update.version)", forHTTPHeaderField: "User-Agent")
            let (temporaryURL, response) = try await session.download(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw SoftwareUpdateError.invalidResponse
            }

            let archiveURL = workingDirectory.appendingPathComponent("RAW-Viewer-\(update.version)-macOS-arm64.zip")
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)
            let fileSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize == update.expectedSize else { throw SoftwareUpdateError.downloadSizeMismatch }
            guard try Self.sha256(for: archiveURL) == update.expectedSHA256 else {
                throw SoftwareUpdateError.checksumMismatch
            }

            try await Self.extract(archiveURL, into: workingDirectory)
            let appURL = workingDirectory.appendingPathComponent("RAW Viewer.app", isDirectory: true)
            try Self.validateAppBundle(at: appURL, expectedVersion: update.version)
            return PreparedSoftwareUpdate(update: update, appURL: appURL, workingDirectory: workingDirectory)
        } catch {
            try? fileManager.removeItem(at: workingDirectory)
            throw error
        }
    }

    static func update(fromReleaseData data: Data, currentVersion: SemanticVersion) throws -> SoftwareUpdate? {
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw SoftwareUpdateError.invalidReleaseMetadata
        }
        guard let version = SemanticVersion(string: release.tagName) else {
            throw SoftwareUpdateError.invalidReleaseMetadata
        }
        guard version > currentVersion else { return nil }

        let expectedName = "RAW-Viewer-\(version)-macOS-arm64.zip"
        guard let asset = release.assets.first(where: { $0.name == expectedName }) else {
            throw SoftwareUpdateError.noMatchingAsset
        }
        guard asset.size > 0, asset.size <= maximumAssetSize else {
            throw SoftwareUpdateError.unsafeAssetSize
        }
        guard let digest = asset.digest?.lowercased(),
              digest.hasPrefix("sha256:"),
              let sha256 = Self.normalizedSHA256(String(digest.dropFirst("sha256:".count))) else {
            throw SoftwareUpdateError.missingDigest
        }
        return SoftwareUpdate(
            version: version,
            downloadURL: asset.browserDownloadURL,
            releaseURL: release.htmlURL,
            expectedSHA256: sha256,
            expectedSize: asset.size
        )
    }

    private static func normalizedSHA256(_ value: String) -> String? {
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return value.lowercased()
    }

    private static func sha256(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func extract(_ archiveURL: URL, into directoryURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archiveURL.path, directoryURL.path]
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw SoftwareUpdateError.archiveExtractionFailed(error.localizedDescription)
            }
            guard process.terminationStatus == 0 else {
                let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unbekannter Fehler"
                throw SoftwareUpdateError.archiveExtractionFailed(message)
            }
        }.value
    }

    private static func validateAppBundle(at appURL: URL, expectedVersion: SemanticVersion) throws {
        let values = try appURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == bundleIdentifier,
              SemanticVersion(string: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") == expectedVersion else {
            throw SoftwareUpdateError.invalidAppBundle
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            throw SoftwareUpdateError.invalidAppSignature
        }
        let requirementText = "identifier \"\(bundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(signingTeamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(), requirement) == errSecSuccess else {
            throw SoftwareUpdateError.invalidAppSignature
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL
        let assets: [GitHubReleaseAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    private struct GitHubReleaseAsset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let digest: String?
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
            case size
        }
    }
}
