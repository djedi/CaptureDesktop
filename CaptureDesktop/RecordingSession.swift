import AVFoundation
import CoreGraphics
import Foundation

struct RecordingOptions {
    var screen = true
    var camera = true
    /// Unique ID of the camera to record; `nil` uses the system default.
    var cameraID: String?
    var microphone = true
    var systemAudio = true
    var fps: Int32 = 30
    var showsCursor = true
    var target: CaptureTarget = .display(nil)
    /// Record at the display's native (Retina) pixel density instead of 1x.
    var nativeResolution = true
    var outputRoot = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CaptureDesktop", isDirectory: true)

    var needsScreenStream: Bool { screen || systemAudio }
    var needsDeviceSession: Bool { camera || microphone }
    var hasAnySource: Bool { needsScreenStream || needsDeviceSession }
}

/// One recording, from start to finished files.
///
/// Every source delivers on `queue` and every writer is touched only on
/// `queue`, so the pipeline needs no locks. All timestamps are host-clock
/// times measured from a single T0, which becomes time zero in each file.
final class RecordingSession {
    let options: RecordingOptions
    private(set) var directory: URL

    private let queue = DispatchQueue(label: "top.capturedesk.pipeline", qos: .userInitiated)
    private let screenSource = ScreenSource()
    /// Window capture only carries that app's sound, so system audio gets its own stream.
    private let systemAudioSource = ScreenSource()
    private let deviceSource = DeviceSource()
    private let cursorLogger = CursorLogger()
    private var display: CaptureRegion?

    // Touched only on `queue`.
    private var t0: CMTime?
    private var t0Date = Date()
    private var sealed = false
    private var prerollScreen: CVPixelBuffer?
    private var prerollCamera: CVPixelBuffer?
    private var prerollMicChannels: Int?
    private var screenFile: MovieFile?
    private var cameraFile: MovieFile?
    private var screenTrack: PacedVideoTrack?
    private var cameraTrack: PacedVideoTrack?
    private var systemTrack: AudioTrack?
    private var micTrack: AudioTrack?
    private var pacer: DispatchSourceTimer?
    private var sourceError: Error?
    private var endedEarly = false
    /// The stop boundary. Unlike the rest of the pipeline state it is guarded by
    /// its own lock, so `stop()` can publish it at once, without waiting for
    /// work already queued, and that work then sees it.
    private let stopLock = NSLock()
    private var stopBoundary: (started: CMTime, limit: Double)?
    /// Seconds since T0 at which the recording ends; set when stop begins.
    private var stopLimit: Double? { stopLock.withLock { stopBoundary?.limit } }
    /// Host time at which stop began.
    private var stopStarted: CMTime? { stopLock.withLock { stopBoundary?.started } }
    /// T0 as published to `stop()`; set once writing has begun.
    private var startedAt: CMTime?
    private var cursorStartError: Error?
    private var firstFrameLagMs: [String: Double] = [:]

    init(options: RecordingOptions) {
        self.options = options
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        directory = options.outputRoot.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
    }

    func start() async throws {
        guard options.hasAnySource else { throw RecorderError("Turn on at least one source") }
        try await checkPermissions()
        // Claim a folder nobody else has: two sessions can start within the same
        // second, and a failed start deletes its folder.
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let base = directory
        var attempt = 1
        while true {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                break
            } catch CocoaError.fileWriteFileExists where attempt < 100 {
                attempt += 1
                directory = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent)-\(attempt)", isDirectory: true)
            }
        }

        do {
            if options.needsScreenStream {
                let onError: (Error) -> Void = { [weak self] error in self?.reportSourceError(error) }
                let onAudio: (CMSampleBuffer, CMTime) -> Void = { [weak self] sample, pts in self?.handleAudio(sample, pts: pts, microphone: false) }
                let separateAudio = options.screen && options.systemAudio && options.target.isWindow
                screenSource.onVideo = { [weak self] buffer, pts in self?.handleVideo(buffer, pts: pts, camera: false) }
                screenSource.onAudio = onAudio
                screenSource.onError = onError
                display = try await screenSource.start(
                    target: options.screen ? options.target : .display(nil),
                    video: options.screen, systemAudio: options.systemAudio && !separateAudio,
                    fps: options.fps, showsCursor: options.showsCursor,
                    nativeResolution: options.nativeResolution, queue: queue)
                if separateAudio {
                    systemAudioSource.onAudio = onAudio
                    systemAudioSource.onError = onError
                    _ = try await systemAudioSource.start(
                        target: .display(nil), video: false, systemAudio: true, fps: options.fps,
                        showsCursor: false, nativeResolution: false, queue: queue)
                }
            }
            if options.needsDeviceSession {
                deviceSource.onVideo = { [weak self] buffer, pts in self?.handleVideo(buffer, pts: pts, camera: true) }
                deviceSource.onAudio = { [weak self] sample, pts in self?.handleAudio(sample, pts: pts, microphone: true) }
                deviceSource.onError = { [weak self] error in self?.reportSourceError(error) }
                try deviceSource.start(camera: options.camera, cameraID: options.cameraID, microphone: options.microphone, queue: queue)
            }
            try await waitForFirstFrames()
            try queue.sync { try beginWriting() }
        } catch {
            await stopSources()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        // The mouse is only logged alongside screen video: an audio-only or
        // camera-only recording has no use for it.
        startedAt = queue.sync { self.t0 }
        if options.screen, let display, let t0 = startedAt {
            // The recording carries on without a mouse log; the failure is reported at stop.
            do {
                try cursorLogger.start(url: directory.appendingPathComponent("cursor.jsonl"), display: display, t0: t0)
            } catch {
                cursorStartError = error
            }
        }
    }

    /// Stops capture, finishes the files and returns the session folder.
    func stop() async throws -> URL {
        // Fix the stop time first, then stop the sources and let their queued
        // callbacks run, so frames captured before the stop time still make it in.
        // The boundary is published immediately, before waiting for anything: the
        // recording ends when Stop was asked for, however busy the pipeline is, and
        // pacing ticks, media callbacks and the mouse log all honour it from now on.
        let now = hostNow()
        let limit: Double? = stopLock.withLock {
            if stopBoundary == nil, let startedAt { stopBoundary = (now, (now - startedAt).seconds) }
            return stopBoundary?.limit
        }
        cursorLogger.stop(at: limit)
        await stopSources()
        let files: [MovieFile] = queue.sync {
            pacer?.cancel()
            pacer = nil
            guard t0 != nil, !sealed, let stopTime = stopLimit else { return [] }
            sealed = true
            let screenDone = screenTrack?.drain(upTo: stopTime) ?? true
            let cameraDone = cameraTrack?.drain(upTo: stopTime) ?? true
            endedEarly = !(screenDone && cameraDone)

            let timecode = startTimecodeFrame()
            var files: [MovieFile] = []
            if let file = screenFile {
                // An audio-only file takes the camera's length when there is one, so the two files match.
                let duration = screenTrack?.duration ?? cameraTrack?.duration ?? CMTime(seconds: stopTime, preferredTimescale: 48_000)
                file.seal(duration: duration, startFrameNumber: timecode)
                files.append(file)
            }
            if let file = cameraFile, let track = cameraTrack {
                file.seal(duration: track.duration, startFrameNumber: timecode)
                files.append(file)
            }
            return files
        }
        // Report everything that went wrong together, so one problem never hides
        // the cause of another.
        var problems: [String] = []
        for file in files {
            do { try await file.finish() } catch {
                problems.append("\(file.url.lastPathComponent) could not be finished and may not play: \(error.localizedDescription).")
            }
        }
        do { try writeSummary() } catch {
            problems.append("The recording's details file (session.json) could not be written: \(error.localizedDescription).")
        }
        // A source that died mid-recording leaves files that play but freeze or go silent.
        if let sourceError = queue.sync(execute: { self.sourceError }) {
            problems.append("A capture source stopped during the recording, so it may be incomplete: \(sourceError.localizedDescription).")
        }
        if queue.sync(execute: { self.endedEarly }) {
            problems.append("The video encoder fell behind at the end, so the last moments of the recording may be missing.")
        }
        // Both audio sources deliver buffers continuously, even in silence, so a
        // track that received none means the source never worked.
        let silent: [String] = queue.sync {
            [("system audio", systemTrack), ("the microphone", micTrack)].compactMap { name, track in
                track.map { $0.writtenBuffers == 0 } == true ? name : nil
            }
        }
        if !silent.isEmpty {
            problems.append("No sound from \(silent.joined(separator: " or ")) reached the recording, so that track is silent.")
        }
        if let cursorError = cursorStartError ?? cursorLogger.writeError {
            problems.append("The mouse log (cursor.jsonl) is incomplete, so cursor effects will stop early: \(cursorError.localizedDescription).")
        }
        if !problems.isEmpty { throw RecorderError(problems.joined(separator: " ")) }
        return directory
    }

    /// Keeps the first source failure. The time is taken when the failure is
    /// reported, not when the queue gets to it, so a failure just before the user
    /// stops is kept while errors caused by shutting the sources down are ignored.
    private func reportSourceError(_ error: Error) {
        let reported = hostNow()
        queue.async { [weak self] in
            guard let self, self.sourceError == nil else { return }
            if let stopStarted = self.stopStarted, reported >= stopStarted { return }
            self.sourceError = error
        }
    }

    // MARK: - Setup

    private func checkPermissions() async throws {
        if options.needsScreenStream && !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw RecorderError("Screen Recording permission is needed. Allow CaptureDesktop in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch it.")
        }
        if options.camera, !(await AVCaptureDevice.requestAccess(for: .video)) {
            throw RecorderError("Camera permission is needed. Allow CaptureDesktop in System Settings > Privacy & Security > Camera.")
        }
        if options.microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            throw RecorderError("Microphone permission is needed. Allow CaptureDesktop in System Settings > Privacy & Security > Microphone.")
        }
    }

    private func waitForFirstFrames() async throws {
        let deadline = Date().addingTimeInterval(10)
        while true {
            let (ready, micKnown, error) = queue.sync {
                ((!options.screen || prerollScreen != nil) && (!options.camera || prerollCamera != nil),
                 !options.microphone || prerollMicChannels != nil,
                 sourceError)
            }
            if let error { throw error }
            // The microphone format is nice to have; video frames are required.
            if ready && (micKnown || Date() > deadline.addingTimeInterval(-8)) { return }
            if Date() > deadline {
                throw RecorderError("Timed out waiting for the first frame from the \(queue.sync { prerollScreen == nil && options.screen } ? "screen" : "camera")")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Runs on `queue`. Creates the writers and fixes T0.
    private func beginWriting() throws {
        if options.needsScreenStream {
            let name = options.screen ? "screen.mov" : "audio.mov"
            let file = try MovieFile(url: directory.appendingPathComponent(name), fps: options.fps)
            if options.screen, let seed = prerollScreen {
                // The pacing delay shrinks at high frame rates so the frames held stay
                // within ScreenCaptureKit's small buffer pool.
                screenTrack = try file.addVideo(seed: seed, bitsPerPixel: 0.10, latency: min(0.05, 3.0 / Double(options.fps)))
            }
            if options.systemAudio { systemTrack = try file.addAudio(name: "System Audio", channels: 2) }
            if options.microphone { micTrack = try file.addAudio(name: "Microphone", channels: prerollMicChannels ?? 1) }
            screenFile = file
        } else if options.microphone {
            let file = try MovieFile(url: directory.appendingPathComponent("audio.mov"), fps: options.fps)
            micTrack = try file.addAudio(name: "Microphone", channels: prerollMicChannels ?? 1)
            screenFile = file
        }
        if options.camera, let seed = prerollCamera {
            let file = try MovieFile(url: directory.appendingPathComponent("camera.mov"), fps: options.fps)
            cameraTrack = try file.addVideo(seed: seed, bitsPerPixel: 0.20, latency: min(0.10, 6.0 / Double(options.fps)))
            cameraFile = file
        }
        try screenFile?.begin()
        try cameraFile?.begin()
        prerollScreen = nil
        prerollCamera = nil

        t0 = hostNow()
        t0Date = Date()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(options.fps), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        pacer = timer
        timer.resume()
    }

    private func stopSources() async {
        await screenSource.stop()
        await systemAudioSource.stop()
        deviceSource.stop()
    }

    // MARK: - Pipeline (all on `queue`)

    private func tick() {
        guard let t0, !sealed else { return }
        let now = (hostNow() - t0).seconds
        let limit = stopLimit ?? .infinity
        if let track = screenTrack { track.emit(upTo: min(now - track.latency, limit)) }
        if let track = cameraTrack { track.emit(upTo: min(now - track.latency, limit)) }
        if sourceError == nil, let failure = screenFile?.failure ?? cameraFile?.failure { sourceError = failure }
    }

    private func handleVideo(_ buffer: CVPixelBuffer, pts: CMTime, camera: Bool) {
        guard !sealed else { return }
        let key = camera ? "camera" : "screen"
        if firstFrameLagMs[key] == nil { firstFrameLagMs[key] = (hostNow() - pts).seconds * 1000 }
        guard let t0 else {
            if camera { prerollCamera = buffer } else { prerollScreen = buffer }
            return
        }
        let t = (pts - t0).seconds
        if let stopLimit, t > stopLimit { return }
        (camera ? cameraTrack : screenTrack)?.push(buffer, t: t)
    }

    private func handleAudio(_ sample: CMSampleBuffer, pts: CMTime, microphone: Bool) {
        guard !sealed else { return }
        let key = microphone ? "microphone" : "systemAudio"
        if firstFrameLagMs[key] == nil { firstFrameLagMs[key] = (hostNow() - pts).seconds * 1000 }
        guard let t0 else {
            if microphone, prerollMicChannels == nil, let desc = sample.formatDescription,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                prerollMicChannels = Int(asbd.mChannelsPerFrame)
            }
            return
        }
        let t = (pts - t0).seconds
        let limit = stopLimit
        if let limit, t >= limit { return }
        (microphone ? micTrack : systemTrack)?.append(sample, t: t, limit: limit)
    }

    /// Time of day at T0 as a frame count, so both files carry the same start timecode.
    private func startTimecodeFrame() -> UInt32 {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: t0Date)
        let seconds = (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
        let frame = Int(Double(parts.nanosecond ?? 0) / 1e9 * Double(options.fps))
        return UInt32(seconds * Int(options.fps) + min(frame, Int(options.fps) - 1))
    }

    // MARK: - Summary

    private func writeSummary() throws {
        let summary: [String: Any] = queue.sync {
            var result: [String: Any] = [
                "startedAt": ISO8601DateFormatter().string(from: t0Date),
                "fps": Int(options.fps),
                "sources": [
                    "screen": options.screen, "camera": options.camera,
                    "microphone": options.microphone, "systemAudio": options.systemAudio,
                ],
                "firstSampleLagMs": firstFrameLagMs,
                "cursorEvents": cursorLogger.events,
            ]
            if let display {
                result["capture"] = [
                    "kind": display.kind,
                    "pixelWidth": display.pixelWidth, "pixelHeight": display.pixelHeight,
                    "scale": display.scale,
                    "boundsPoints": [display.bounds.minX, display.bounds.minY, display.bounds.width, display.bounds.height],
                    "cursorInVideo": options.showsCursor,
                ]
            }
            if let name = deviceSource.cameraName { result["camera"] = name }
            if let name = deviceSource.microphoneName { result["microphone"] = name }
            var tracks: [String: Any] = [:]
            for (name, track) in [("screen", screenTrack), ("camera", cameraTrack)] {
                guard let track else { continue }
                tracks[name] = [
                    "frames": track.nextIndex, "seconds": track.duration.seconds,
                    "sourceFrames": track.sourceFrames, "repeatedFrames": track.repeatedFrames,
                    "stalledTicks": track.stalledTicks, "droppedSourceFrames": track.droppedSourceFrames,
                ]
            }
            for (name, track) in [("systemAudio", systemTrack), ("microphone", micTrack)] {
                guard let track else { continue }
                tracks[name] = [
                    "seconds": track.seconds, "sampleRate": track.sampleRate,
                    "sourceBuffers": track.sourceBuffers, "writtenBuffers": track.writtenBuffers,
                    "droppedBuffers": track.droppedBuffers, "trimmedBuffers": track.trimmedBuffers,
                    "silenceSeconds": track.sampleRate > 0 ? Double(track.silenceFrames) / track.sampleRate : 0,
                    "maxDriftMs": track.maxDriftMs, "endsShort": track.endsShort,
                ]
            }
            result["tracks"] = tracks
            if let sourceError { result["error"] = sourceError.localizedDescription }
            return result
        }
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
}
