import XCTest
@testable import OpenWisprLib

/// Unit tests for Task 6.4: validating that all user-facing strings in `Copy.swift`
/// adhere to brand-voice rules (no banned words, no exclamation marks, proper sentence count).
final class CopyLintTests: XCTestCase {

    private var allCopyStrings: [String] {
        [
            Copy.onboardingWelcome,
            Copy.onboardingMicrophone,
            Copy.onboardingAccessibility,
            Copy.onboardingGetStarted,
            Copy.onboardingAllowMic,
            Copy.onboardingAllowAX,
            Copy.statusIdle,
            Copy.statusRecording,
            Copy.statusTranscribing,
            Copy.statusRewriting,
            Copy.menuCopyLast,
            Copy.menuCopied,
            Copy.menuRewrite,
            Copy.menuRevokeRewriteConsent,
            Copy.menuRevokeContextConsent,
            Copy.menuEnableContext,
            Copy.menuQuit,
            Copy.disclosureTitle,
            Copy.disclosureWhatSentTitle,
            Copy.disclosureWhatSentBody,
            Copy.disclosureToWhomTitle,
            Copy.disclosureToWhomBody,
            Copy.disclosureRetentionTitle,
            Copy.disclosureRetentionBody,
            Copy.disclosureFailureTitle,
            Copy.disclosureFailureBody,
            Copy.disclosureRevoke,
            Copy.disclosureAccept,
            Copy.disclosureDecline,
            Copy.contextConsentTitle,
            Copy.contextConsentSubtitle,
            Copy.contextWhatSent,
            Copy.contextToWhom,
            Copy.contextSafety,
            Copy.askListening,
            Copy.askProcessing,
            Copy.askCopyDismiss,
            Copy.editSecureField,
            Copy.askSecureField,
            Copy.askExcludedApp("TestApp"),
            Copy.editExcludedApp("TestApp"),
            Copy.editExcludedGeneric,
            Copy.injectionBlocked,
            Copy.downloadingModel("1.5 GB", percent: 45),
        ]
    }

    func testNoBannedWordsInCopy() {
        for str in allCopyStrings {
            let lower = str.lowercased()
            for banned in CopyLint.banned {
                XCTAssertFalse(
                    lower.contains(banned),
                    "Copy string contains banned word '\(banned)': \"\(str)\""
                )
            }
        }
    }

    func testNoExclamationMarksInCopy() {
        for str in allCopyStrings {
            XCTAssertFalse(
                str.contains("!"),
                "Copy string contains prohibited exclamation mark: \"\(str)\""
            )
        }
    }

    func testSentenceLengthBoundedInCopy() {
        for str in allCopyStrings {
            let count = CopyLint.sentenceCount(str)
            XCTAssertLessThanOrEqual(
                count,
                2,
                "Copy string exceeds maximum allowed 2 sentences (\(count) sentences): \"\(str)\""
            )
        }
    }
}
