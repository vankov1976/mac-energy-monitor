import AppKit
import Security

/// Downloads a new version inside the app (no browser): zip into Downloads, unpack it, check that the
/// new app is signed by the same developer, then show it in Finder. The user drags it into Applications.
@MainActor
final class UpdateDownloader: NSObject, ObservableObject {
    static let shared = UpdateDownloader()

    enum State: Equatable {
        case idle
        case downloading(Double)    // 0...1
        case ready(URL)             // the unpacked, verified app
        case failed(String)
    }
    @Published private(set) var state = State.idle
    private var version = ""

    /// Developer ID team of the published app; a downloaded app must carry the same signature.
    nonisolated static let teamID = "ZK4CK28QS4"

    func start(_ r: Release) {
        if case .downloading = state { return }
        if case .ready(let app) = state, version == r.version, FileManager.default.fileExists(atPath: app.path) {
            reveal(app)
            return
        }
        guard var zip = r.download else {             // no zip attached: the release page is the only way
            NSWorkspace.shared.open(r.page)
            return
        }
#if DIAGNOSTICS
        // Test builds only: `defaults write local.mac-energy-monitor updateTestZipURL <url>` (e.g. a file:// zip).
        if let t = UserDefaults.standard.string(forKey: "updateTestZipURL"), let u = URL(string: t) { zip = u }
#endif
        version = r.version
        state = .downloading(0)
        Task {
            do {
                let app = try await fetchAndUnpack(zip, version: r.version)
                state = .ready(app)
                reveal(app)
            } catch {
                state = .failed((error as? UpdateError)?.message
                    ?? "The download failed. Check the internet connection and try again.")
            }
        }
    }

    func reveal(_ app: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([app])
    }


    // MARK: - Steps

    struct UpdateError: Error { let message: String }

    private func fetchAndUnpack(_ url: URL, version: String) async throws -> URL {
        let tmpZip = try await download(url)
        defer { try? FileManager.default.removeItem(at: tmpZip) }

        let fm = FileManager.default
        let downloads = try fm.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = downloads.appendingPathComponent("Mac Energy Monitor \(version)", isDirectory: true)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        try await Self.run("/usr/bin/ditto", ["-x", "-k", tmpZip.path, folder.path])
        guard let app = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else {
            try? fm.removeItem(at: folder)
            throw UpdateError(message: "The download did not contain the app. Please try again later.")
        }
        guard Self.isSignedByUs(app) else {
            try? fm.removeItem(at: folder)
            throw UpdateError(message: "The downloaded app is not signed by the developer of Mac Energy Monitor, so it was deleted.")
        }
        return app
    }

    private var continuation: CheckedContinuation<URL, Error>?

    /// Downloads to a temporary file, reporting progress.
    private func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { c in
            continuation = c
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.setValue("Mac-Energy-Monitor", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: req).resume()
            session.finishTasksAndInvalidate()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw UpdateError(message: "The download could not be unpacked. Please try again.")
            }
        }.value
    }

    /// Valid signature from Apple's Developer ID chain with our team ID (what Gatekeeper also trusts).
    nonisolated static func isSignedByUs(_ app: URL) -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        let r = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(r as CFString, [], &req) == errSecSuccess, let req else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }
}

extension UpdateDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData _: Int64, totalBytesWritten done: Int64, totalBytesExpectedToWrite total: Int64) {
        let f = total > 0 ? Double(done) / Double(total) : 0
        MainActor.assumeIsolated { state = .downloading(f) }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns: move it first.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        let moved = Result { try FileManager.default.moveItem(at: location, to: tmp); return tmp }
        MainActor.assumeIsolated {
            if status != 200 { finish(.failure(URLError(.badServerResponse))) } else { finish(moved) }
        }
    }

    nonisolated func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated { finish(.failure(error)) }
    }
}
