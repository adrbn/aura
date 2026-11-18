import SwiftUI

/// The equalizer, in three trial layouts the owner switches between from the header: a
/// response curve, a console of faders, and preset cards. They share one state and the
/// same actions; only the presentation differs. Changes are heard at once and saved as
/// they land — this sheet also opens from Now Playing, where the settings page isn't
/// there to save them.
struct EqualizerView: View {
    @State private var appSettings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("design_trial_equalizer") private var variant = 0

    private var bands: [Float] {
        appSettings.eqPreset == .custom ? appSettings.eqCustomBands : appSettings.eqPreset.bands
    }

    private var controls: EQControls {
        EQControls(bands: bands, customBands: appSettings.eqCustomBands, preset: appSettings.eqPreset,
                   choose: choose, setBand: setBand, commit: { appSettings.save() })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch variant {
                case 1: EQConsoleLayout(eq: controls)
                case 2: EQCardsLayout(eq: controls)
                default: EQCurveLayout(eq: controls)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Color.themeBg)
        // A tick each time a band lands on, or leaves, 0 dB.
        .sensoryFeedback(.selection, trigger: bands.map { $0 == 0 })
        .presentationBackground(Color.themeBg)
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("equalizer")
                .auraDisplay(40)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            DesignTrialSwitcher(variant: $variant)
            Button("Done") { dismiss() }
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.primary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
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

// MARK: - Shared state and scale

/// What every layout reads and calls; the layouts own nothing but their gestures.
private struct EQControls {
    let bands: [Float]
    let customBands: [Float]
    let preset: EQPreset
    let choose: (EQPreset) -> Void
    let setBand: (Int, Float) -> Void
    let commit: () -> Void

    static let bandCount = 5
    /// Custom first — it brings back your own curve — then the presets. Flat is Reset.
    static let presetChoices: [EQPreset] = [.custom] + EQPreset.allCases.filter { $0 != .flat && $0 != .custom }
}

private enum EQScale {
    static let range: ClosedRange<Float> = -12...12
    static var span: Float { range.upperBound - range.lowerBound }

    static func clamp(_ value: Float) -> Float {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// Half-decibel steps, with a small detent at 0 dB so flat is easy to find by feel.
    static func snap(_ raw: Float) -> Float {
        let value = clamp(raw)
        return abs(value) < 0.75 ? 0 : (value * 2).rounded() / 2
    }

    /// 0 at the bottom of the range, 1 at the top.
    static func fraction(_ value: Float) -> CGFloat {
        CGFloat((clamp(value) - range.lowerBound) / span)
    }

    /// Whole decibels without the ".0", and a true minus sign.
    static func gain(_ value: Float) -> String {
        guard value != 0 else { return "0 dB" }
        return String(format: "%+.1f dB", value)
            .replacingOccurrences(of: ".0 ", with: " ")
            .replacingOccurrences(of: "-", with: "\u{2212}")
    }

    static func mark(_ db: Float) -> String {
        db == 0 ? "0" : String(format: "%+.0f", db).replacingOccurrences(of: "-", with: "\u{2212}")
    }
}

/// A drag that moves a value by how far the finger travels, 1:1 with the track — never a
/// jump to where the finger first landed.
private struct EQValueDrag: ViewModifier {
    let value: Float
    /// Points the finger travels across the whole dB range.
    let length: CGFloat
    let axis: Axis
    @Binding var isActive: Bool
    let onChange: (Float) -> Void
    let onEnd: () -> Void
    @State private var base: Float?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let start = base ?? value
                        if base == nil { base = value; isActive = true }
                        let travel = axis == .vertical ? -gesture.translation.height : gesture.translation.width
                        onChange(EQScale.snap(start + Float(travel / max(length, 1)) * EQScale.span))
                    }
                    .onEnded { _ in
                        base = nil
                        isActive = false
                        onEnd()
                    }
            )
    }
}

private extension View {
    func eqAdjustable(_ index: Int, value: Float, eq: EQControls) -> some View {
        accessibilityElement()
            .accessibilityLabel("\(EQPreset.bandLabels[index]) hertz")
            .accessibilityValue(String(format: "%+.1f decibels", value))
            .accessibilityAdjustableAction { direction in
                let step: Float = direction == .increment ? 1 : -1
                eq.setBand(index, EQScale.clamp(value + step))
                eq.commit()
            }
    }
}

// MARK: - Shared presets row

/// "Presets", Reset when there's something to reset, and the presets in one sliding row.
private struct EQPresetRow: View {
    let eq: EQControls

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EQPresetsTitle(eq: eq)
                .padding(.horizontal, 20)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(EQControls.presetChoices, id: \.self) { preset in
                                EQPresetChip(preset: preset, isOn: eq.preset == preset) { eq.choose(preset) }
                                    .id(preset)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(eq.preset, anchor: .center) }
            }
        }
    }
}

private struct EQPresetsTitle: View {
    let eq: EQControls
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Presets")
                .font(.title3.weight(.semibold))
            Spacer()
            if eq.preset != .flat {
                Button {
                    eq.choose(.flat)
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accentColor)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
    }
}

private struct EQPresetChip: View {
    let preset: EQPreset
    let isOn: Bool
    let action: () -> Void
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(preset.rawValue))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .foregroundStyle(isOn ? Color.white : accentColor)
                .glassEffect(isOn ? .regular.tint(accentColor).interactive() : .regular.interactive(),
                             in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - 1 · Curve

/// The gains as one big curve with its handles on it, the values under each handle and
/// the presets sliding beneath. The curve takes whatever height the sheet has left; only
/// when there is none to spare — large text — does the page scroll instead.
private struct EQCurveLayout: View {
    let eq: EQControls

    var body: some View {
        ViewThatFits(in: .vertical) {
            page(fillsHeight: true)
            ScrollView { page(fillsHeight: false) }
                .scrollIndicators(.hidden)
        }
    }

    private func page(fillsHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            EQCurveEditor(eq: eq)
                .frame(minHeight: 260, maxHeight: fillsHeight ? .infinity : 260)
                .padding(.horizontal, 16)
                .padding(.top, 24)
            bandReadout
                .padding(.horizontal, 16)
                .padding(.top, 8)
            EQPresetRow(eq: eq)
                .padding(.top, 32)
        }
        .padding(.bottom, 24)
    }

    /// Each band's gain, and its frequency beneath, under its handle.
    private var bandReadout: some View {
        GeometryReader { geo in
            ForEach(0..<EQControls.bandCount, id: \.self) { i in
                let value = eq.bands[i]
                VStack(spacing: 1) {
                    Text(verbatim: EQScale.gain(value))
                        .font(.subheadline.weight(value == 0 ? .medium : .semibold).monospacedDigit())
                        .foregroundStyle(value == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .contentTransition(.numericText(value: Double(value)))
                    Text(verbatim: EQPreset.bandLabels[i] + " Hz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                .position(x: EQPlot.editor.x(i, width: geo.size.width), y: geo.size.height / 2)
            }
        }
        .frame(height: 40)
    }
}

/// The five gains drawn as one smooth line over a faint dB grid. A touch anywhere takes
/// the nearest handle, which then follows the finger 1:1 from where it stood.
private struct EQCurveEditor: View {
    let eq: EQControls
    @Environment(\.appAccentColor) private var accentColor
    @State private var dragging: Int?
    @State private var base: Float = 0

    private let plot = EQPlot.editor

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                grid
                EQCurveShape(gains: EQGains(eq.bands), closed: true, plot: plot)
                    .fill(LinearGradient(colors: [accentColor.opacity(0.32), accentColor.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                EQCurveShape(gains: EQGains(eq.bands), closed: false, plot: plot)
                    .stroke(accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                ForEach(0..<EQControls.bandCount, id: \.self) { i in
                    handle(i, at: CGPoint(x: plot.x(i, width: size.width), y: plot.y(eq.bands[i], height: size.height)))
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(in: size))
        }
        .accessibilityElement(children: .contain)
    }

    private var grid: some View {
        Canvas { context, canvasSize in
            for db: Float in [-12, -6, 0, 6, 12] {
                let y = plot.y(db, height: canvasSize.height)
                var line = Path()
                line.move(to: CGPoint(x: plot.gutter, y: y))
                line.addLine(to: CGPoint(x: canvasSize.width, y: y))
                let isZero = db == 0
                context.stroke(line, with: .color(.primary.opacity(isZero ? 0.2 : 0.07)),
                               style: StrokeStyle(lineWidth: 1, dash: isZero ? [4, 4] : []))
                if abs(db) != 6 {
                    context.draw(Text(verbatim: EQScale.mark(db))
                                    .font(.caption2.weight(.medium).monospacedDigit())
                                    .foregroundStyle(Color.primary.opacity(0.35)),
                                 at: CGPoint(x: plot.gutter - 8, y: y), anchor: .trailing)
                }
            }
        }
    }

    /// The handle under the finger grows and carries its gain above it, clear of the thumb.
    private func handle(_ i: Int, at position: CGPoint) -> some View {
        let isActive = dragging == i
        return ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: isActive ? 24 : 16, height: isActive ? 24 : 16)
                .overlay(Circle().strokeBorder(accentColor, lineWidth: 3))
                .shadow(color: accentColor.opacity(isActive ? 0.6 : 0), radius: 10)
            if isActive {
                Text(verbatim: EQScale.gain(eq.bands[i]))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .glassEffect(.regular, in: Capsule())
                    .fixedSize()
                    .offset(y: -40)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .position(position)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isActive)
        .eqAdjustable(i, value: eq.bands[i], eq: eq)
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let index: Int
                if let dragging {
                    index = dragging
                } else {
                    index = nearestBand(to: gesture.startLocation.x, width: size.width)
                    base = eq.bands[index]
                    dragging = index
                }
                let travel = Float(-gesture.translation.height / max(plot.length(height: size.height), 1))
                eq.setBand(index, EQScale.snap(base + travel * EQScale.span))
            }
            .onEnded { _ in
                dragging = nil
                eq.commit()
            }
    }

    private func nearestBand(to x: CGFloat, width: CGFloat) -> Int {
        (0..<EQControls.bandCount).min { abs(plot.x($0, width: width) - x) < abs(plot.x($1, width: width) - x) } ?? 0
    }
}

// MARK: - 2 · Console

/// Five tall faders on a shared dB scale, each reading its gain over the top. The fill
/// runs from the 0 dB line to the thumb, up or down.
private struct EQConsoleLayout: View {
    let eq: EQControls

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                scale
                ForEach(0..<EQControls.bandCount, id: \.self) { i in
                    EQFader(index: i, eq: eq)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.top, 24)
            .frame(minHeight: 280, maxHeight: .infinity)
            EQPresetRow(eq: eq)
                .padding(.top, 28)
                .padding(.bottom, 24)
        }
    }

    /// The marks at ±12, ±6 and 0, laid out on the same track geometry as the faders.
    private var scale: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: EQFader.readoutHeight)
            GeometryReader { geo in
                ForEach([Float(12), 6, 0, -6, -12], id: \.self) { db in
                    Text(verbatim: EQScale.mark(db))
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(Color.primary.opacity(db == 0 ? 0.5 : 0.3))
                        .position(x: geo.size.width / 2, y: EQFader.y(db, height: geo.size.height))
                }
            }
            Color.clear.frame(height: EQFader.labelHeight)
        }
        .frame(width: 28)
    }
}

private struct EQFader: View {
    let index: Int
    let eq: EQControls
    @Environment(\.appAccentColor) private var accentColor
    @State private var isDragging = false

    static let readoutHeight: CGFloat = 36
    static let labelHeight: CGFloat = 32
    /// Half the thumb's height, so the thumb stays whole at either end.
    static let pad: CGFloat = 14

    static func y(_ value: Float, height: CGFloat) -> CGFloat {
        pad + (height - pad * 2) * (1 - EQScale.fraction(value))
    }

    private var value: Float { eq.bands[index] }

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: EQScale.gain(value))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(value == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(accentColor))
                .contentTransition(.numericText(value: Double(value)))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: Self.readoutHeight, alignment: .top)
            GeometryReader { geo in
                track(in: geo.size)
                    .modifier(EQValueDrag(value: value, length: geo.size.height - Self.pad * 2, axis: .vertical,
                                          isActive: $isDragging,
                                          onChange: { eq.setBand(index, $0) }, onEnd: eq.commit))
            }
            Text(verbatim: EQPreset.bandLabels[index] + " Hz")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: Self.labelHeight)
        }
        .eqAdjustable(index, value: value, eq: eq)
    }

    private func track(in size: CGSize) -> some View {
        let midX = size.width / 2
        let zeroY = Self.y(0, height: size.height)
        let thumbY = Self.y(value, height: size.height)
        return ZStack {
            Canvas { context, canvas in
                for db: Float in [-12, -6, 0, 6, 12] {
                    let y = Self.y(db, height: canvas.height)
                    let half: CGFloat = db == 0 ? 18 : 10
                    var tick = Path()
                    tick.move(to: CGPoint(x: midX - half, y: y))
                    tick.addLine(to: CGPoint(x: midX + half, y: y))
                    context.stroke(tick, with: .color(.primary.opacity(db == 0 ? 0.35 : 0.14)), lineWidth: 1)
                }
            }
            Capsule()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 4, height: size.height - Self.pad * 2)
                .position(x: midX, y: size.height / 2)
            Capsule()
                .fill(accentColor)
                .frame(width: 4, height: abs(thumbY - zeroY))
                .position(x: midX, y: (thumbY + zeroY) / 2)
            Capsule()
                .fill(Color.clear)
                .frame(width: 44, height: 28)
                .glassEffect(.regular.interactive(), in: Capsule())
                .overlay(Capsule().fill(value == 0 ? Color.primary.opacity(0.6) : accentColor).frame(width: 18, height: 3))
                .scaleEffect(isDragging ? 1.15 : 1)
                .shadow(color: accentColor.opacity(isDragging ? 0.45 : 0), radius: 12)
                .position(x: midX, y: thumbY)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isDragging)
        }
    }
}

// MARK: - 3 · Cards

/// The presets first, each a card that shows its curve. Custom sits on top and opens
/// into fine sliders for the five bands.
private struct EQCardsLayout: View {
    let eq: EQControls
    @Environment(\.appAccentColor) private var accentColor
    @State private var showsBands: Bool

    init(eq: EQControls) {
        self.eq = eq
        _showsBands = State(initialValue: eq.preset == .custom)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 10) {
                VStack(alignment: .leading, spacing: 14) {
                    customCard
                    EQPresetsTitle(eq: eq)
                        .padding(.horizontal, 4)
                        .padding(.top, 14)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(EQControls.presetChoices.filter { $0 != .custom }, id: \.self) { preset in
                            EQPresetCard(preset: preset, bands: preset.bands, isOn: eq.preset == preset) {
                                eq.choose(preset)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }
        }
        .scrollIndicators(.hidden)
    }

    private var customCard: some View {
        let isOn = eq.preset == .custom
        return VStack(spacing: 0) {
            Button {
                if !isOn { eq.choose(.custom) }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showsBands.toggle() }
            } label: {
                HStack(spacing: 14) {
                    EQMiniCurve(bands: isOn ? eq.bands : eq.customBands, isOn: isOn)
                        .frame(width: 96, height: 44)
                    Text("Custom")
                        .font(.headline)
                        .foregroundStyle(isOn ? accentColor : Color.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsBands ? 180 : 0))
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            if showsBands {
                VStack(spacing: 6) {
                    ForEach(0..<EQControls.bandCount, id: \.self) { i in
                        EQFineSlider(index: i, eq: eq)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct EQPresetCard: View {
    let preset: EQPreset
    let bands: [Float]
    let isOn: Bool
    let action: () -> Void
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                EQMiniCurve(bands: bands, isOn: isOn)
                    .frame(height: 40)
                Text(LocalizedStringKey(preset.rawValue))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(isOn ? accentColor : Color.primary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(isOn ? .regular.tint(accentColor.opacity(0.3)).interactive() : .regular.interactive(),
                         in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A card's curve: the same line as the editor's, small, lit in the accent when chosen.
private struct EQMiniCurve: View {
    let bands: [Float]
    let isOn: Bool
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        let tint = isOn ? accentColor : Color.primary.opacity(0.55)
        ZStack {
            EQCurveShape(gains: EQGains(bands), closed: true, plot: .mini)
                .fill(LinearGradient(colors: [tint.opacity(isOn ? 0.35 : 0.15), tint.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
            EQCurveShape(gains: EQGains(bands), closed: false, plot: .mini)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

/// One band across the card: frequency, a centred track that fills from 0 dB, the gain.
private struct EQFineSlider: View {
    let index: Int
    let eq: EQControls
    @Environment(\.appAccentColor) private var accentColor
    @State private var isDragging = false

    private var value: Float { eq.bands[index] }
    private let pad: CGFloat = 12

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: EQPreset.bandLabels[index] + " Hz")
                .font(.footnote.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            GeometryReader { geo in
                track(in: geo.size)
                    .modifier(EQValueDrag(value: value, length: geo.size.width - pad * 2, axis: .horizontal,
                                          isActive: $isDragging,
                                          onChange: { eq.setBand(index, $0) }, onEnd: eq.commit))
            }
            .frame(height: 40)
            Text(verbatim: EQScale.gain(value))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(value == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(accentColor))
                .contentTransition(.numericText(value: Double(value)))
                .frame(width: 62, alignment: .trailing)
        }
        .eqAdjustable(index, value: value, eq: eq)
    }

    private func track(in size: CGSize) -> some View {
        let x = { (v: Float) in pad + (size.width - pad * 2) * EQScale.fraction(v) }
        let midY = size.height / 2
        let zeroX = x(0), thumbX = x(value)
        return ZStack {
            Capsule()
                .fill(Color.primary.opacity(0.1))
                .frame(width: size.width - pad * 2, height: 4)
                .position(x: size.width / 2, y: midY)
            Rectangle()
                .fill(Color.primary.opacity(0.35))
                .frame(width: 1, height: 12)
                .position(x: zeroX, y: midY)
            Capsule()
                .fill(accentColor)
                .frame(width: abs(thumbX - zeroX), height: 4)
                .position(x: (thumbX + zeroX) / 2, y: midY)
            Circle()
                .fill(Color.white)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(accentColor, lineWidth: value == 0 ? 0 : 3))
                .scaleEffect(isDragging ? 1.2 : 1)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                .position(x: thumbX, y: midY)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isDragging)
        }
    }
}

// MARK: - Curve geometry and shape

/// Where the five gains sit inside a rect: a left gutter for the dB scale, an inset so the
/// outer points can be grabbed, and a vertical pad so the top and bottom points show whole.
private struct EQPlot {
    let gutter: CGFloat
    let inset: CGFloat
    let pad: CGFloat

    static let editor = EQPlot(gutter: 30, inset: 26, pad: 14)
    static let mini = EQPlot(gutter: 0, inset: 3, pad: 3)

    func x(_ index: Int, width: CGFloat) -> CGFloat {
        let start = gutter + inset
        return start + (width - start - inset) * CGFloat(index) / CGFloat(EQControls.bandCount - 1)
    }

    func y(_ value: Float, height: CGFloat) -> CGFloat {
        pad + length(height: height) * (1 - EQScale.fraction(value))
    }

    func length(height: CGFloat) -> CGFloat { height - pad * 2 }
}

/// A smooth line through the five gains (Catmull-Rom, drawn as cubic Béziers), carried
/// flat out to both edges. Closed, it runs down to the bottom so it can be filled.
private struct EQCurveShape: Shape {
    var gains: EQGains
    let closed: Bool
    let plot: EQPlot

    var animatableData: EQGains {
        get { gains }
        set { gains = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let values = gains.values
        let points = values.indices.map { i in
            CGPoint(x: plot.x(i, width: rect.width), y: plot.y(Float(values[i]), height: rect.height))
        }
        guard let first = points.first, let last = points.last else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: plot.gutter, y: first.y))
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
            path.addLine(to: CGPoint(x: plot.gutter, y: rect.height))
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

    static var zero: EQGains { EQGains(values: Array(repeating: 0, count: EQControls.bandCount)) }

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
        values.count >= EQControls.bandCount
            ? values
            : values + Array(repeating: 0, count: EQControls.bandCount - values.count)
    }
}

#Preview {
    EqualizerView()
}
