import AVFoundation
import Accelerate
import MediaToolbox

final class EqualizerManager: @unchecked Sendable {
    static let shared = EqualizerManager()

    private(set) var gains: [Float] = [0, 0, 0, 0, 0]
    var isEnabled: Bool { !gains.allSatisfy { $0 == 0 } }

    /// Bumped with every change of gains, so each tap rebuilds its filters on its next buffer.
    private var revision = 0
    private let lock = NSLock()

    init() {
        let preset = AppSettings.shared.eqPreset
        gains = preset == .custom ? AppSettings.shared.eqCustomBands : preset.bands
    }

    func applyPreset(_ preset: EQPreset) {
        applyBands(preset == .custom ? AppSettings.shared.eqCustomBands : preset.bands)
    }

    /// The pitch shift every tap applies, in cents, the speed untouched.
    private(set) var pitchCents: Float = 0

    func setPitch(semitones: Int) {
        lock.lock()
        pitchCents = Float(semitones * 100)
        lock.unlock()
    }

    func applyBands(_ newGains: [Float]) {
        guard newGains.count == 5 else { return }
        lock.lock()
        gains = newGains
        revision += 1
        lock.unlock()
    }

    // MARK: - MTAudioProcessingTap

    /// Puts the EQ's tap on an item — and, for a clip that stops mid-song, a fade over its
    /// last `fadeOut` seconds rather than a cut.
    func attachToPlayerItem(_ item: AVPlayerItem, fadeOut: TimeInterval? = nil) {
        Task { await attach(to: item, fadeOut: fadeOut) }
    }

    /// The same, finished when the tap is in place — for an item that must sound right from
    /// its first sample, like a song taking over from its preview mid-phrase.
    func attach(to item: AVPlayerItem, fadeOut: TimeInterval? = nil) async {
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

        // Each tap carries its own filter memory: two can run at once — a preview and its
        // song, crossing over — and one shared set of delay lines garbles both.
        let context = Unmanaged.passRetained(EQTapContext(manager: self)).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: context,
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
            Unmanaged<EQTapContext>.fromOpaque(context).release()
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
        AppLogger.shared.log("🎛️ EQ tap attached")
    }

    /// The gains and their revision, read together.
    fileprivate func snapshot() -> (gains: [Float], revision: Int, pitch: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (gains, revision, pitchCents)
    }

    // MARK: - Biquad

    fileprivate static func makeSetup(gains: [Float], sampleRate: Float) -> vDSP_biquad_Setup? {
        guard !gains.allSatisfy({ $0 == 0 }) else { return nil }
        var coefficients = [Double]()
        for (i, freq) in EQPreset.bandFrequencies.enumerated() {
            coefficients.append(contentsOf: peakingEQ(freq: freq, gain: gains[i], Q: 1.0, sr: sampleRate))
        }
        return vDSP_biquad_CreateSetup(&coefficients, UInt(5))
    }

    private static func peakingEQ(freq: Float, gain: Float, Q: Float, sr: Float) -> [Double] {
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

// MARK: - One tap's state

/// A tap's filters and their memory, rebuilt when the gains or the sample rate change.
/// Only the audio thread of its own tap touches it, apart from creation and release.
private final class EQTapContext {
    let manager: EqualizerManager
    private var setup: vDSP_biquad_Setup?
    private var builtRevision = -1
    private var sampleRate: Float = 44100
    private var delayBuffers: [[Float]] = EQTapContext.freshDelays()
    /// Apple's time-pitch unit, fed from the tap's source, for a pitch that leaves the speed alone.
    private var pitchUnit: AudioUnit?
    private var pitchActive = false
    private var renderTime = AudioTimeStamp()
    fileprivate var tap: MTAudioProcessingTap?

    init(manager: EqualizerManager) { self.manager = manager }

    deinit {
        if let setup { vDSP_biquad_DestroySetup(setup) }
        if let pitchUnit { AudioUnitUninitialize(pitchUnit); AudioComponentInstanceDispose(pitchUnit) }
    }

    /// Builds the time-pitch unit for the tap's format; without it the pitch stays at zero.
    func preparePitch(format: AudioStreamBasicDescription, maxFrames: CMItemCount) {
        if let pitchUnit { AudioUnitUninitialize(pitchUnit); AudioComponentInstanceDispose(pitchUnit) }
        pitchUnit = nil
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter, componentSubType: kAudioUnitSubType_NewTimePitch,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return }
        var asbd = format
        var frames = UInt32(maxFrames)
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var callback = AURenderCallbackStruct(inputProc: pitchSource,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, size) == noErr,
              AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, size) == noErr,
              AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                   &frames, UInt32(MemoryLayout<UInt32>.size)) == noErr,
              AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                   &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(unit) == noErr
        else {
            AudioComponentInstanceDispose(unit)
            AppLogger.shared.log("⚠️ Pitch: time-pitch unit unavailable")
            return
        }
        renderTime = AudioTimeStamp()
        renderTime.mFlags = .sampleTimeValid
        pitchUnit = unit
    }

    /// Fills `bufferList` with the source audio, through the time-pitch unit when the pitch is
    /// off zero. Returns false when the source couldn't be read.
    func render(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount,
                flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>,
                framesOut: UnsafeMutablePointer<CMItemCount>) -> Bool {
        guard let tap else { return false }
        let cents = manager.snapshot().pitch
        guard cents != 0, let pitchUnit else {
            if pitchActive, let pitchUnit { AudioUnitReset(pitchUnit, kAudioUnitScope_Global, 0) }
            pitchActive = false
            return MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr
        }
        pitchActive = true
        AudioUnitSetParameter(pitchUnit, kNewTimePitchParam_Pitch, kAudioUnitScope_Global, 0, cents, 0)
        var actionFlags = AudioUnitRenderActionFlags()
        let status = AudioUnitRender(pitchUnit, &actionFlags, &renderTime, 0, UInt32(frames), bufferList)
        renderTime.mSampleTime += Double(frames)
        framesOut.pointee = frames
        return status == noErr
    }

    /// The time-pitch unit asks for source audio: read it from the tap.
    fileprivate func pullSource(_ ioData: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) -> OSStatus {
        guard let tap else { return -1 }
        var flags = MTAudioProcessingTapFlags()
        var got: CMItemCount = 0
        return MTAudioProcessingTapGetSourceAudio(tap, CMItemCount(frames), ioData, &flags, nil, &got)
    }

    private static func freshDelays() -> [[Float]] {
        [[Float](repeating: 0, count: 12), [Float](repeating: 0, count: 12)]
    }

    func prepare(sampleRate newRate: Float) {
        sampleRate = newRate
        delayBuffers = Self.freshDelays()
        builtRevision = -1
    }

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        let current = manager.snapshot()
        if current.revision != builtRevision {
            if let old = setup { vDSP_biquad_DestroySetup(old) }
            setup = EqualizerManager.makeSetup(gains: current.gains, sampleRate: sampleRate)
            builtRevision = current.revision
        }
        guard let setup else { return }

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
}

// MARK: - Tap Callbacks

private func eqTapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

/// The tap is gone: its context, retained when the tap was made, goes with it.
private func eqTapFinalize(tap: MTAudioProcessingTap) {
    Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private func eqTapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    let context = Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.tap = tap
    context.prepare(sampleRate: Float(processingFormat.pointee.mSampleRate))
    context.preparePitch(format: processingFormat.pointee, maxFrames: maxFrames)
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
    let context = Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    guard context.render(bufferListInOut, frames: numberFrames, flagsOut: flagsOut, framesOut: numberFramesOut)
    else { return }
    context.process(bufferListInOut, frames: numberFrames)
}

private func pitchSource(
    refCon: UnsafeMutableRawPointer,
    actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timeStamp: UnsafePointer<AudioTimeStamp>,
    bus: UInt32,
    frames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return -1 }
    return Unmanaged<EQTapContext>.fromOpaque(refCon).takeUnretainedValue().pullSource(ioData, frames: frames)
}
