import SwiftUI

/// What the progress window shows. ShelfContextMenu fills it in as a job runs.
@Observable
final class VideoProgressModel {
    /// "Converting" or "Trimming".
    var verb = ""
    var fileName = ""
    /// A picture of the file being worked on, once Quick Look has made one.
    var thumbnail: NSImage?
    /// Which file of the batch this is (0-based), and how many there are.
    var index = 0
    var count = 1
    /// How far through the current file, 0...1.
    var fraction = 0.0
    /// Every file is done: the ring turns into a tick before the window goes.
    var isFinished = false
    var startedAt = Date()
    var onCancel: () -> Void = {}

    /// How far through the whole batch, 0...1.
    var overallFraction: Double {
        isFinished ? 1 : (Double(index) + fraction) / Double(max(count, 1))
    }

    /// "about 12 min left", worked out from how long the batch has taken so far.
    /// Nil until there's enough to go on.
    func remainingText(now: Date = Date()) -> String? {
        let elapsed = now.timeIntervalSince(startedAt)
        guard !isFinished, elapsed >= 4, overallFraction >= 0.01 else { return nil }
        let remaining = elapsed / overallFraction - elapsed
        if remaining < 60 {
            return "less than a minute left"
        }
        let duration = Duration.seconds(remaining.rounded())
        let text = duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
        return "about \(text) left"
    }
}

/// The progress window's contents: the file's picture inside a ring that fills as
/// the file is converted, its name, and (for several files) a bar for the batch.
struct VideoProgressView: View {
    let model: VideoProgressModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 380

    var body: some View {
        HStack(spacing: 14) {
            ring
            VStack(alignment: .leading, spacing: 5) {
                Text(model.isFinished ? "Done" : model.verb)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(model.isFinished ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                Text(model.isFinished && model.count > 1 ? "\(model.count) files on the shelf" : model.fileName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.count > 1 {
                    batchBar
                }
                // Once a second is plenty for "about 12 min left".
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(detail(now: context.date))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: model.onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background(.quaternary, in: Circle())
            .help("Cancel")
            .accessibilityLabel("Cancel")
            .opacity(model.isFinished ? 0 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: Self.width)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: model.fraction)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: model.index)
        .animation(reduceMotion ? nil : .bouncy(duration: 0.45), value: model.isFinished)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int(model.overallFraction * 100)) percent")
    }

    /// The file's picture in a circle, with the current file's progress around it.
    private var ring: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 4)
            Circle()
                .trim(from: 0, to: model.isFinished ? 1 : max(model.fraction, 0.003))
                .stroke(
                    model.isFinished
                        ? AnyShapeStyle(.green)
                        : AnyShapeStyle(AngularGradient(
                            colors: [.accentColor.opacity(0.55), .accentColor],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360 * max(model.fraction, 0.05))
                        )),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Group {
                if let thumbnail = model.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .overlay {
                if model.isFinished {
                    ZStack {
                        Circle().fill(.green)
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .frame(width: 58, height: 58)
        .accessibilityHidden(true)
    }

    /// Progress through the whole batch.
    private var batchBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(
                        colors: model.isFinished ? [.green, .green] : [.accentColor.opacity(0.7), .accentColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(5, geometry.size.width * model.overallFraction))
            }
        }
        .frame(height: 5)
        .padding(.vertical, 2)
    }

    /// "3 of 108 · 42% · about 12 min left"
    private func detail(now: Date) -> String {
        var parts: [String] = []
        if model.count > 1 {
            if !model.isFinished {
                parts.append("\(model.index + 1) of \(model.count)")
            }
        }
        if !model.isFinished {
            parts.append("\(Int(model.fraction * 100))%")
            if let remaining = model.remainingText(now: now) {
                parts.append(remaining)
            }
        }
        return model.isFinished ? "On the shelf, next to the original" : parts.joined(separator: " · ")
    }
}
