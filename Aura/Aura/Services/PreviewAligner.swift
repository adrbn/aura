import AVFoundation
import Accelerate

/// Where a preview sits inside its song.
///
/// Deezer's thirty seconds are cut from somewhere in the middle, and nothing says where. So
/// the two recordings are lined up: a stretch of the preview slid along the song until the
/// two agree — coarsely first, on rough copies of both, then to a quarter of a millisecond
/// around the best match. That is close enough for the two to play over each other with
/// nothing heard, which is what a preview handing over to its song needs.
enum PreviewAligner {
    /// The rate the fine match runs at, and how much rougher the first pass is.
    private static let fineRate: Double = 4000
    private static let coarseFactor = 8
    /// The stretch of the preview compared: clear of its opening, and long enough that a
    /// chorus the song repeats still has one best place.
    private static let probeStart: TimeInterval = 2
    private static let probeLength: TimeInterval = 16
    /// How alike the best place must be, from 0 to 1. The same recording scores close to 1;
    /// another take or another master falls well short, and then nothing is handed over.
    private static let minimumLikeness: Float = 0.6

    /// Seconds into `song` at which the preview at `previewURL` begins, or nil when the two
    /// don't line up — a different recording, or audio that couldn't be read.
    static func offset(ofPreviewAt previewURL: URL, inSongAt songURL: URL) async -> TimeInterval? {
        guard let preview = await download(previewURL) else { return nil }
        defer { try? FileManager.default.removeItem(at: preview) }
        return await Task.detached(priority: .userInitiated) {
            offset(of: preview, in: songURL)
        }.value
    }

    private static func download(_ url: URL) async -> URL? {
        guard let (temporary, response) = try? await URLSession.shared.download(from: url),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return nil }
        // Decoders go by the extension.
        let named = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-\(UUID().uuidString).mp3")
        guard (try? FileManager.default.moveItem(at: temporary, to: named)) != nil else { return nil }
        return named
    }

    private static func offset(of preview: URL, in song: URL) -> TimeInterval? {
        guard let clip = samples(of: preview), let whole = samples(of: song) else { return nil }
        let start = Int(probeStart * fineRate)
        let length = min(Int(probeLength * fineRate), clip.count - start)
        guard length > Int(4 * fineRate), whole.count > length else { return nil }
        let probe = Array(clip[start..<start + length])

        guard let coarse = bestMatch(of: decimated(probe), in: decimated(whole)) else { return nil }
        let centre = coarse.lag * coarseFactor
        let lags = max(0, centre - 2 * coarseFactor)...min(whole.count - length, centre + 2 * coarseFactor)
        guard let fine = bestMatch(of: probe, in: whole, lags: lags) else { return nil }
        AppLogger.shared.log("🎯 Preview aligned at \(Double(fine.lag) / fineRate - probeStart)s, likeness \(fine.likeness)")
        guard fine.likeness >= minimumLikeness else { return nil }
        return Double(fine.lag) / fineRate - probeStart
    }

    /// The lag at which `probe` best matches `signal`, by normalised cross-correlation, with
    /// how alike the two are there.
    private static func bestMatch(of probe: [Float], in signal: [Float],
                                  lags: ClosedRange<Int>? = nil) -> (lag: Int, likeness: Float)? {
        let width = probe.count
        let range = lags ?? 0...(signal.count - width)
        guard width > 0, range.lowerBound >= 0, range.upperBound + width <= signal.count else { return nil }
        let count = range.count

        var dots = [Float](repeating: 0, count: count)
        signal.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            vDSP_conv(base + range.lowerBound, 1, probe, 1, &dots, 1, vDSP_Length(count), vDSP_Length(width))
        }

        var probeEnergy: Float = 0
        vDSP_svesq(probe, 1, &probeEnergy, vDSP_Length(width))
        guard probeEnergy > 0 else { return nil }

        // Each window's energy, from running sums — in Double, over a million samples.
        var running = 0.0
        var prefix = [Double](repeating: 0, count: range.upperBound + width + 1)
        for index in range.lowerBound..<(range.upperBound + width) {
            running += Double(signal[index] * signal[index])
            prefix[index + 1] = running
        }

        var best: (lag: Int, likeness: Float)?
        for offset in 0..<count {
            let lag = range.lowerBound + offset
            let energy = prefix[lag + width] - prefix[lag]
            guard energy > 0 else { continue }
            let likeness = Float(Double(dots[offset]) / (Double(probeEnergy) * energy).squareRoot())
            if likeness > (best?.likeness ?? -1) { best = (lag, likeness) }
        }
        return best
    }

    /// Every `coarseFactor` samples averaged into one.
    private static func decimated(_ samples: [Float]) -> [Float] {
        let count = (samples.count - coarseFactor) / coarseFactor + 1
        guard count > 0 else { return [] }
        let filter = [Float](repeating: 1 / Float(coarseFactor), count: coarseFactor)
        var out = [Float](repeating: 0, count: count)
        vDSP_desamp(samples, vDSP_Stride(coarseFactor), filter, &out, vDSP_Length(count), vDSP_Length(coarseFactor))
        return out
    }

    /// The file's audio, mixed to mono at `fineRate`.
    private static func samples(of url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fineRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768)
        else { return nil }
        converter.downmix = true

        var out = [Float]()
        out.reserveCapacity(Int(Double(file.length) * fineRate / file.processingFormat.sampleRate) + 1024)
        var drained = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else { return nil }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if !drained {
                    // Emptied first: a failed read must not hand the last buffer over again.
                    input.frameLength = 0
                    if file.framePosition < file.length {
                        try? file.read(into: input, frameCount: input.frameCapacity)
                    }
                    drained = input.frameLength == 0
                }
                guard !drained else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let channel = output.floatChannelData, output.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return out.isEmpty ? nil : out
    }
}
