import Foundation

public struct LanguageOption: Equatable, Sendable {
    public let code: String
    public let name: String
}

/// Whether dictation is passed through the Pro rewrite service.
/// `off` (default) never touches the network; `auto` rewrites on release.
public enum RewriteMode: String, Codable, Equatable {
    case off
    case auto
}

public struct Config: Codable {
    public var hotkeys: [HotkeyConfig]
    public var modelPath: String?
    public var modelSize: String
    public var language: String
    public var whisperPrompt: String?
    public var spokenPunctuation: FlexBool?
    public var maxRecordings: Int?
    public var toggleMode: FlexBool?
    public var audioInputDeviceID: UInt32?
    public var audioInputDeviceUID: String?
    public var rewriteMode: RewriteMode
    public var editHotkey: HotkeyConfig?
    public var askHotkey: HotkeyConfig?
    public var analyticsOptIn: FlexBool?
    public var localLLMEnabled: FlexBool?
    public var localLLMURL: String?
    public var localLLMModel: String?
    /// Off unless config.json explicitly sets it. Gates `FoundationModelsPipeline`
    /// (Apple's on-device Foundation Models framework, macOS 26+) as a rewrite
    /// pipeline. Absent in old configs, so an old config.json keeps this off,
    /// matching the same "ships off" rule as `localLLMEnabled`/`agentLayerEnabled`.
    /// Even when true, `RewriteGate`/`RewriteCoordinator` only use it when
    /// `FoundationModelsPipeline.isAvailable` is also true (real device/Apple
    /// Intelligence eligibility) — this flag alone never forces the on-device
    /// path over a graceful fallback.
    public var onDeviceAIEnabled: FlexBool?
    public var translateToEnglish: FlexBool?
    /// Off unless a config.json explicitly sets it. Gates the v2 agent-layer
    /// surfaces (Edit and Ask context/screen awareness) independently of, and
    /// before, consent and sign-in — see `EditGate`/`AskGate`. Absent in old
    /// configs, so an old config.json keeps this off, matching CLAUDE.md's rule
    /// that this flag ships off by default.
    public var agentLayerEnabled: FlexBool?

    /// Whether Edit/Ask may run at all, before consent or sign-in are even
    /// considered. True only when config.json sets `agentLayerEnabled`, or, in a
    /// DEBUG build only, when `OPENWISPR_AGENT_LAYER=1` is set in the process
    /// environment for local testing. The environment path never persists
    /// anything to config.json or UserDefaults, so it cannot leak from a DEBUG
    /// session into a release build sharing the same files, and it does not
    /// exist at all in a release binary (the `#if DEBUG` block is compiled out).
    public var isAgentLayerEnabled: Bool {
        if agentLayerEnabled?.value == true { return true }
        #if DEBUG
        if ProcessInfo.processInfo.environment["OPENWISPR_AGENT_LAYER"] == "1" { return true }
        #endif
        return false
    }

    public var hotkey: HotkeyConfig {
        get { hotkeys[0] }
        set { hotkeys = Config.deduplicateHotkeys([newValue]) }
    }

    public func hotkeySummary() -> String {
        var parts = hotkeys.map { KeyCodes.describe(keyCode: $0.keyCode, modifiers: $0.modifiers) }
        // Only shown when the founder explicitly set one in config.json — the
        // Context/Ask hotkey has no synthesized default. Enabling the agent
        // layer flag alone must not start listening for a hotkey nobody chose
        // (see AppDelegate's hotkey registration, which follows the same rule).
        if let ask = askHotkey {
            parts.append("Context/Edit: " + KeyCodes.describe(keyCode: ask.keyCode, modifiers: ask.modifiers))
        }
        return parts.joined(separator: " · ")
    }

    private static func deduplicateHotkeys(_ list: [HotkeyConfig]) -> [HotkeyConfig] {
        var out: [HotkeyConfig] = []
        for h in list where !out.contains(h) {
            out.append(h)
        }
        return out
    }

    private enum CodingKeys: String, CodingKey {
        case hotkey
        case hotkeys
        case modelPath
        case modelSize
        case language
        case whisperPrompt
        case spokenPunctuation
        case maxRecordings
        case toggleMode
        case audioInputDeviceID
        case audioInputDeviceUID
        case rewriteMode
        case editHotkey
        case askHotkey
        case analyticsOptIn
        case localLLMEnabled
        case localLLMURL
        case localLLMModel
        case onDeviceAIEnabled
        case translateToEnglish
        case agentLayerEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let hotkeysList = try c.decodeIfPresent([HotkeyConfig].self, forKey: .hotkeys)
        let legacyHotkey = try c.decodeIfPresent(HotkeyConfig.self, forKey: .hotkey)
        if let list = hotkeysList, !list.isEmpty {
            self.hotkeys = Config.deduplicateHotkeys(list)
        } else if let legacy = legacyHotkey {
            self.hotkeys = [legacy]
        } else {
            self.hotkeys = [HotkeyConfig(keyCode: 63, modifiers: [])]
        }
        self.modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath)
        self.modelSize = try c.decode(String.self, forKey: .modelSize)
        self.language = try c.decode(String.self, forKey: .language)
        self.whisperPrompt = try c.decodeIfPresent(String.self, forKey: .whisperPrompt)
        self.spokenPunctuation = try c.decodeIfPresent(FlexBool.self, forKey: .spokenPunctuation)
        self.maxRecordings = try c.decodeIfPresent(Int.self, forKey: .maxRecordings)
        self.toggleMode = try c.decodeIfPresent(FlexBool.self, forKey: .toggleMode)
        self.audioInputDeviceID = try c.decodeIfPresent(UInt32.self, forKey: .audioInputDeviceID)
        self.audioInputDeviceUID = try c.decodeIfPresent(String.self, forKey: .audioInputDeviceUID)
        let rawMode = (try? c.decodeIfPresent(String.self, forKey: .rewriteMode)) ?? nil
        self.rewriteMode = rawMode
            .flatMap { RewriteMode(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) } ?? .off
        self.editHotkey = try c.decodeIfPresent(HotkeyConfig.self, forKey: .editHotkey)
        self.askHotkey = try c.decodeIfPresent(HotkeyConfig.self, forKey: .askHotkey)
        self.analyticsOptIn = try c.decodeIfPresent(FlexBool.self, forKey: .analyticsOptIn)
        self.localLLMEnabled = try c.decodeIfPresent(FlexBool.self, forKey: .localLLMEnabled)
        self.localLLMURL = try c.decodeIfPresent(String.self, forKey: .localLLMURL)
        self.localLLMModel = try c.decodeIfPresent(String.self, forKey: .localLLMModel)
        self.onDeviceAIEnabled = try c.decodeIfPresent(FlexBool.self, forKey: .onDeviceAIEnabled)
        self.translateToEnglish = try c.decodeIfPresent(FlexBool.self, forKey: .translateToEnglish)
        self.agentLayerEnabled = try c.decodeIfPresent(FlexBool.self, forKey: .agentLayerEnabled)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hotkeys, forKey: .hotkeys)
        try c.encode(hotkeys[0], forKey: .hotkey)
        try c.encodeIfPresent(modelPath, forKey: .modelPath)
        try c.encode(modelSize, forKey: .modelSize)
        try c.encode(language, forKey: .language)
        try c.encodeIfPresent(whisperPrompt, forKey: .whisperPrompt)
        try c.encodeIfPresent(spokenPunctuation, forKey: .spokenPunctuation)
        try c.encodeIfPresent(maxRecordings, forKey: .maxRecordings)
        try c.encodeIfPresent(toggleMode, forKey: .toggleMode)
        try c.encodeIfPresent(audioInputDeviceID, forKey: .audioInputDeviceID)
        try c.encodeIfPresent(audioInputDeviceUID, forKey: .audioInputDeviceUID)
        try c.encode(rewriteMode, forKey: .rewriteMode)
        try c.encodeIfPresent(editHotkey, forKey: .editHotkey)
        try c.encodeIfPresent(askHotkey, forKey: .askHotkey)
        try c.encodeIfPresent(analyticsOptIn, forKey: .analyticsOptIn)
        try c.encodeIfPresent(localLLMEnabled, forKey: .localLLMEnabled)
        try c.encodeIfPresent(localLLMURL, forKey: .localLLMURL)
        try c.encodeIfPresent(localLLMModel, forKey: .localLLMModel)
        try c.encodeIfPresent(onDeviceAIEnabled, forKey: .onDeviceAIEnabled)
        try c.encodeIfPresent(translateToEnglish, forKey: .translateToEnglish)
        try c.encodeIfPresent(agentLayerEnabled, forKey: .agentLayerEnabled)
    }

    public init(
        hotkeys: [HotkeyConfig],
        modelPath: String?,
        modelSize: String,
        language: String,
        whisperPrompt: String? = nil,
        spokenPunctuation: FlexBool?,
        maxRecordings: Int?,
        toggleMode: FlexBool?,
        audioInputDeviceID: UInt32? = nil,
        audioInputDeviceUID: String? = nil,
        rewriteMode: RewriteMode = .off,
        editHotkey: HotkeyConfig? = nil,
        askHotkey: HotkeyConfig? = nil,
        localLLMEnabled: FlexBool? = nil,
        localLLMURL: String? = nil,
        localLLMModel: String? = nil,
        onDeviceAIEnabled: FlexBool? = nil,
        translateToEnglish: FlexBool? = nil,
        agentLayerEnabled: FlexBool? = nil
    ) {
        self.hotkeys = hotkeys.isEmpty
            ? [HotkeyConfig(keyCode: 63, modifiers: [])]
            : Config.deduplicateHotkeys(hotkeys)
        self.modelPath = modelPath
        self.modelSize = modelSize
        self.language = language
        self.whisperPrompt = whisperPrompt
        self.spokenPunctuation = spokenPunctuation
        self.maxRecordings = maxRecordings
        self.toggleMode = toggleMode
        self.audioInputDeviceID = audioInputDeviceID
        self.audioInputDeviceUID = audioInputDeviceUID
        self.rewriteMode = rewriteMode
        self.editHotkey = editHotkey
        self.askHotkey = askHotkey
        self.localLLMEnabled = localLLMEnabled
        self.localLLMURL = localLLMURL
        self.localLLMModel = localLLMModel
        self.onDeviceAIEnabled = onDeviceAIEnabled
        self.translateToEnglish = translateToEnglish
        self.agentLayerEnabled = agentLayerEnabled
    }

    public static let supportedLanguages: [LanguageOption] = [
        LanguageOption(code: "auto", name: "Auto-Detect"),
        LanguageOption(code: "en", name: "English"),
        LanguageOption(code: "zh", name: "Chinese"),
        LanguageOption(code: "de", name: "German"),
        LanguageOption(code: "es", name: "Spanish"),
        LanguageOption(code: "ru", name: "Russian"),
        LanguageOption(code: "ko", name: "Korean"),
        LanguageOption(code: "fr", name: "French"),
        LanguageOption(code: "ja", name: "Japanese"),
        LanguageOption(code: "pt", name: "Portuguese"),
        LanguageOption(code: "tr", name: "Turkish"),
        LanguageOption(code: "pl", name: "Polish"),
        LanguageOption(code: "ca", name: "Catalan"),
        LanguageOption(code: "nl", name: "Dutch"),
        LanguageOption(code: "ar", name: "Arabic"),
        LanguageOption(code: "sv", name: "Swedish"),
        LanguageOption(code: "it", name: "Italian"),
        LanguageOption(code: "id", name: "Indonesian"),
        LanguageOption(code: "hi", name: "Hindi"),
        LanguageOption(code: "fi", name: "Finnish"),
        LanguageOption(code: "vi", name: "Vietnamese"),
        LanguageOption(code: "he", name: "Hebrew"),
        LanguageOption(code: "uk", name: "Ukrainian"),
        LanguageOption(code: "el", name: "Greek"),
        LanguageOption(code: "ms", name: "Malay"),
        LanguageOption(code: "cs", name: "Czech"),
        LanguageOption(code: "ro", name: "Romanian"),
        LanguageOption(code: "da", name: "Danish"),
        LanguageOption(code: "hu", name: "Hungarian"),
        LanguageOption(code: "ta", name: "Tamil"),
        LanguageOption(code: "no", name: "Norwegian"),
        LanguageOption(code: "th", name: "Thai"),
        LanguageOption(code: "ur", name: "Urdu"),
        LanguageOption(code: "hr", name: "Croatian"),
        LanguageOption(code: "bg", name: "Bulgarian"),
        LanguageOption(code: "lt", name: "Lithuanian"),
        LanguageOption(code: "la", name: "Latin"),
        LanguageOption(code: "mi", name: "Maori"),
        LanguageOption(code: "ml", name: "Malayalam"),
        LanguageOption(code: "cy", name: "Welsh"),
        LanguageOption(code: "sk", name: "Slovak"),
        LanguageOption(code: "te", name: "Telugu"),
        LanguageOption(code: "fa", name: "Persian"),
        LanguageOption(code: "lv", name: "Latvian"),
        LanguageOption(code: "bn", name: "Bengali"),
        LanguageOption(code: "sr", name: "Serbian"),
        LanguageOption(code: "az", name: "Azerbaijani"),
        LanguageOption(code: "sl", name: "Slovenian"),
        LanguageOption(code: "kn", name: "Kannada"),
        LanguageOption(code: "et", name: "Estonian"),
        LanguageOption(code: "mk", name: "Macedonian"),
        LanguageOption(code: "br", name: "Breton"),
        LanguageOption(code: "eu", name: "Basque"),
        LanguageOption(code: "is", name: "Icelandic"),
        LanguageOption(code: "hy", name: "Armenian"),
        LanguageOption(code: "ne", name: "Nepali"),
        LanguageOption(code: "mn", name: "Mongolian"),
        LanguageOption(code: "bs", name: "Bosnian"),
        LanguageOption(code: "kk", name: "Kazakh"),
        LanguageOption(code: "sq", name: "Albanian"),
        LanguageOption(code: "sw", name: "Swahili"),
        LanguageOption(code: "gl", name: "Galician"),
        LanguageOption(code: "mr", name: "Marathi"),
        LanguageOption(code: "pa", name: "Punjabi"),
        LanguageOption(code: "si", name: "Sinhala"),
        LanguageOption(code: "km", name: "Khmer"),
        LanguageOption(code: "sn", name: "Shona"),
        LanguageOption(code: "yo", name: "Yoruba"),
        LanguageOption(code: "so", name: "Somali"),
        LanguageOption(code: "af", name: "Afrikaans"),
        LanguageOption(code: "oc", name: "Occitan"),
        LanguageOption(code: "ka", name: "Georgian"),
        LanguageOption(code: "be", name: "Belarusian"),
        LanguageOption(code: "tg", name: "Tajik"),
        LanguageOption(code: "sd", name: "Sindhi"),
        LanguageOption(code: "gu", name: "Gujarati"),
        LanguageOption(code: "am", name: "Amharic"),
        LanguageOption(code: "yi", name: "Yiddish"),
        LanguageOption(code: "lo", name: "Lao"),
        LanguageOption(code: "uz", name: "Uzbek"),
        LanguageOption(code: "fo", name: "Faroese"),
        LanguageOption(code: "ht", name: "Haitian Creole"),
        LanguageOption(code: "ps", name: "Pashto"),
        LanguageOption(code: "tk", name: "Turkmen"),
        LanguageOption(code: "nn", name: "Nynorsk"),
        LanguageOption(code: "mt", name: "Maltese"),
        LanguageOption(code: "sa", name: "Sanskrit"),
        LanguageOption(code: "lb", name: "Luxembourgish"),
        LanguageOption(code: "my", name: "Myanmar"),
        LanguageOption(code: "bo", name: "Tibetan"),
        LanguageOption(code: "tl", name: "Tagalog"),
        LanguageOption(code: "mg", name: "Malagasy"),
        LanguageOption(code: "as", name: "Assamese"),
        LanguageOption(code: "tt", name: "Tatar"),
        LanguageOption(code: "haw", name: "Hawaiian"),
        LanguageOption(code: "ln", name: "Lingala"),
        LanguageOption(code: "ha", name: "Hausa"),
        LanguageOption(code: "ba", name: "Bashkir"),
        LanguageOption(code: "jw", name: "Javanese"),
        LanguageOption(code: "su", name: "Sundanese"),
    ]

    public static let supportedModels: [String] = [
        "tiny.en", "tiny.en-q5_1",
        "tiny",
        "base.en", "base.en-q5_1",
        "base",
        "small.en", "small.en-q5_1",
        "small",
        "medium.en", "medium.en-q5_0",
        "medium",
        "large-v3-turbo", "large-v3-turbo-q8_0", "large-v3-turbo-q5_0",
        "large-v3",
    ]

    public static let modelAliases: [String: String] = [
        "large": "large-v3",
    ]

    public static func resolveModelAlias(_ size: String) -> String {
        return modelAliases[size] ?? size
    }

    public static func isEnglishOnlyModel(_ name: String) -> Bool {
        return name.hasSuffix(".en") || name.contains(".en-")
    }

    public static let defaultMaxRecordings = 0

    public static func effectiveMaxRecordings(_ value: Int?) -> Int {
        let raw = value ?? Config.defaultMaxRecordings
        if raw == 0 { return 0 }
        return min(max(1, raw), 100)
    }

    public static let defaultConfig = Config(
        hotkeys: [HotkeyConfig(keyCode: 63, modifiers: [])],
        modelPath: nil,
        modelSize: "base.en",
        language: "en",
        whisperPrompt: nil,
        spokenPunctuation: FlexBool(false),
        maxRecordings: nil,
        toggleMode: FlexBool(false)
    )

    public static var configDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/open-wispr")
    }

    public static var configFile: URL {
        configDir.appendingPathComponent("config.json")
    }

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: configFile) else {
            let config = Config.defaultConfig
            try? config.save()
            return config
        }

        do {
            var config = try JSONDecoder().decode(Config.self, from: data)
            let resolved = Config.resolveModelAlias(config.modelSize)
            if resolved != config.modelSize {
                config.modelSize = resolved
                try? config.save()
            }
            return config
        } catch {
            fputs("Warning: unable to parse \(configFile.path): \(error.localizedDescription)\n", stderr)
            return Config.defaultConfig
        }
    }

    public static func decode(from data: Data) throws -> Config {
        var config = try JSONDecoder().decode(Config.self, from: data)
        config.modelSize = Config.resolveModelAlias(config.modelSize)
        return config
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(self)
        try data.write(to: Config.configFile)
    }
}

public struct FlexBool: Codable {
    public let value: Bool

    public init(_ value: Bool) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            value = b
        } else if let s = try? container.decode(String.self) {
            value = ["true", "yes", "1"].contains(s.lowercased())
        } else if let i = try? container.decode(Int.self) {
            value = i != 0
        } else {
            value = false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct HotkeyConfig: Codable, Equatable {
    public var keyCode: UInt16
    public var modifiers: [String]

    public init(keyCode: UInt16, modifiers: [String]) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var modifierFlags: UInt64 {
        var flags: UInt64 = 0
        for mod in modifiers {
            switch mod.lowercased() {
            case "cmd", "command": flags |= UInt64(1 << 20)
            case "shift": flags |= UInt64(1 << 17)
            case "ctrl", "control": flags |= UInt64(1 << 18)
            case "opt", "option", "alt": flags |= UInt64(1 << 19)
            default: break
            }
        }
        return flags
    }
}
