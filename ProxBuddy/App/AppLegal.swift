import Foundation

enum AppLegal {
    static let sourceURL = URL(string: "https://github.com/spot-rfid/proxbuddy")!
    static let supportURL = URL(string: "https://github.com/spot-rfid/proxbuddy/issues")!
    static let privacyURL = URL(string: "https://github.com/spot-rfid/proxbuddy/blob/main/PRIVACY.md")!
    static let icemanURL = URL(string: "https://github.com/RfidResearchGroup/proxmark3")!

    static let copyrightLine = "Copyright (C) 2026 ProxBuddy Project & Contributors."
    static let warrantyLine = "ProxBuddy is free software under GPL-3.0, provided with absolutely no warranty."

    enum Document: String, CaseIterable, Identifiable {
        case privacyPolicy = "PRIVACY"
        case gpl3 = "GPL-3.0"
        case gpl2 = "GPL-2.0"
        case apache2 = "Apache-2.0"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .privacyPolicy: "Privacy Policy"
            case .gpl3: "GNU GPL version 3"
            case .gpl2: "GNU GPL version 2"
            case .apache2: "Apache License 2.0"
            }
        }

        var fileExtension: String {
            self == .privacyPolicy ? "md" : "txt"
        }

        var subdirectory: String? {
            self == .privacyPolicy ? nil : "Legal"
        }
    }

    static func text(for document: Document) -> String {
        let bundled: URL?
        if let subdirectory = document.subdirectory {
            bundled = Bundle.main.url(
                forResource: document.rawValue,
                withExtension: document.fileExtension,
                subdirectory: subdirectory
            ) ?? Bundle.main.url(
                forResource: document.rawValue,
                withExtension: document.fileExtension
            )
        } else {
            bundled = Bundle.main.url(
                forResource: document.rawValue,
                withExtension: document.fileExtension
            )
        }
        if let bundled,
           let text = try? String(contentsOf: bundled, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if document == .privacyPolicy {
            return fallbackPrivacyPolicy
        }
        return "This license text is missing from the app bundle. See \(sourceURL.absoluteString)."
    }

    static let fallbackPrivacyPolicy = """
    ProxBuddy does not require an account and does not include analytics or advertising SDKs. \
    Terminal history, dumps, logs, and optional location sidecars stay in the app container. \
    Bluetooth and local network are used only to talk to your Proxmark. \
    Location tagging is off by default. \
    Full policy: \(privacyURL.absoluteString)
    """
}
