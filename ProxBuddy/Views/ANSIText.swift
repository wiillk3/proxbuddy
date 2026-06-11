import SwiftUI

struct ANSIText: View {
    let raw: String
    let showTimestamp: Bool
    let timestamp: Date
    let isInput: Bool

    @AppStorage("terminalFontSize") private var fontSize: Double = 13

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if showTimestamp {
                Text(ANSIText.timeFmt.string(from: timestamp))
                    .font(.system(size: CGFloat(fontSize) * 0.85, design: .monospaced))
                    .foregroundStyle(.gray)
                    .fixedSize()
            }
            Text(ANSIParser.parse(
                raw,
                fontSize: CGFloat(fontSize),
                defaultColor: isInput ? ANSIParser.inputDefault : ANSIParser.outputDefault
            ))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
