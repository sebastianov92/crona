import SwiftUI
import AVFoundation

/// Grabadora de notas de voz: graba en AAC (.m4a), con preescucha antes de adjuntar.
struct VoiceRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onDone: (Attachment) -> Void

    enum Phase { case idle, denied, recording, recorded }

    @State private var phase: Phase = .idle
    @State private var recorder: AVAudioRecorder?
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var seconds = 0
    @State private var timer: Timer?
    @State private var fileURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(phase == .recording ? Color.red.opacity(0.15) : Theme.accent.opacity(0.15))
                        .frame(width: 140, height: 140)
                    Image(systemName: phase == .recording ? "waveform" : "mic.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(phase == .recording ? .red : Theme.accent)
                        .symbolEffect(.variableColor.iterative, isActive: phase == .recording)
                }

                Text(timeLabel)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .foregroundStyle(phase == .recording ? .red : .primary)

                switch phase {
                case .idle:
                    Text("Toca para empezar a grabar.")
                        .foregroundStyle(.secondary)
                    bigButton("Grabar", color: Theme.accent) { Task { await start() } }
                case .denied:
                    Text("Crona no tiene permiso para usar el micrófono. Actívalo en Ajustes del sistema → Privacidad → Micrófono.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 320)
                case .recording:
                    Text("Grabando…")
                        .foregroundStyle(.secondary)
                    bigButton("Detener", color: .red) { stop() }
                case .recorded:
                    HStack(spacing: 14) {
                        Button {
                            playing ? stopPlayback() : play()
                        } label: {
                            Label(playing ? "Pausar" : "Escuchar", systemImage: playing ? "pause.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            discard()
                            Task { await start() }
                        } label: {
                            Label("Repetir", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: 340)
                    bigButton("Usar esta nota", color: Theme.accent) { finish() }
                }

                Spacer()
            }
            .padding(24)
            .navigationTitle("Nota de voz")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        discard()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            recorder?.stop()
            player?.stop()
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    private var timeLabel: String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func bigButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: 340)
                .frame(height: 50)
                .background(color, in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grabación

    private func start() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            phase = .denied
            return
        }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)
        #endif

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nota-de-voz-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.record()
            recorder = rec
            fileURL = url
            seconds = 0
            phase = .recording
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in seconds += 1 }
        } catch {
            phase = .idle
        }
    }

    private func stop() {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        phase = .recorded
    }

    private func play() {
        guard let fileURL else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        #endif
        player = try? AVAudioPlayer(contentsOf: fileURL)
        player?.play()
        playing = true
        // volver al estado normal cuando acabe (sin delegate: chequear con timer ligero)
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { t in
            if !(player?.isPlaying ?? false) {
                playing = false
                t.invalidate()
            }
        }
    }

    private func stopPlayback() {
        player?.stop()
        playing = false
    }

    private func discard() {
        stopPlayback()
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        seconds = 0
        phase = .idle
    }

    private func finish() {
        stopPlayback()
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            discard()
            return
        }
        try? FileManager.default.removeItem(at: fileURL)
        onDone(Attachment(data: data, fileName: "nota-de-voz.m4a", mimeType: "audio/mp4"))
        dismiss()
    }
}
