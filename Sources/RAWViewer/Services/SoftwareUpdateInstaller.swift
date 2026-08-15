import Foundation

enum SoftwareUpdateInstaller {
    private static let workspacePrefix = "RAWViewerUpdate-"

    static func scheduleInstallation(of preparedUpdate: PreparedSoftwareUpdate) throws {
        let fileManager = FileManager.default
        let currentAppURL = Bundle.main.bundleURL.standardizedFileURL
        let targetDirectoryURL = currentAppURL.deletingLastPathComponent()
        let temporaryDirectoryURL = fileManager.temporaryDirectory.standardizedFileURL
        let workspaceURL = preparedUpdate.workingDirectory.standardizedFileURL

        guard currentAppURL.pathExtension == "app",
              currentAppURL.lastPathComponent == "RAW Viewer.app",
              workspaceURL.deletingLastPathComponent() == temporaryDirectoryURL,
              workspaceURL.lastPathComponent.hasPrefix(workspacePrefix),
              preparedUpdate.appURL.deletingLastPathComponent().standardizedFileURL == workspaceURL,
              fileManager.fileExists(atPath: preparedUpdate.appURL.path),
              fileManager.isWritableFile(atPath: targetDirectoryURL.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let helperURL = workspaceURL.appendingPathComponent("install-update.sh")
        let backupSuffix = UUID().uuidString
        let script = """
        #!/bin/sh
        set -eu

        parent_pid="$1"
        source_app="$2"
        target_app="$3"
        workspace="$4"
        backup_app="$target_app.previous-\(backupSuffix)"

        while kill -0 "$parent_pid" 2>/dev/null; do
            sleep 1
        done

        if [ -e "$target_app" ]; then
            /bin/mv "$target_app" "$backup_app"
        fi

        if /usr/bin/ditto --rsrc --extattr "$source_app" "$target_app"; then
            /usr/bin/open -n "$target_app"
            /bin/rm -rf "$backup_app"
            /bin/rm -rf "$workspace"
            exit 0
        fi

        /bin/rm -rf "$target_app"
        if [ -e "$backup_app" ]; then
            /bin/mv "$backup_app" "$target_app"
            /usr/bin/open -n "$target_app"
        fi
        exit 1
        """
        guard let scriptData = script.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try scriptData.write(to: helperURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            helperURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            preparedUpdate.appURL.path,
            currentAppURL.path,
            workspaceURL.path
        ]
        try process.run()
    }
}
