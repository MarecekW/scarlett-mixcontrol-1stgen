import SwiftUI

/// A vertical dB axis shared by a strip's fader, meter and scale, so all
/// three agree on where every level sits.
///
/// The spacing follows the usual console / Focusrite Control meter law:
/// even 6 dB steps from the top down to -30 dB, where the detail matters,
/// then a compressed -30 / -36 / -48 / -60 tail and one last step down to
/// `off` (-∞), so a fader pulled all the way down mutes.  Every axis has
/// the same physical extent (from `inset` to `height - inset`, the knob's
/// centre line at either end of its travel), so tracks and meters line up
/// from strip to strip; only the top value differs.
struct DbAxis {
    /// Scale breakpoints, top to bottom.  The first is the axis' top value.
    let breakpoints: [Double]

    /// Matrix channel gain (input and DAW strips): up to +6 dB.
    static let gain = DbAxis(breakpoints: [6] + Self.levels)
    /// Output attenuation (Monitor, Phones, line outs): 0 dB at the top.
    static let attenuation = DbAxis(breakpoints: Self.levels)

    /// The bottom of every axis: the device treats -128 dB as off.
    static let off: Double = -128
    /// Quietest level meters and peak readouts show; below it is the
    /// device's noise floor (shown as -∞).
    static let meterFloor: Double = -60

    private static let levels: [Double] = [0, -6, -12, -18, -24, -30, -36, -48, -60, off]
    /// Relative height of the segment below breakpoint `db`: full steps
    /// down to -30 dB, a little over half a step for each in the tail, and
    /// a short last step from -60 dB to off.
    private static func weight(below db: Double) -> Double {
        if db > -30 { return 1 }
        if db > -60 { return 0.55 }
        return 0.28
    }

    static let inset: CGFloat = VerticalFader.knobHeight / 2

    var top: Double { breakpoints.first ?? 0 }
    var bottom: Double { breakpoints.last ?? Self.off }

    /// Marks at the breakpoints (all but `off`), and minor ticks halfway
    /// between them.
    var majorTicks: [Double] { breakpoints.filter { $0 > Self.off } }
    var minorTicks: [Double] {
        zip(majorTicks, majorTicks.dropFirst()).map { ($0 + $1) / 2 }
    }

    /// Readout for a fader level: "-7.0", "+3.0", or "-∞" at the bottom.
    static func format(_ db: Double) -> String {
        if db <= off { return "−∞" }
        let tenths = (db * 10).rounded() / 10
        if tenths == 0 { return "0.0" }   // not "-0.0"
        return String(format: tenths > 0 ? "+%.1f" : "%.1f", tenths)
    }

    /// Position of `db` from the bottom of the axis, 0...1.
    private func fraction(_ db: Double) -> Double {
        let value = db.isFinite ? min(max(db, bottom), top) : bottom
        var below = 0.0, total = 0.0
        for (upper, lower) in zip(breakpoints, breakpoints.dropFirst()) {
            let w = Self.weight(below: upper)
            total += w
            if value >= upper { below += w }
            else if value > lower { below += w * (value - lower) / (upper - lower) }
        }
        return total > 0 ? below / total : 0
    }

    /// Vertical position of `db` in a column of `height`, from the top.
    func y(_ db: Double, height: CGFloat) -> CGFloat {
        Self.inset + (height - 2 * Self.inset) * CGFloat(1 - fraction(db))
    }

    /// Inverse of `y(_:height:)`, clamped to the axis.
    func db(atY y: CGFloat, height: CGFloat) -> Double {
        let target = 1 - Double((y - Self.inset) / (height - 2 * Self.inset))
        // Snap the ends, so the bottom is exactly `off` (mute) and the top
        // exactly the axis' maximum.
        if target <= 0 { return bottom }
        if target >= 1 { return top }
        // `fraction` is monotonic, so bisect rather than invert by hand.
        var lo = bottom, hi = top
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if fraction(mid) < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}

/// Vertical fader inspired by Focusrite Control 2's mixer strips, covering
/// its `axis`.  Drag anywhere along the column (or on the knob) to set the
/// value.  SwiftUI throttles drag events, so the gesture path doesn't flood
/// the USB queue.
struct VerticalFader: View {
    @Binding var db: Double
    var axis: DbAxis = .gain
    @Environment(\.faderHeight) private var height

    static let knobHeight: CGFloat = 14
    private let trackWidth: CGFloat = 4
    private let knobWidth: CGFloat = 30
    private var knobHeight: CGFloat { Self.knobHeight }

    var body: some View {
        // Height comes from `\.faderHeight`, so no GeometryReader (which
        // would force a layout pass on every frame).  Drag-gesture
        // `.location.y` is already in this view's local coordinate space.
        let topY = axis.y(axis.top, height: height)
        let bottomY = axis.y(axis.bottom, height: height)
        let knobY = axis.y(db, height: height)

        return ZStack(alignment: .top) {
            // Unity (0 dB) mark: a short line either side of the track,
            // leaving a gap so it doesn't cross the track itself.
            HStack(spacing: trackWidth + 6) {
                Rectangle().frame(height: 1)
                Rectangle().frame(height: 1)
            }
            .foregroundStyle(Theme.textSecondary.opacity(0.6))
            .frame(width: knobWidth, height: 1)
            .offset(y: axis.y(0, height: height) - 0.5)

            // Track: exactly the axis' extent, like the meter beside it.
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.faderTrack)
                .frame(width: trackWidth, height: bottomY - topY)
                .offset(y: topY)

            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.faderTrackFill)
                .frame(width: trackWidth, height: max(0, bottomY - knobY))
                .offset(y: knobY)

            RoundedRectangle(cornerRadius: 2.5)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.85), Theme.faderKnob, Color(white: 0.55)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    Rectangle()
                        .fill(Color.black.opacity(0.35))
                        .frame(height: 1)
                )
                .frame(width: knobWidth, height: knobHeight)
                .shadow(color: Theme.faderKnobShadow, radius: 1.5, y: 1)
                .offset(y: knobY - knobHeight / 2)
        }
        .frame(width: knobWidth + 6, height: height, alignment: .top)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    db = axis.db(atY: drag.location.y, height: height)
                }
        )
    }
}

/// dB-scale tick column rendered beside a meter, on its `axis`: a mark at
/// each breakpoint, labelled without signs (Focusrite style: 6 above unity
/// on the gain axis, then 0, 6, 12 … below), right-aligned, and a short
/// tick between marks.
struct DbScale: View {
    var axis: DbAxis = .gain
    @Environment(\.faderHeight) private var height

    private let tickColor = Theme.textSecondary.opacity(0.65)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(axis.minorTicks, id: \.self) { db in
                Rectangle()
                    .fill(tickColor)
                    .frame(width: 2, height: 1)
                    .offset(y: axis.y(db, height: height))
            }
            ForEach(axis.majorTicks, id: \.self) { db in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(tickColor)
                        .frame(width: 4, height: 1)
                    Spacer(minLength: 2)
                    Text("\(Int(abs(db)))")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize()
                }
                // Centre the row on the tick's line; numbers right-aligned.
                .frame(width: 24, height: 10)
                .offset(y: axis.y(db, height: height) - 5)
            }
        }
        .frame(width: 28, height: height, alignment: .topLeading)
    }
}

/// Vertical peak meter rendered alongside a fader, on the same `axis`.
///
/// The bar follows the live `db` value, coloured by level rather than
/// stretched to the bar's height: green up to -24 dB, blending to solid
/// yellow by -18, then to solid red by -6.
/// Two horizontal ticks hover above it:
///  * `peakDb` (white): recent peak-hold value, decays at the rate set in
///    `MixerState.peakDecayDbPerSecond`.
///  * `maxPeakDb` (red): all-time max since the last "Clear peaks" — useful
///    for gain staging over a long take.
struct VerticalMeter: View {
    var db: Double
    var peakDb: Double = -.infinity
    var maxPeakDb: Double = -.infinity
    var axis: DbAxis = .gain
    @Environment(\.faderHeight) private var height
    /// Signal level can't exceed 0 dBFS; the gain axis' +6 dB above it is
    /// fader headroom only.
    private let dbMax: Double = 0
    private let dbFloor = DbAxis.meterFloor
    private let width: CGFloat = 6

    var body: some View {
        // Height comes from `\.faderHeight` — no GeometryReader needed.
        // The track spans the full axis, like the fader track beside it.
        let topY = axis.y(axis.top, height: height)
        let bottomY = axis.y(axis.bottom, height: height)
        let trackHeight = bottomY - topY
        let levelY = axis.y(min(db, dbMax), height: height)
        let fill = db > dbFloor ? bottomY - levelY : 0
        // Gradient stops pinned to levels on the axis, not to the bar.
        let stop = { (db: Double) in (axis.y(db, height: height) - topY) / trackHeight }

        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Theme.faderTrack)
                .frame(width: width, height: trackHeight)
                .offset(y: topY)

            Rectangle()
                .fill(LinearGradient(
                    stops: [
                        .init(color: Theme.meterHigh, location: 0),
                        .init(color: Theme.meterHigh, location: stop(-6)),
                        .init(color: Theme.meterMid,  location: stop(-12)),
                        .init(color: Theme.meterMid,  location: stop(-18)),
                        .init(color: Theme.meterLow,  location: stop(-24)),
                        .init(color: Theme.meterLow,  location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: width, height: trackHeight)
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: max(0, fill))
                }
                .offset(y: topY)

            if peakDb.isFinite && peakDb > dbFloor {
                Rectangle()
                    .fill(Theme.textPrimary)
                    .frame(width: width + 2, height: 1.5)
                    .offset(y: axis.y(min(peakDb, dbMax), height: height) - 0.75)
            }

            if maxPeakDb.isFinite && maxPeakDb > dbFloor {
                Rectangle()
                    .fill(Theme.meterHigh)
                    .frame(width: width + 4, height: 1.5)
                    .offset(y: axis.y(min(maxPeakDb, dbMax), height: height) - 0.75)
            }
        }
        .frame(width: width + 4, height: height, alignment: .top)
    }
}
