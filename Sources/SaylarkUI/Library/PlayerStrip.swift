import SaylarkCore
import SwiftUI

/// Play/pause, a slim waveform you can drag along, and the time. The words above highlight as it plays.
struct PlayerStrip: View {
    let player: PlaybackModel
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!player.hasAudio)
            .help(player.hasAudio ? (player.isPlaying ? "Pause" : "Play") : "No audio kept for this take")

            WaveformView(levels: player.levels, progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                         accent: accent) { fraction in
                player.seek(to: fraction * player.duration)
            }
            .frame(height: 22)

            Text("\(TakeRow.duration(player.currentTime)) / \(TakeRow.duration(player.duration))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.trailing, 4)
    }
}

/// Mirrored bars, played part in the accent. Click or drag anywhere to scrub.
struct WaveformView: View {
    let levels: [Float]
    let progress: Double
    let accent: Color
    let onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard !levels.isEmpty else { return }
                let step = size.width / CGFloat(levels.count)
                let bar = max(1, step * 0.55)
                let played = progress * Double(levels.count)
                for (i, v) in levels.enumerated() {
                    let h = max(1.5, CGFloat(v) * size.height)
                    let r = CGRect(x: CGFloat(i) * step + (step - bar) / 2, y: (size.height - h) / 2, width: bar, height: h)
                    let colour = Double(i) < played ? accent : Color.primary.opacity(0.22)
                    ctx.fill(Path(roundedRect: r, cornerRadius: bar / 2), with: .color(colour))
                }
                // Playhead
                let x = CGFloat(progress) * size.width
                ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(Color.primary.opacity(0.55)))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onScrub(max(0, min(1, g.location.x / max(1, geo.size.width))))
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue("\(Int(progress * 100)) percent played")
    }
}
