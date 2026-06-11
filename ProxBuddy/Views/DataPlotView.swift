import SwiftUI
import Charts

struct DataPlotView: View {
    let samples: [Double]
    @Environment(\.dismiss) private var dismiss

    // Downsample for chart — keep at most 4096 display points
    private var display: [(x: Int, y: Double)] {
        let cap = 4096
        guard samples.count > cap else {
            return samples.enumerated().map { (.init($0.offset), $0.element) }
        }
        let stride = samples.count / cap
        return Swift.stride(from: 0, to: samples.count, by: stride).map { i in
            let window = samples[i ..< min(i + stride, samples.count)]
            let peak = window.max(by: { abs($0) < abs($1) }) ?? samples[i]
            return (x: i, y: peak)
        }
    }

    private var yMin: Double { (samples.min() ?? -128) }
    private var yMax: Double { (samples.max() ?? 128) }
    private var mean:  Double { samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count) }

    // Visible window = 1024 display points at a time; user can scroll
    private var visibleLen: Int { min(display.count, 1024) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chart
                    .padding(.top, 8)

                Divider()
                    .background(Color.white.opacity(0.1))

                statsBar
            }
            .background(Color.black)
            .navigationTitle("Signal Plot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    shareButton
                }
            }
        }
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            // Zero reference line
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(.white.opacity(0.2))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4, 4]))

            ForEach(display, id: \.x) { pt in
                LineMark(
                    x: .value("Sample", pt.x),
                    y: .value("Amplitude", pt.y)
                )
                .foregroundStyle(Color.green)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) {
                AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel().foregroundStyle(.gray)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel().foregroundStyle(.gray)
            }
        }
        .chartYScale(domain: (yMin * 1.1)...(yMax * 1.1))
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleLen)
        .frame(maxWidth: .infinity)
        .frame(height: 280)
        .padding(.horizontal, 12)
        .background(Color(white: 0.05))
    }

    // MARK: - Stats bar

    private var statsBar: some View {
        HStack(spacing: 0) {
            stat("Samples", "\(samples.count)")
            Divider().frame(height: 32).background(.white.opacity(0.15))
            stat("Min",  String(format: "%.0f", yMin))
            Divider().frame(height: 32).background(.white.opacity(0.15))
            stat("Max",  String(format: "%.0f", yMax))
            Divider().frame(height: 32).background(.white.opacity(0.15))
            stat("Mean", String(format: "%.1f", mean))
            Divider().frame(height: 32).background(.white.opacity(0.15))
            stat("Range", String(format: "%.0f", yMax - yMin))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(white: 0.08))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Share

    private var shareButton: some View {
        let text = samples.map { String(format: "%.0f", $0) }.joined(separator: "\n")
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("pm3_signal.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return ShareLink(item: url) {
            Image(systemName: "square.and.arrow.up")
        }
    }
}
