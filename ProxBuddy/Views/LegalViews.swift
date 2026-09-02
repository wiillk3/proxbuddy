import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        LegalDocumentView(document: .privacyPolicy)
    }
}

struct LicenseTextView: View {
    let document: AppLegal.Document

    var body: some View {
        LegalDocumentView(document: document)
    }
}

private struct LegalDocumentView: View {
    let document: AppLegal.Document

    var body: some View {
        ScrollView {
            Text(AppLegal.text(for: document))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .hackerBackground()
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("OPEN SOURCE CREDITS")
                        .hackerText().font(.caption).opacity(0.8)
                    Text(AppLegal.copyrightLine)
                        .font(.system(.caption, design: .monospaced))
                    Text(AppLegal.warrantyLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("ProxBuddy is licensed under the GNU General Public License v3.0 (GPL-3.0). Corresponding source, including iOS patches and build_pm3_ios.sh, is at github.com/wiillk3/proxbuddy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .liquidGlassCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("LICENSE TEXTS").hackerText().font(.caption).opacity(0.8)
                    VStack(alignment: .leading, spacing: 16) {
                        licenseLink(.gpl3)
                        Divider().background(Color.glassBorder)
                        licenseLink(.gpl2)
                        Divider().background(Color.glassBorder)
                        licenseLink(.apache2)
                    }
                    .liquidGlassCard()
                }

                creditCard(
                    title: "Proxmark3 / RRG Iceman Firmware",
                    authors: "Jonathan Westhues, Iceman (@iceman1001), DXL (@xianglin1998) & RFID Research Group",
                    license: "GPL-2.0-or-later",
                    description: "Native C client bundled as libpm3client.dylib, plus Lua/Python scripts, dictionaries, and resources from the Iceman tree.",
                    url: "https://github.com/RfidResearchGroup/proxmark3"
                )

                creditCard(
                    title: "Proxmark5 BWM ESP32 Firmware",
                    authors: "DXL (@xianglin1998) & RFID Research Group",
                    license: "GPL-3.0 / Apache-2.0 (ESP-IDF)",
                    description: "On-device BLE/Wi-Fi firmware. Not bundled in this app; ProxBuddy talks to it over BLE SPP and TCP.",
                    url: "https://github.com/RfidResearchGroup/Proxmark5_BWM_esp32"
                )

                creditCard(
                    title: "OpenSSL Cryptographic Toolkit (v3.4.1)",
                    authors: "The OpenSSL Project Authors",
                    license: "Apache-2.0",
                    description: "libcrypto, statically linked into bundled pm3 helper tools (staticnested and mfulc_des_brute).",
                    url: "https://www.openssl.org"
                )

                creditCard(
                    title: "Python for iOS (BeeWare Project)",
                    authors: "Python Software Foundation & The BeeWare Project",
                    license: "PSF License & BSD 3-Clause",
                    description: "Embedded Python 3.13 runtime for Proxmark3 Python scripts shipped in the app bundle.",
                    url: "https://beeware.org"
                )

                creditCard(
                    title: "Lua",
                    authors: "Lua.org, PUC-Rio",
                    license: "MIT",
                    description: "Interpreter inside libpm3client and the bundled luascripts / lualibs trees.",
                    url: "https://www.lua.org"
                )

                creditCard(
                    title: "linenoise",
                    authors: "Salvatore Sanfilippo and contributors",
                    license: "BSD-2-Clause",
                    description: "Line editor used instead of readline in the iOS pm3 client build.",
                    url: "https://github.com/antirez/linenoise"
                )

                creditCard(
                    title: "lz4",
                    authors: "Yann Collet and contributors",
                    license: "BSD-2-Clause",
                    description: "Compression library statically linked into libpm3client.",
                    url: "https://github.com/lz4/lz4"
                )

                creditCard(
                    title: "bzip2",
                    authors: "Julian Seward and contributors",
                    license: "BSD-style",
                    description: "Compression library statically linked into libpm3client.",
                    url: "https://sourceware.org/bzip2/"
                )
            }
            .padding()
        }
        .hackerBackground()
        .navigationTitle("Licenses & Credits")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func licenseLink(_ document: AppLegal.Document) -> some View {
        NavigationLink {
            LicenseTextView(document: document)
        } label: {
            HStack {
                Text(document.title)
                    .foregroundStyle(.hackerGreen)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func creditCard(title: String, authors: String, license: String, description: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .hackerText().font(.subheadline)
                Spacer()
                Text(license)
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.hackerGreen.opacity(0.15))
                    .foregroundStyle(.hackerGreen)
                    .clipShape(Capsule())
            }

            Text("Authors: \(authors)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)

            Link(destination: URL(string: url)!) {
                HStack(spacing: 4) {
                    Text(url).font(.system(.caption2, design: .monospaced))
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                }
                .foregroundStyle(.hackerGreen)
            }
        }
        .liquidGlassCard()
    }
}
