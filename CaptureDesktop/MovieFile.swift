import AVFoundation
import CoreMedia

func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

func log(_ message: String) {
    FileHandle.standardError.write(Data("[CaptureDesktop] \(message)\n".utf8))
}

struct RecorderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A video track that always writes a constant frame rate.
///
/// Sources deliver frames irregularly (ScreenCaptureKit only sends a frame when
/// the screen changes; cameras slow down in low light). Each output slot gets
/// the newest source frame whose timestamp is at or before the slot time, and
/// the previous frame is repeated when nothing new arrived.
final class PacedVideoTrack {
    let input: AVAssetWriterInput
    let fps: Int32
    /// How far behind real time slots are emitted, so frames still in flight
    /// land in the slot they belong to.
    let latency: Double

    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var pending: [(t: Double, buffer: CVPixelBuffer)] = []
    private var current: CVPixelBuffer?
    private(set) var nextIndex: Int64 = 0
    private(set) var sourceFrames = 0
    private(set) var repeatedFrames = 0
    private(set) var stalledTicks = 0
    private(set) var droppedSourceFrames = 0
    private let capacity: Int

    init(width: Int, height: Int, fps: Int32, bitsPerPixel: Double, latency: Double, seed: CVPixelBuffer) {
        let bitrate = min(60_000_000, max(2_000_000, Int(Double(width * height) * Double(fps) * bitsPerPixel)))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.mediaTimeScale = fps.multipliedReportingOverflow(by: 100).overflow ? fps : fps * 100
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        self.fps = fps
        self.latency = latency
        // Room for the frames normally in flight during the pacing delay, plus a few spare.
        capacity = max(6, Int((Double(fps) * latency).rounded(.up)) + 3)
        current = seed
    }

    func push(_ buffer: CVPixelBuffer, t: Double) {
        sourceFrames += 1
        // Never hold many source buffers: the capture pools are small. When the
        // encoder is stalled, the newest frame is the one to drop, so the frames
        // already queued still land in the slots their timestamps belong to.
        guard pending.count < capacity else {
            droppedSourceFrames += 1
            return
        }
        pending.append((t, buffer))
    }

    /// Write every slot up to `t`, waiting briefly for the encoder if it is busy.
    /// Used at stop, when there is no later tick to catch up on.
    /// Returns false when the stop time could not be reached.
    @discardableResult
    func drain(upTo t: Double, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Double(nextIndex) / Double(fps) <= t {
            guard current != nil || !pending.isEmpty else { return false }
            let before = nextIndex
            emit(upTo: t)
            if nextIndex == before {
                // Ready but no progress means the append failed (writer error): give up.
                guard !input.isReadyForMoreMediaData, Date() < deadline else { return false }
                usleep(2000)
            }
        }
        return true
    }

    /// Write every slot whose time is <= `t` (seconds since T0).
    func emit(upTo t: Double) {
        while Double(nextIndex) / Double(fps) <= t {
            guard input.isReadyForMoreMediaData else {
                stalledTicks += 1
                return // catch up on a later tick; slots are never skipped
            }
            let slot = Double(nextIndex) / Double(fps)
            var fresh = false
            while let first = pending.first, first.t <= slot {
                current = first.buffer
                pending.removeFirst()
                fresh = true
            }
            guard let buffer = current else { return }
            if !fresh && nextIndex > 0 { repeatedFrames += 1 }
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: nextIndex, timescale: fps)) {
                return
            }
            nextIndex += 1
        }
    }

    var duration: CMTime { CMTime(value: nextIndex, timescale: fps) }
}

/// An audio track written as one gapless run of samples starting at T0.
///
/// Buffers are re-stamped onto a running sample count, and any hole (late
/// start, a source that goes quiet, dropped buffers) is filled with silence so
/// the track never relies on edit lists to stay in sync.
final class AudioTrack {
    let name: String
    let input: AVAssetWriterInput
    private var format: CMAudioFormatDescription?
    private var rate: Double = 0
    private(set) var writtenFrames: Int64 = 0
    private(set) var silenceFrames: Int64 = 0
    private(set) var sourceBuffers = 0
    /// Source buffers that actually reached the file.
    private(set) var writtenBuffers = 0
    private(set) var droppedBuffers = 0
    /// Buffers shortened or skipped because they overlapped sound already written.
    private(set) var trimmedBuffers = 0
    private(set) var maxDriftMs: Double = 0
    /// True when the track could not be padded to the full recording length.
    private(set) var endsShort = false

    init(name: String, channels: Int) {
        self.name = name
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        if channels > 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let title = AVMutableMetadataItem()
        title.identifier = .quickTimeUserDataTrackName
        title.value = name as NSString
        title.extendedLanguageTag = "und"
        input.metadata = [title]
    }

    /// `t` is the buffer's start time in seconds since T0. `limit` is the stop
    /// boundary in seconds since T0, once stopping has begun.
    func append(_ sampleBuffer: CMSampleBuffer, t: Double, limit: Double? = nil) {
        guard let desc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0 else { return }
        if format == nil {
            format = desc
            rate = asbd.mSampleRate
        }
        let startFrame = Int64((t * rate).rounded())
        // Entirely before T0: not part of the recording. A buffer that straddles
        // T0 is kept and has its early part cut off below.
        if writtenFrames == 0 && startFrame + Int64(count) <= 0 { return }
        sourceBuffers += 1

        let gap = startFrame - writtenFrames
        maxDriftMs = max(maxDriftMs, abs(Double(gap)) / rate * 1000)
        // Always align the very first buffer; afterwards only repair real holes.
        if gap > 0 && (writtenFrames == 0 || Double(gap) > rate * 0.02) {
            // If the hole cannot be filled, appending now would shift this audio
            // earlier. Drop it instead: the next buffer retries the fill.
            guard writeSilence(frames: gap) else {
                droppedBuffers += 1
                return
            }
        }

        // Work out which part of the buffer to keep.
        var location = 0
        var frames = count
        // It may start before the point already written (clock drift, a timestamp
        // jump, or the first buffer straddling T0). Appending it whole would repeat
        // sound and push the track late, so the overlapping start is cut off.
        if gap < 0, writtenFrames == 0 || Double(-gap) > rate * 0.02 {
            location = Int(min(-gap, Int64(count)))
            frames = count - location
        }
        // And it may run past the stop boundary: nothing captured after Stop is kept.
        // Measured on the buffer's own timestamps (when the sound was captured),
        // and also on the output position, so neither can pass the boundary.
        if let limit {
            let limitFrame = Int64((limit * rate).rounded(.down))
            let capturedRoom = limitFrame - (startFrame + Int64(location))
            let outputRoom = limitFrame - writtenFrames
            frames = Int(max(0, min(Int64(frames), capturedRoom, outputRoom)))
        }
        guard frames > 0 else {
            trimmedBuffers += 1
            return
        }
        var source = sampleBuffer
        if location > 0 || frames < count {
            var part: CMSampleBuffer?
            CMSampleBufferCopySampleBufferForRange(
                allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                sampleRange: CFRange(location: location, length: frames), sampleBufferOut: &part)
            guard let part else {
                droppedBuffers += 1
                return
            }
            source = part
            trimmedBuffers += 1
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
            presentationTimeStamp: CMTime(value: writtenFrames, timescale: CMTimeScale(rate)),
            decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: source,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed)
        guard let retimed, input.isReadyForMoreMediaData, input.append(retimed) else {
            droppedBuffers += 1 // the hole is filled with silence by the next buffer
            return
        }
        writtenBuffers += 1
        writtenFrames += Int64(frames)
    }

    /// Extend the track with silence so it is at least `seconds` long.
    func pad(until seconds: Double) {
        if format == nil {
            // The source never delivered anything: synthesize a format.
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            var desc: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
            format = desc
            rate = 48_000
        }
        let target = Int64((seconds * rate).rounded())
        if target > writtenFrames, !writeSilence(frames: target - writtenFrames) { endsShort = true }
    }

    /// Returns false when the silence could not be written in full.
    @discardableResult
    private func writeSilence(frames total: Int64) -> Bool {
        guard let format, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return false }
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerFrame = Int(asbd.mBytesPerFrame) * (planar ? Int(asbd.mChannelsPerFrame) : 1)
        var remaining = total
        while remaining > 0 {
            let frames = Int(min(remaining, Int64(rate)))
            let bytes = frames * bytesPerFrame
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            guard let block else { return false }
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
            var silence: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: frames,
                presentationTimeStamp: CMTime(value: writtenFrames, timescale: CMTimeScale(rate)),
                packetDescriptions: nil, sampleBufferOut: &silence)
            guard let silence else { return false }
            // Brief wait if the writer is momentarily busy; silence must not be skipped.
            var tries = 0
            while !input.isReadyForMoreMediaData && tries < 200 { usleep(1000); tries += 1 }
            guard input.isReadyForMoreMediaData, input.append(silence) else { return false }
            writtenFrames += Int64(frames)
            silenceFrames += Int64(frames)
            remaining -= Int64(frames)
        }
        return true
    }

    var seconds: Double { rate > 0 ? Double(writtenFrames) / rate : 0 }
    var sampleRate: Double { rate }
}

/// One QuickTime file: an optional paced video track, any number of audio
/// tracks and a timecode track, all on a timeline that starts at T0 = 0.
final class MovieFile {
    let url: URL
    let fps: Int32
    private let writer: AVAssetWriter
    private(set) var video: PacedVideoTrack?
    private(set) var audio: [AudioTrack] = []
    private var timecodeInput: AVAssetWriterInput?
    private var timecodeFormat: CMTimeCodeFormatDescription?

    init(url: URL, fps: Int32) throws {
        self.url = url
        self.fps = fps
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    }

    func addVideo(seed: CVPixelBuffer, bitsPerPixel: Double, latency: Double) throws -> PacedVideoTrack {
        let track = PacedVideoTrack(
            width: CVPixelBufferGetWidth(seed), height: CVPixelBufferGetHeight(seed),
            fps: fps, bitsPerPixel: bitsPerPixel, latency: latency, seed: seed)
        guard writer.canAdd(track.input) else { throw RecorderError("Cannot add video track to \(url.lastPathComponent)") }
        writer.add(track.input)
        video = track

        var desc: CMTimeCodeFormatDescription?
        CMTimeCodeFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: CMTime(value: 1, timescale: fps), frameQuanta: UInt32(fps),
            flags: kCMTimeCodeFlag_24HourMax, extensions: nil, formatDescriptionOut: &desc)
        if let desc {
            let tc = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: desc)
            tc.expectsMediaDataInRealTime = true
            if writer.canAdd(tc) {
                writer.add(tc)
                track.input.addTrackAssociation(withTrackOf: tc, type: AVAssetTrack.AssociationType.timecode.rawValue)
                timecodeInput = tc
                timecodeFormat = desc
            }
        }
        return track
    }

    func addAudio(name: String, channels: Int) throws -> AudioTrack {
        let track = AudioTrack(name: name, channels: channels)
        guard writer.canAdd(track.input) else { throw RecorderError("Cannot add \(name) track to \(url.lastPathComponent)") }
        writer.add(track.input)
        audio.append(track)
        return track
    }

    func begin() throws {
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError("Could not start writing \(url.lastPathComponent)")
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Close every track at `duration`. Call on the writer queue, then await `finish()`.
    func seal(duration: CMTime, startFrameNumber: UInt32) {
        for track in audio {
            track.pad(until: duration.seconds)
            track.input.markAsFinished()
        }
        if let tc = timecodeInput, let format = timecodeFormat,
           let sample = Self.timecodeSample(frame: startFrameNumber, duration: duration, format: format) {
            var tries = 0
            while !tc.isReadyForMoreMediaData && tries < 200 { usleep(1000); tries += 1 }
            if !tc.append(sample) { log("timecode sample was not written for \(url.lastPathComponent)") }
            tc.markAsFinished()
        }
        video?.input.markAsFinished()
        writer.endSession(atSourceTime: duration)
    }

    func finish() async throws {
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? RecorderError("Writing \(url.lastPathComponent) failed")
        }
    }

    var failure: Error? { writer.status == .failed ? writer.error : nil }

    private static func timecodeSample(frame: UInt32, duration: CMTime, format: CMTimeCodeFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { return nil }
        var bigEndian = frame.bigEndian
        CMBlockBufferReplaceDataBytes(with: &bigEndian, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return sample
    }
}
