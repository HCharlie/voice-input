import AppKit
import Foundation

final class UpdateChecker {
    static let shared = UpdateChecker()
    private init() {}

    private let apiURL = URL(string: "https://api.github.com/repos/HCharlie/voice-input/releases/latest")!
    private var progressWindow: NSWindow?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // Called once on launch with a delay so it doesn't compete with permission prompts.
    // Skipped in debug builds (running from .build/, not /Applications).
    func checkOnLaunch() {
        #if DEBUG
        return
        #endif
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.fetchLatestRelease(userInitiated: false)
        }
    }

    func checkUserInitiated() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.fetchLatestRelease(userInitiated: true)
        }
    }

    // MARK: - Fetch

    private func fetchLatestRelease(userInitiated: Bool) {
        var request = URLRequest(url: apiURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VoiceInput/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var release: GitHubRelease?
        var fetchError: Error?

        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error { fetchError = error; return }
            guard let data else { return }
            release = try? JSONDecoder().decode(GitHubRelease.self, from: data)
        }.resume()
        semaphore.wait()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let error = fetchError {
                if userInitiated { self.showError("Could not check for updates.\n\(error.localizedDescription)") }
                return
            }
            guard let release else {
                if userInitiated { self.showError("Received an unexpected response from GitHub.") }
                return
            }
            let remote = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            if self.isNewer(remote: remote, than: self.currentVersion) {
                self.showUpdateDialog(release: release)
            } else if userInitiated {
                self.showUpToDateAlert()
            }
        }
    }

    // MARK: - Dialogs

    private func showUpdateDialog(release: GitHubRelease) {
        let alert = NSAlert()
        alert.messageText = "VoiceInput \(release.tagName) is available"
        let notes = release.body.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = notes.isEmpty
            ? "A new version is ready to install."
            : String(notes.prefix(400)) + (notes.count > 400 ? "…" : "")
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        startInstall(release: release)
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "VoiceInput is up to date"
        alert.informativeText = "You're running version \(currentVersion)."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Download & Install

    private func startInstall(release: GitHubRelease) {
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let downloadURL = URL(string: asset.browserDownloadURL) else {
            showError("No downloadable package found for \(release.tagName).")
            return
        }

        showProgressWindow(version: release.tagName)

        URLSession.shared.downloadTask(with: downloadURL) { [weak self] tempURL, _, error in
            guard let self else { return }
            guard let tempURL else {
                DispatchQueue.main.async {
                    self.closeProgressWindow()
                    self.showError("Download failed: \(error?.localizedDescription ?? "unknown error")")
                }
                return
            }
            do {
                try self.installZip(at: tempURL, version: release.tagName)
                DispatchQueue.main.async {
                    self.closeProgressWindow()
                    self.relaunch()
                }
            } catch {
                DispatchQueue.main.async {
                    self.closeProgressWindow()
                    self.showError("Installation failed: \(error.localizedDescription)")
                }
            }
        }.resume()
    }

    private func installZip(at zipURL: URL, version: String) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("VoiceInput-\(version)")
        try? fm.removeItem(at: tempDir)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", zipURL.path, "-d", tempDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateError.extractionFailed }

        let newApp = tempDir.appendingPathComponent("VoiceInput.app")
        guard fm.fileExists(atPath: newApp.path) else { throw UpdateError.appNotFoundInZip }

        let destination = URL(fileURLWithPath: "/Applications/VoiceInput.app")
        try? fm.trashItem(at: destination, resultingItemURL: nil)
        try fm.moveItem(at: newApp, to: destination)

        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-cr", destination.path]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    private func relaunch() {
        let appURL = URL(fileURLWithPath: "/Applications/VoiceInput.app")
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
    }

    // MARK: - Progress window

    private func showProgressWindow(version: String) {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 72),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "Updating VoiceInput"
        window.isReleasedWhenClosed = false
        window.center()

        let content = window.contentView!

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(spinner)

        let label = NSTextField(labelWithString: "Downloading \(version)…")
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)

        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        progressWindow = window
    }

    private func closeProgressWindow() {
        progressWindow?.close()
        progressWindow = nil
    }

    // MARK: - Semver comparison

    private func isNewer(remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        guard r.count >= 3, c.count >= 3 else { return false }
        for i in 0..<3 where r[i] != c[i] { return r[i] > c[i] }
        return false
    }
}

// MARK: - Models

private struct GitHubRelease: Decodable {
    let tagName: String
    let body: String
    let assets: [GitHubAsset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String
    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private enum UpdateError: LocalizedError {
    case extractionFailed
    case appNotFoundInZip
    var errorDescription: String? {
        switch self {
        case .extractionFailed: "Failed to extract the downloaded update."
        case .appNotFoundInZip: "VoiceInput.app was not found in the downloaded package."
        }
    }
}
