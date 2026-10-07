import Foundation

public class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    static let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    private var onProgress: ((Double) -> Void)?
    private var completion: ((Error?) -> Void)?
    private var destPath: URL?

    public static func download(modelSize: String, onProgress: ((Double) -> Void)? = nil) throws {
        let modelFileName = "ggml-\(modelSize).bin"
        let modelsDir = Config.configDir.appendingPathComponent("models")
        let destPath = modelsDir.appendingPathComponent(modelFileName)

        // A file existing at destPath is not proof the model is usable: a
        // prior download could have been interrupted (e.g. the process
        // killed) in the narrow window after moveItem placed the file but
        // before the magic-byte check below ran, leaving a corrupt file
        // behind with no download ever re-attempted. Transcriber.findModel
        // / modelExists make the same "exists on disk" assumption this check
        // does, so a corrupt file here would otherwise silently break
        // dictation for this model size forever (confirmed: whisper-cli
        // degrades gracefully with exit 0 and no stdout on a bad-magic model
        // file rather than crashing, which `resolveOutput` already turns
        // into a thrown transcriptionFailed -- but only ModelDownloader can
        // actually fix the file, since nothing else ever re-downloads it).
        if ModelDownloader.canReuseExisting(at: destPath.path) {
            print("Model '\(modelSize)' already exists at \(destPath.path)")
            return
        }
        if FileManager.default.fileExists(atPath: destPath.path) {
            print("Existing model file for '\(modelSize)' is corrupt; re-downloading.")
            try? FileManager.default.removeItem(at: destPath)
        }

        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let urlString = "\(baseURL)/\(modelFileName)"
        guard let url = URL(string: urlString) else {
            throw ModelDownloadError.downloadFailed
        }

        print("Downloading \(modelSize) model from \(urlString)...")

        let downloader = ModelDownloader()
        downloader.onProgress = onProgress
        downloader.destPath = destPath

        let semaphore = DispatchSemaphore(value: 0)
        var downloadError: Error?

        downloader.completion = { error in
            downloadError = error
            semaphore.signal()
        }

        let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        task.resume()

        semaphore.wait()
        session.invalidateAndCancel()

        if let error = downloadError {
            throw error
        }

        print("Model downloaded to \(destPath.path)")
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destPath = destPath else {
            completion?(ModelDownloadError.downloadFailed)
            return
        }
        do {
            if let httpResponse = downloadTask.response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                completion?(ModelDownloadError.httpError(httpResponse.statusCode))
                return
            }

            if FileManager.default.fileExists(atPath: destPath.path) {
                try FileManager.default.removeItem(at: destPath)
            }
            try FileManager.default.moveItem(at: location, to: destPath)

            if !ModelDownloader.isValidGGMLFile(at: destPath) {
                try? FileManager.default.removeItem(at: destPath)
                completion?(ModelDownloadError.invalidModelData)
                return
            }

            completion?(nil)
        } catch {
            completion?(error)
        }
    }

    // Pure decision logic split out of `download(modelSize:)` so the
    // corrupt-leftover-file case can be unit tested without a real file or
    // network call, the same way `Transcriber.resolveOutput` is split from
    // its Process-touching caller. True only when a file exists at `path`
    // AND it passes the GGML magic-byte check; false for both "missing" and
    // "present but corrupt" so the caller's single "do I need to download?"
    // branch stays simple.
    static func canReuseExisting(
        at path: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isValid: (URL) -> Bool = { ModelDownloader.isValidGGMLFile(at: $0) }
    ) -> Bool {
        guard fileExists(path) else { return false }
        return isValid(URL(fileURLWithPath: path))
    }

    public static func isValidGGMLFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        // GGML magic: 0x67676d6c ("ggml"), GGJT magic: 0x67676a74 ("ggjt"), GGUF magic: 0x46554747 ("GGUF")
        let magicU32 = magic.withUnsafeBytes { $0.load(as: UInt32.self) }
        let knownMagics: Set<UInt32> = [0x67676d6c, 0x67676a74, 0x46554747]
        return knownMagics.contains(magicU32)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100.0
        onProgress?(percent)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            completion?(error)
        }
    }
}

public enum ModelDownloadError: LocalizedError {
    case downloadFailed
    case httpError(Int)
    case invalidModelData

    public var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Failed to download model"
        case .httpError(let statusCode):
            return "Download failed with HTTP status \(statusCode). Check your network connection or proxy settings."
        case .invalidModelData:
            return "Downloaded file is not a valid GGML model (possibly a proxy error page). Check your network connection or try downloading from a different network."
        }
    }
}
