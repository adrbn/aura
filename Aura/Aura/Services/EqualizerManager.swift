import AVFoundation
import Accelerate
import MediaToolbox

final class EqualizerManager: @unchecked Sendable {
    static let shared = EqualizerManager()

    private(set) var gains: [Float] = [0, 0, 0, 0, 0]
    var isEnabled: Bool { !gains.allSatisfy { $0 == 0 } }

    private var biquadSetup: vDSP_biquad_Setup?
    private var delayBuffers: [[Float]] = [
        [Float](repeating: 0, count: 12),
        [Float](repeating: 0, count: 12)
    ]
    private var sampleRate: Float = 44100
    private let lock = NSLock()

    init() {
        let preset = AppSettings.shared.eqPreset
        gains = preset == .custom ? AppSettings.shared.eqCustomBands : preset.bands
    }

    func applyPreset(_ preset: EQPreset) {
        applyBands(preset == .custom ? AppSettings.shared.eqCustomBands : preset.bands)
    }

    func applyBands(_ newGains: [Float]) {
        guard newGains.count == 5 else { return }
        lock.lock()
        gains = newGains
        rebuildSetup()
        lock.unlock()
    }

    // MARK: - MTAudioProcessingTap

    /// Puts the EQ's tap on an item — and, for a clip that stops mid-song, a fade over its
    /// last `fadeOut` seconds rather than a cut.
    func attachToPlayerItem(_ item: AVPlayerItem, fadeOut: TimeInterval? = nil) {
        lock.lock()
        delayBuffers = [
            [Float](repeating: 0, count: 12),
            [Float](repeating: 0, count: 12)
        ]
        lock.unlock()

        Task {
            let tracks: [AVAssetTrack]
            do {
                tracks = try await item.asset.loadTracks(withMediaType: .audio)
            } catch {
                AppLogger.shared.log("⚠️ EQ: loadTracks error: \(error.localizedDescription)")
                return
            }
            guard let track = tracks.first else {
                AppLogger.shared.log("⚠️ EQ: no audio track found")
                return
            }

            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                `init`: eqTapInit,
                finalize: eqTapFinalize,
                prepare: eqTapPrepare,
                unprepare: eqTapUnprepare,
                process: eqTapProcess
            )

            var tap: MTAudioProcessingTap?
            let status = MTAudioProcessingTapCreate(
                kCFAllocatorDefault, &callbacks,
                kMTAudioProcessingTapCreationFlag_PreEffects, &tap
            )

            guard status == noErr, let audioTap = tap else {
                AppLogger.shared.log("❌ EQ: tap creation failed (\(status))")
                return
            }

            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = audioTap
            if let fadeOut, let length = try? await item.asset.load(.duration),
               length.isNumeric, length.seconds > fadeOut * 2 {
                let fade = CMTime(seconds: fadeOut, preferredTimescale: 600)
                params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: length - fade, duration: fade))
            }

            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [params]

            await MainActor.run {
                item.audioMix = audioMix
            }
            AppLogger.shared.log("🎛️ EQ tap attached (sr=\(self.sampleRate))")
        }
    }

    // MARK: - DSP

    fileprivate func setSampleRate(_ sr: Float) {
        lock.lock()
        sampleRate = sr
        delayBuffers = [
            [Float](repeating: 0, count: 12),
            [Float](repeating: 0, count: 12)
        ]
        rebuildSetup()
        lock.unlock()
    }

    fileprivate func processAudio(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        lock.lock()
        defer { lock.unlock() }
        guard let setup = biquadSetup else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        if buffers.count >= 2 {
            // Non-interleaved
            for ch in 0..<min(buffers.count, 2) {
                guard let data = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                vDSP_biquad(setup, &delayBuffers[ch], data, 1, data, 1, vDSP_Length(frames))
            }
        } else if buffers.count == 1, let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
            // Interleaved
            let channels = Int(buffers[0].mNumberChannels)
            if channels >= 2 {
                vDSP_biquad(setup, &delayBuffers[0], data, vDSP_Stride(channels), data, vDSP_Stride(channels), vDSP_Length(frames))
                vDSP_biquad(setup, &delayBuffers[1], data.advanced(by: 1), vDSP_Stride(channels), data.advanced(by: 1), vDSP_Stride(channels), vDSP_Length(frames))
            } else {
                vDSP_biquad(setup, &delayBuffers[0], data, 1, data, 1, vDSP_Length(frames))
            }
        }
    }

    // MARK: - Biquad

    private func rebuildSetup() {
        if let old = biquadSetup {
            vDSP_biquad_DestroySetup(old)
            biquadSetup = nil
        }
        guard isEnabled else { return }

        var coefficients = [Double]()
        for (i, freq) in EQPreset.bandFrequencies.enumerated() {
            coefficients.append(contentsOf: peakingEQ(freq: freq, gain: gains[i], Q: 1.0, sr: sampleRate))
        }
        biquadSetup = vDSP_biquad_CreateSetup(&coefficients, UInt(5))
    }

    private func peakingEQ(freq: Float, gain: Float, Q: Float, sr: Float) -> [Double] {
        guard gain != 0 else { return [1, 0, 0, 0, 0] }
        let A = pow(10.0, Double(gain) / 40.0)
        let w0 = 2.0 * Double.pi * Double(freq) / Double(sr)
        let alpha = sin(w0) / (2.0 * Double(Q))
        let cosW0 = cos(w0)
        let a0 = 1.0 + alpha / A
        return [
            (1.0 + alpha * A) / a0,
            (-2.0 * cosW0)    / a0,
            (1.0 - alpha * A) / a0,
            (-2.0 * cosW0)    / a0,
            (1.0 - alpha / A) / a0
        ]
    }
}

// MARK: - Tap Callbacks

private func eqTapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private func eqTapFinalize(tap: MTAudioProcessingTap) {}

private func eqTapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    let manager = Unmanaged<EqualizerManager>.fromOpaque(
        MTAudioProcessingTapGetStorage(tap)
    ).takeUnretainedValue()
    manager.setSampleRate(Float(processingFormat.pointee.mSampleRate))
}

private func eqTapUnprepare(tap: MTAudioProcessingTap) {}

private func eqTapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
    )
    guard status == noErr else { return }
    let manager = Unmanaged<EqualizerManager>.fromOpaque(
        MTAudioProcessingTapGetStorage(tap)
    ).takeUnretainedValue()
    manager.processAudio(bufferListInOut, frames: numberFrames)
}
