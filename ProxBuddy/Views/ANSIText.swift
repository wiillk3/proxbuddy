import SwiftUI

struct ANSIText: View {
    let line: TerminalLine
    let showTimestamp: Bool

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if showTimestamp {
                Text(ANSIText.timeFmt.string(from: line.timestamp))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.gray)
                    .fixedSize()
            }
            Text(line.attributedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
