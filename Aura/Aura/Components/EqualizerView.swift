import SwiftUI

/// The equalizer as a response curve: five points on a smooth line, dragged up or down,
/// with the presets under it. Changes are heard at once and saved as they land — this
/// sheet also opens from Now Playing, where the settings page isn't there to save them.
struct EqualizerView: View {
    @State private var appSettings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccentColor) private var accentColor

    private let presetColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    /// Flat isn't among them: it's what Reset goes back to, and the grid comes out even.
    private let presetChoices = EQPreset.allCases.filter { $0 != .flat }

    private var bands: [Float] {
        appSettings.eqPreset == .custom ? appSettings.eqCustomBands : appSettings.eqPreset.bands
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                EQCurveEditor(bands: bands, onChange: setBand, onEnd: { appSettings.save() })
                    .frame(height: 236)
                    .padding(.horizontal, 16)
                    .padding(.top, 22)
                bandReadout
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                presets
                    .padding(.horizontal, 16)
                    .padding(.top, 36)
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Color.themeBg)
        .presentationBackground(Color.themeBg)
        .presentationDragIndicator(.visible)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                Text("equalizer")
                    .auraDisplay(40)
                    .foregroundStyle(.primary)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            Button("Done") { dismiss() }
                .font(.body.weight(.semibold))
                .foregroundStyle(accentColor)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
    }

    private var status: String {
        switch appSettings.eqPreset {
        case .flat: return "Off — every band at 0 dB"
        case .custom: return bands.allSatisfy { $0 == 0 } ? "Custom — flat" : "Custom"
        default: return appSettings.eqPreset.rawValue
        }
    }

    // MARK: - Band values

    /// Each band's gain, and its frequency beneath, under its point on the curve. The gain
    /// is what moves, so it carries the weight; the frequency is only its axis label.
    private var bandReadout: some View {
        GeometryReader { geo in
            ForEach(0..<EQCurveEditor.bandCount, id: \.self) { i in
                VStack(spacing: 1) {
                    Text(Self.gain(bands[i]))
                        .font(.subheadline.weight(bands[i] == 0 ? .medium : .semibold).monospacedDigit())
                        .foregroundStyle(bands[i] == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(accentColor))
                        .contentTransition(.numericText(value: Double(bands[i])))
                    Text(EQPreset.bandLabels[i] + " Hz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                .position(x: EQCurveEditor.x(for: i, width: geo.size.width), y: geo.size.height / 2)
            }
        }
        .frame(height: 40)
    }

    /// Whole decibels without the ".0", and a true minus sign.
    private static func gain(_ value: Float) -> String {
        guard value != 0 else { return "0 dB" }
        return String(format: "%+.1f dB", value)
            .replacingOccurrences(of: ".0 ", with: " ")
            .replacingOccurrences(of: "-", with: "\u{2212}")
    }

    // MARK: - Presets

    private var presets: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Presets")
                    .font(.title3.weight(.semibold))
                Spacer()
                if appSettings.eqPreset != .flat {
                    Button("Reset") { choose(.flat) }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(accentColor)
                }
            }
            .padding(.horizontal, 4)
            LazyVGrid(columns: presetColumns, spacing: 8) {
                ForEach(presetChoices, id: \.self) { preset in
                    presetChip(preset)
                }
            }
        }
    }

    private func presetChip(_ preset: EQPreset) -> some View {
        let isOn = appSettings.eqPreset == preset
        return Button { choose(preset) } label: {
            Text(preset.rawValue)
                .font(.subheadline.weight(isOn ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                // Kept off the capsule's ends, so a long name shrinks before it touches them.
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.88))
                .background(isOn ? AnyShapeStyle(accentColor) : AnyShapeStyle(Color.primary.opacity(0.07)),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Changes

    private func choose(_ preset: EQPreset) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            appSettings.eqPreset = preset
        }
        EqualizerManager.shared.applyPreset(preset)
        appSettings.save()
    }

    /// Editing a preset turns it into Custom, starting from where the preset stood.
    private func setBand(_ index: Int, _ value: Float) {
        if appSettings.eqPreset != .custom {
            appSettings.eqCustomBands = appSettings.eqPreset.bands
            appSettings.eqPreset = .custom
        }
        appSettings.eqCustomBands[index] = value
        EqualizerManager.shared.applyBands(appSettings.eqCustomBands)
    }
}

// MARK: - Curve editor

/// The five gains drawn as one smooth line over a faint dB grid, each gain a point that
/// follows the finger vertically. A touch anywhere takes the nearest point.
private struct EQCurveEditor: View {
    let bands: [Float]
    let onChange: (Int, Float) -> Void
    let onEnd: () -> Void
    @Environment(\.appAccentColor) private var accentColor

    static let bandCount = 5
    /// The dB scale's column, left of the graph.
    static let axisGutter: CGFloat = 30
    /// How far in from each side the outer points sit, so they can be grabbed.
    static let edgeInset: CGFloat = 22
    static let range: ClosedRange<Float> = -12...12
    private static let scaleMarks: Set<Float> = [-12, 0, 12]

    @State private var dragging: Int?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                grid
                EQCurveShape(gains: EQGains(bands), closed: true)
                    .fill(LinearGradient(colors: [accentColor.opacity(0.32), accentColor.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                EQCurveShape(gains: EQGains(bands), closed: false)
                    .stroke(accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                ForEach(0..<Self.bandCount, id: \.self) { i in
                    node(i, at: point(i, in: size))
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(in: size))
        }
        .sensoryFeedback(.selection, trigger: bands.map { $0 == 0 })
        .accessibilityElement(children: .contain)
    }

    private var grid: some View {
        Canvas { context, canvasSize in
            for db: Float in [-12, -6, 0, 6, 12] {
                let y = Self.y(for: db, height: canvasSize.height)
                var line = Path()
                line.move(to: CGPoint(x: Self.axisGutter, y: y))
                line.addLine(to: CGPoint(x: canvasSize.width, y: y))
                let isZero = db == 0
                context.stroke(line, with: .color(.primary.opacity(isZero ? 0.2 : 0.07)),
                               style: StrokeStyle(lineWidth: 1, dash: isZero ? [4, 4] : []))
                if Self.scaleMarks.contains(db) {
                    let label = db == 0 ? "0" : String(format: "%+.0f", db).replacingOccurrences(of: "-", with: "\u{2212}")
                    context.draw(Text(label)
                                    .font(.caption2.weight(.medium).monospacedDigit())
                                    .foregroundStyle(Color.primary.opacity(0.35)),
                                 at: CGPoint(x: Self.axisGutter - 8, y: y), anchor: .trailing)
                }
            }
        }
    }

    private func node(_ i: Int, at position: CGPoint) -> some View {
        let isActive = dragging == i
        return Circle()
            .fill(Color.white)
            .frame(width: isActive ? 22 : 16, height: isActive ? 22 : 16)
            .overlay(Circle().strokeBorder(accentColor, lineWidth: 3))
            .shadow(color: accentColor.opacity(isActive ? 0.6 : 0), radius: 10)
            .position(position)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isActive)
            .accessibilityElement()
            .accessibilityLabel("\(EQPreset.bandLabels[i]) hertz")
            .accessibilityValue(String(format: "%+.1f decibels", bands[i]))
            .accessibilityAdjustableAction { direction in
                let step: Float = direction == .increment ? 1 : -1
                onChange(i, Self.clamp(bands[i] + step))
                onEnd()
            }
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let index = dragging ?? nearestBand(to: gesture.startLocation.x, width: size.width)
                if dragging == nil { dragging = index }
                onChange(index, Self.value(forY: gesture.location.y, height: size.height))
            }
            .onEnded { _ in
                dragging = nil
                onEnd()
            }
    }

    // MARK: Geometry

    private func point(_ i: Int, in size: CGSize) -> CGPoint {
        CGPoint(x: Self.x(for: i, width: size.width),
                y: Self.y(for: Self.clamp(bands[i]), height: size.height))
    }

    private func nearestBand(to x: CGFloat, width: CGFloat) -> Int {
        (0..<Self.bandCount).min { abs(Self.x(for: $0, width: width) - x) < abs(Self.x(for: $1, width: width) - x) } ?? 0
    }

    static func x(for index: Int, width: CGFloat) -> CGFloat {
        let start = axisGutter + edgeInset
        return start + (width - start - edgeInset) * CGFloat(index) / CGFloat(bandCount - 1)
    }

    /// Kept clear of the frame by the node's radius, so the top and bottom points show whole.
    static func y(for value: Float, height: CGFloat) -> CGFloat {
        let pad: CGFloat = 12
        let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        return pad + (height - pad * 2) * (1 - fraction)
    }

    /// Snapped to half a decibel.
    static func value(forY y: CGFloat, height: CGFloat) -> Float {
        let pad: CGFloat = 12
        let fraction = 1 - (y - pad) / max(height - pad * 2, 1)
        let raw = range.lowerBound + Float(max(0, min(1, fraction))) * (range.upperBound - range.lowerBound)
        return (raw * 2).rounded() / 2
    }

    static func clamp(_ value: Float) -> Float {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

// MARK: - Curve shape

/// A smooth line through the five gains (Catmull-Rom, drawn as cubic Béziers), carried
/// flat out to both edges of the graph. Closed, it runs down to the bottom so it can be filled.
private struct EQCurveShape: Shape {
    var gains: EQGains
    let closed: Bool

    var animatableData: EQGains {
        get { gains }
        set { gains = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let values = gains.values
        let points = values.indices.map { i in
            CGPoint(x: EQCurveEditor.x(for: i, width: rect.width),
                    y: EQCurveEditor.y(for: EQCurveEditor.clamp(Float(values[i])), height: rect.height))
        }
        guard let first = points.first, let last = points.last else { return Path() }
        var path = Path()
        let left = EQCurveEditor.axisGutter
        path.move(to: CGPoint(x: left, y: first.y))
        path.addLine(to: first)
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i]
            let p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.addLine(to: CGPoint(x: rect.width, y: last.y))
        if closed {
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: left, y: rect.height))
            path.closeSubpath()
        }
        return path
    }
}

/// The gains as something SwiftUI can animate, so a preset morphs the curve into place.
private struct EQGains: VectorArithmetic {
    var values: [Double]

    init(_ bands: [Float]) { values = bands.map(Double.init) }
    private init(values: [Double]) { self.values = values }

    static var zero: EQGains { EQGains(values: Array(repeating: 0, count: EQCurveEditor.bandCount)) }

    static func + (lhs: EQGains, rhs: EQGains) -> EQGains {
        EQGains(values: zip(lhs.padded, rhs.padded).map(+))
    }

    static func - (lhs: EQGains, rhs: EQGains) -> EQGains {
        EQGains(values: zip(lhs.padded, rhs.padded).map(-))
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }

    /// Always five, whatever the arithmetic was handed.
    private var padded: [Double] {
        values.count >= EQCurveEditor.bandCount
            ? values
            : values + Array(repeating: 0, count: EQCurveEditor.bandCount - values.count)
    }
}

#Preview {
    EqualizerView()
}
