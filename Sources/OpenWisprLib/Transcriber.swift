import Foundation

public class Transcriber {
    private let modelSize: String
    private let language: String
    private let whisperPrompt: String?
    public var spokenPunctuation: Bool = false
    public var translateToEnglish: Bool = false

    public init(modelSize: String = "base.en", language: String = "en", whisperPrompt: String? = nil, translateToEnglish: Bool = false) {
        self.modelSize = modelSize
        self.language = language
        self.whisperPrompt = whisperPrompt
        self.translateToEnglish = translateToEnglish
    }

    public func transcribe(audioURL: URL) throws -> String {
        guard let whisperPath = Transcriber.findWhisperBinary() else {
            throw TranscriberError.whisperNotFound
        }

        guard let modelPath = Transcriber.findModel(modelSize: modelSize) else {
            throw TranscriberError.modelNotFound(modelSize)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = arguments(modelPath: modelPath, audioURL: audioURL)

        // Task 8.2 follow-up: whisper.cpp's ggml-base dylib dlopen()s its compute
        // backend (CPU/BLAS/Metal) from a separate plugin file at runtime rather than
        // statically linking it -- `otool -L` never shows this. bundle-app.sh embeds
        // the plugin at Contents/Frameworks/ggml-backends/ inside the app, but only
        // the launching process knows the app's install location at runtime, so this
        // env var has to be set here, not baked in at bundle-build time (that would
        // break the moment a user moved the .app). When unbundled (dev.sh, swift
        // test, a bare .build/release binary), bundledBackendPath returns nil and we
        // leave the environment untouched -- whisper-cli then falls through to its
        // own Homebrew-fallback resolution exactly as it does today. Never set this
        // to a path that doesn't exist: ggml dlopen()s the value directly with no
        // fallback scan, so a bad path crashes harder than an unset one.
        if let backendPath = Transcriber.bundledBackendPath(bundlePath: Bundle.main.bundlePath) {
            var env = ProcessInfo.processInfo.environment
            env["GGML_BACKEND_PATH"] = backendPath
            process.environment = env
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        var stderrData = Data()
        let stderrThread = Thread {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        stderrThread.start()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        while !stderrThread.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        process.waitUntilExit()

        let rawStdout = String(data: data, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return try Transcriber.resolveOutput(
            terminationStatus: process.terminationStatus,
            rawStdout: rawStdout,
            stderr: stderrText
        )
    }

    // Pure decision logic split out of `transcribe(audioURL:)` so it can be unit
    // tested without shelling out to a real whisper-cli process.
    //
    // whisper.cpp's argument parser does not fail on an unrecognized flag: it prints
    // "error: unknown argument: ..." plus a full usage dump to stderr, produces EMPTY
    // stdout, and exits 0. Left unchecked, that reads as a successful "no speech
    // detected" transcription and silently produces no text.
    //
    // The distinguishing signal is stderr content, not stdout emptiness alone:
    // legitimate silent/no-speech audio also produces empty stdout, but with EMPTY
    // stderr, and must keep returning "" exactly as before.
    static func resolveOutput(terminationStatus: Int32, rawStdout: String, stderr: String) throws -> String {
        let output = stripWhisperMarkers(rawStdout.trimmingCharacters(in: .whitespacesAndNewlines))

        if terminationStatus != 0 {
            if !stderr.isEmpty { fputs("whisper-cpp: \(stderr)\n", Foundation.stderr) }
            throw TranscriberError.transcriptionFailed
        }

        if output.isEmpty && !stderr.isEmpty {
            fputs("whisper-cpp: \(stderr)\n", Foundation.stderr)
            throw TranscriberError.transcriptionFailed
        }

        return output
    }

    func arguments(modelPath: String, audioURL: URL) -> [String] {
        var args = [
            "-m", modelPath,
            "-f", audioURL.path,
            "-l", language,
            "--no-timestamps",
            "-nt",
            // Suppresses the decoder's non-speech token class (the vocabulary tokens
            // behind hallucinated bracket/parenthetical output like "[Music]" or
            // "(machinery whirring)"). Measured on base.en against 5 real-speech
            // samples (74 reference words): identical WER (6.8%) with and without
            // this flag, and it eliminated every bracketed hallucination we could
            // reproduce on silence/near-silence input. `--no-speech-thold` was
            // tried first (0.3-0.9) and had no observable effect on this whisper-cli
            // build, so it isn't used here.
            "--suppress-nst",
        ]
        if translateToEnglish {
            args.append("-tr")
        }
        if let prompt = effectiveWhisperPrompt {
            args += ["--prompt", prompt]
        }
        if spokenPunctuation {
            args += ["--suppress-regex", "[,\\.\\?!;:\\-—]"]
        }

        return args
    }

    // Pure lookup split out so it's testable without a real app bundle or Process
    // run, the same way `arguments(modelPath:audioURL:)` is. Returns the path to
    // bundle-app.sh's embedded ggml backend plugin when it exists, nil otherwise
    // (unbundled dev/test runs, or a bundle built before Task 8.2's fix). The
    // apple_m1 plugin is verified to also run correctly on newer (M2) Apple
    // Silicon, so one hardcoded filename is correct today -- no per-chip
    // detection needed here (see bundle-app.sh's note on the same point).
    static func bundledBackendPath(
        bundlePath: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let candidate = bundlePath + "/Contents/Frameworks/ggml-backends/libggml-cpu-apple_m1.so"
        return fileExists(candidate) ? candidate : nil
    }

    private var effectiveWhisperPrompt: String? {
        guard let whisperPrompt else { return nil }
        return whisperPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : whisperPrompt
    }

    // Matched case-insensitively against the whole bracket/parenthesis content
    // (trimmed, lowercased) — not just the exact casings whisper.cpp happens to emit.
    private static let knownMarkers: Set<String> = [
        "blank_audio",
        "music", "background music", "music playing",
        "applause", "clapping",
        "laughter", "laughing",
        "silence", "silent",
        "sound", "no audio", "no sound",
        "noise", "background noise", "static", "buzzing", "humming", "engine noise",
        "inaudible", "indistinct", "indistinct chatter", "crosstalk", "mumbling",
        "cough", "coughing", "clears throat", "sneeze", "sneezing", "sniffle", "sniffling",
        "sigh", "sighs", "sighing",
        "door closes", "door opens", "door slams",
        "keyboard clicking", "typing", "keyboard typing",
        "phone ringing", "ringing", "beep", "beeping", "click", "clicking",
        "footsteps", "dog barking", "barking",
        "wind", "wind blowing", "rustling",
        "tv", "television", "radio",
    ]

    private static let markerRegex = try! NSRegularExpression(
        pattern: "[\\[\\(]\\s*([^\\]\\)]+?)\\s*[\\]\\)]"
    )

    // Whisper.cpp's classic bare hallucination on silence/near-silence: no brackets,
    // just a short stock phrase (often lifted from its training data's caption/credit
    // style). Matched only against the ENTIRE trimmed output, so a real dictation that
    // merely contains one of these phrases as part of a longer sentence is untouched.
    // Deliberately narrow: only phrases with essentially no legitimate-dictation
    // collision risk (YouTube-outro/caption artifacts). "you", "thanks", "thank you",
    // and "bye"-family phrases were removed after a real acceptance pass confirmed
    // they're plausible complete real dictations (e.g. a one-word chat reply) and
    // whisper-cli output for them ("Bye!", "Thanks.", "Thank you.") was being silently
    // suppressed to empty text with zero user feedback. See TranscriberTests for the
    // regression coverage proving those words now survive.
    private static let hallucinationOnlyPhrases: Set<String> = [
        "thanks for watching",
        "thank you for watching",
        "please subscribe",
        "subscribe to my channel",
        "see you next time",
    ]

    public static func stripWhisperMarkers(_ text: String) -> String {
        let nsText = text as NSString
        let matches = markerRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result = text
        for match in matches.reversed() {
            let innerRange = match.range(at: 1)
            let inner = nsText.substring(with: innerRange)
            if knownMarkers.contains(inner.lowercased().trimmingCharacters(in: .whitespaces)) {
                let fullRange = Range(match.range, in: result)!
                result.replaceSubrange(fullRange, with: "")
            }
        }
        result = result
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if isHallucinationOnly(result) {
            return ""
        }
        return result
    }

    private static func isHallucinationOnly(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let strippedPunctuation = String(
            text.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        )
        let normalized = strippedPunctuation
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Output was punctuation only (".", "...", "?!") once brackets are gone —
        // whisper's other silence tell.
        if normalized.isEmpty {
            return true
        }
        return hallucinationOnlyPhrases.contains(normalized)
    }

    public static func findWhisperBinary() -> String? {
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forResource: "whisper-cli", withExtension: nil, subdirectory: "whisper") {
            candidates.append(bundled.path)
        }
        if let bundledRoot = Bundle.main.url(forResource: "whisper-cli", withExtension: nil) {
            candidates.append(bundledRoot.path)
        }
        candidates += [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        for name in ["whisper-cli", "whisper-cpp"] {
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = [name]
            let pipe = Pipe()
            which.standardOutput = pipe
            which.standardError = Pipe()
            try? which.run()
            which.waitUntilExit()

            let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let result = result, !result.isEmpty {
                return result
            }
        }

        return nil
    }

    public static func modelExists(modelSize: String) -> Bool {
        return findModel(modelSize: modelSize) != nil
    }

    static func findModel(modelSize: String) -> String? {
        let modelFileName = "ggml-\(modelSize).bin"

        var candidates: [String] = []
        if let bundled = Bundle.main.url(forResource: modelFileName, withExtension: nil, subdirectory: "models") {
            candidates.append(bundled.path)
        }
        if let bundledRoot = Bundle.main.url(forResource: "ggml-\(modelSize)", withExtension: "bin") {
            candidates.append(bundledRoot.path)
        }
        candidates += [
            "\(Config.configDir.path)/models/\(modelFileName)",
            "/opt/homebrew/share/whisper-cpp/models/\(modelFileName)",
            "/usr/local/share/whisper-cpp/models/\(modelFileName)",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cache/whisper/\(modelFileName)",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }
}

enum TranscriberError: LocalizedError, Equatable {
    case whisperNotFound
    case modelNotFound(String)
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .whisperNotFound:
            return "whisper-cpp not found. Install it with: brew install whisper-cpp"
        case .modelNotFound(let size):
            return "Whisper model '\(size)' not found. Download it with: open-wispr download-model \(size)"
        case .transcriptionFailed:
            return "Transcription failed"
        }
    }
}
