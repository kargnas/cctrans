import Foundation
import NaturalLanguage

public struct TranslationLanguageOption: Equatable, Sendable {
    public let name: String
    public let code: String?

    public init(name: String, code: String?) {
        self.name = name
        self.code = code
    }
}

public struct TranslationLanguageDetection: Equatable, Sendable {
    public let language: String
    public let confidence: Double?

    public init(language: String, confidence: Double?) {
        self.language = language
        self.confidence = confidence
    }
}

public struct ResolvedTranslationLanguages: Equatable, Sendable {
    public let sourceLanguage: String
    public let targetLanguage: String
    public let detectedSourceLanguage: String?
    public let didReverseBecauseLanguagesMatched: Bool

    public init(
        sourceLanguage: String,
        targetLanguage: String,
        detectedSourceLanguage: String?,
        didReverseBecauseLanguagesMatched: Bool
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.detectedSourceLanguage = detectedSourceLanguage
        self.didReverseBecauseLanguagesMatched = didReverseBecauseLanguagesMatched
    }
}

public enum TranslationLanguage {
    public static let auto = "Auto"

    public static let options: [TranslationLanguageOption] = [
        TranslationLanguageOption(name: auto, code: nil),
        TranslationLanguageOption(name: "English", code: "en"),
        TranslationLanguageOption(name: "Korean", code: "ko"),
        TranslationLanguageOption(name: "Simplified Chinese", code: "zh-Hans"),
        TranslationLanguageOption(name: "Japanese", code: "ja"),
        TranslationLanguageOption(name: "Spanish", code: "es"),
        TranslationLanguageOption(name: "German", code: "de"),
        TranslationLanguageOption(name: "French", code: "fr"),
        TranslationLanguageOption(name: "Indonesian", code: "id"),
        TranslationLanguageOption(name: "Arabic", code: "ar"),
    ]

    public static var sourceLanguageNames: [String] {
        options.map(\.name)
    }

    public static var targetLanguageNames: [String] {
        options.map(\.name).filter { $0 != auto }
    }

    public static func normalizedName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return auto
        }
        if let option = options.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return option.name
        }
        if let option = options.first(where: { $0.code?.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return option.name
        }
        return trimmed
    }

    public static func reverseTarget(for sourceLanguage: String, preferredTargetLanguage: String) -> String {
        let source = normalizedName(sourceLanguage)
        let preferred = normalizedName(preferredTargetLanguage)
        guard source == preferred else {
            return preferred
        }
        if source == "Korean" {
            return "English"
        }
        if source == "English" {
            return "Korean"
        }
        return "English"
    }

    public static func languageName(for nlLanguage: NLLanguage) -> String? {
        let rawValue = nlLanguage.rawValue.lowercased()
        if rawValue.hasPrefix("en") { return "English" }
        if rawValue.hasPrefix("ko") { return "Korean" }
        if rawValue.hasPrefix("zh") { return "Simplified Chinese" }
        if rawValue.hasPrefix("ja") { return "Japanese" }
        if rawValue.hasPrefix("es") { return "Spanish" }
        if rawValue.hasPrefix("de") { return "German" }
        if rawValue.hasPrefix("fr") { return "French" }
        if rawValue.hasPrefix("id") { return "Indonesian" }
        if rawValue.hasPrefix("ar") { return "Arabic" }
        return nil
    }
}

public enum TranslationLanguageDetector {
    public static func detect(_ text: String) -> TranslationLanguageDetection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let scriptLanguage = dominantScriptLanguage(in: trimmed) {
            return TranslationLanguageDetection(language: scriptLanguage, confidence: 0.95)
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let best = hypotheses
            .compactMap { language, confidence -> TranslationLanguageDetection? in
                guard let name = TranslationLanguage.languageName(for: language) else {
                    return nil
                }
                return TranslationLanguageDetection(language: name, confidence: confidence)
            }
            .max { ($0.confidence ?? 0) < ($1.confidence ?? 0) }
        return best
    }

    private static func dominantScriptLanguage(in text: String) -> String? {
        var korean = 0
        var japanese = 0
        var chinese = 0
        var arabic = 0
        var latin = 0

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
                korean += 1
            case 0x3040...0x30FF:
                japanese += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF:
                chinese += 1
            case 0x0600...0x06FF, 0x0750...0x077F:
                arabic += 1
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F:
                latin += 1
            default:
                continue
            }
        }

        // A CJK/Arabic script only wins when it is the majority of the
        // letter-bearing characters. Without the Latin count, a single Korean
        // word inside an English sentence ("I love 김치") would flip detection
        // to Korean; NLLanguageRecognizer handles the mixed-script remainder.
        let counts = [
            ("Korean", korean),
            ("Japanese", japanese),
            ("Simplified Chinese", chinese),
            ("Arabic", arabic),
        ]
        guard let maxCount = counts.max(by: { $0.1 < $1.1 }),
              maxCount.1 >= 2,
              maxCount.1 > latin else {
            return nil
        }
        return maxCount.0
    }
}

public enum TranslationLanguageResolver {
    public static func resolve(
        text: String,
        sourceLanguage requestedSourceLanguage: String,
        targetLanguage requestedTargetLanguage: String
    ) -> ResolvedTranslationLanguages {
        let normalizedTarget = TranslationLanguage.normalizedName(requestedTargetLanguage)
        let normalizedSource = TranslationLanguage.normalizedName(requestedSourceLanguage)
        let detection = normalizedSource == TranslationLanguage.auto
            ? TranslationLanguageDetector.detect(text)
            : nil
        let source = detection?.language ?? normalizedSource
        let target = TranslationLanguage.reverseTarget(for: source, preferredTargetLanguage: normalizedTarget)

        return ResolvedTranslationLanguages(
            sourceLanguage: source,
            targetLanguage: target,
            detectedSourceLanguage: detection?.language,
            didReverseBecauseLanguagesMatched: target != normalizedTarget
        )
    }
}
