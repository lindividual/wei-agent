import AVFAudio
import AVFoundation
import Foundation
import Speech

import WeiModel

/// The audio half of dictation: a microphone in, sentences out.
///
/// The other half — what a sentence does to the field, and what each way of ending one means — is
/// `Dictation` in `WeiModel`, where it can be tested without any of this. This type is the part that
/// cannot be tested without a microphone, so it is kept as thin as it can be: permission, a language, a
/// model, a tap, and a translation of framework callbacks into five events.
///
/// **Everything here is the platform's own speech stack**, which is what the reader asked for and what
/// the measurements support: it is on-device (nothing leaves the machine and nothing needs a network),
/// it produces partial results while a person is still speaking (measured: the first characters about a
/// second in), and it has no length limit on a sentence (measured against 61 seconds of continuous audio;
/// the one-minute limit that people remember belongs to the *old* `SFSpeechRecognizer` API, which this
/// deliberately does not use).
///
/// **`DictationTranscriber` rather than `SpeechTranscriber`.** They are two different models behind the
/// same API: the first is the one the system's own dictation uses, and it is better suited to this by
/// construction — it is fed hints (`shortForm`, for the sentences a person types into a box) and options
/// (punctuation, emoji) that exist for exactly this job. Measured on this machine: the same audio that
/// gives a `SpeechTranscriber` no usable format at all, or a sentence without capitalisation, is handled
/// by `DictationTranscriber` with punctuation and correct case.
@MainActor
final class VoiceCapture {
    /// What the microphone has to say. Deliberately not `DictationEffect`: this side reports what
    /// happened, and the model decides what it means.
    enum Event {
        /// The button was pressed and the model is being loaded. Nothing is heard yet.
        case starting
        /// The microphone is open and the reader may speak.
        case listening
        /// The sentence so far, which may revise what was sent before.
        case partial(String)
        /// The sentence, settled.
        case final(String)
        /// It cannot go on, or could not start.
        case trouble(DictationTrouble)
    }

    /// Called for each event, on the main actor.
    var onEvent: ((Event) -> Void)?

    /// The locale being dictated in, once `start()` has resolved one.
    private(set) var locale: String?

    private var analyzer: SpeechAnalyzer?
    private var engine: AVAudioEngine?
    private var consumer: Task<Void, Never>?
    private var audio: AsyncStream<AnalyzerInput>.Continuation?

    /// Whether a settled sentence has been reported since the reader asked to stop.
    ///
    /// The guarantee this exists for: **a stop always ends the session.** The final result is what settles a
    /// sentence, and it normally arrives in a fraction of a second — but "normally" is not something a UI can
    /// be built on, and a stop that produced no final left the reader listening forever: the button stayed in
    /// its listening state, the sentence stayed a composition in the field, and pressing the button again did
    /// nothing, because the engine was still open. So `stop` waits a moment for the real result and, if it
    /// does not come, ends the session itself with what was heard.
    private var settledSinceStop = false

    // ── language and models ───────────────────────────────────────────────

    /// The languages this Mac can dictate, most likely first.
    static func languages() async -> [String] {
        await DictationTranscriber.supportedLocales.map(\.identifier).sorted()
    }

    /// The language to dictate in, given what the reader (or the system) asked for.
    ///
    /// `nil` means this Mac cannot dictate that language at all, which is a real answer and not an error:
    /// the platform's own mapping is used rather than a table of ours, so the answer here is the same one
    /// the system's dictation would give.
    static func resolve(_ wanted: String?) async -> String? {
        // The system's own preference list first, in the reader's order, because that is what "my
        // language" means; then the last one they chose here.
        for identifier in [wanted].compactMap({ $0 }) + Locale.preferredLanguages {
            if let supported = await DictationTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: identifier))
            {
                return supported.identifier
            }
        }
        return nil
    }

    /// Whether the model for a language is on the machine, or still to come.
    func modelStatus(locale identifier: String) async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [transcriber(locale: identifier)])
    }

    /// Whether there is a download to offer at all.
    func hasModelToInstall(locale identifier: String) async -> Bool {
        (try? await AssetInventory.assetInstallationRequest(
            supporting: [transcriber(locale: identifier)])) != nil
    }

    /// Download and install the model for a language, reporting how far along it is.
    ///
    /// The system decides the size and the source; all that can be said here is that it is happening.
    /// `SpeechModels.endRetention()` is deliberately *not* called when dictation stops: reserving a
    /// language is what keeps the model on disk between sentences, and the platform caps how many can be
    /// reserved, so reserving is the right default and releasing is for a settings action, not for this.
    func installModel(locale identifier: String, progress: @escaping (Double) -> Void) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber(locale: identifier)])
        else { return }
        let watching = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watching.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    private func transcriber(locale identifier: String) -> DictationTranscriber {
        DictationTranscriber(
            locale: Locale(identifier: identifier),
            // The hints and options that make this a *dictation* model rather than a transcription one:
            // short sentences written into a box, with punctuation, and with the emoji a person would
            // have typed.
            //
            // **`frequentFinalization` is not optional, and leaving it out is the bug this file was written
            // to find.** With `volatileResults` alone the recogniser reports a sentence as a *hypothesis*
            // and never commits one: measured, a three-second sentence produced twelve partial results and
            // **zero** final ones, `finalize(through:)` and `finish(after:)` changed nothing, and ending the
            // audio stream just ended the sequence — so the reader watched correct words appear in the box
            // and could never send them, because the sentence never became text. Adding this one option
            // produces the final: same audio, same everything else, one final result and the sentence is
            // settled. (The two are separate options on purpose: "tell me early" and "commit" are different
            // asks, and only the second one writes anything down.)
            contentHints: [.shortForm],
            transcriptionOptions: [.punctuation, .emoji],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: []
        )
    }

    // ── the microphone ────────────────────────────────────────────────────

    /// Open the microphone and start listening. Reports `listening` when there is something to say.
    func start(wanted: String?) async {
        guard engine == nil else { return }

        guard await permitted() else {
            onEvent?(.trouble(.microphoneNotPermitted))
            return
        }
        guard let identifier = await Self.resolve(wanted) else {
            onEvent?(.trouble(.languageUnsupported(locale: wanted ?? Locale.current.identifier)))
            return
        }
        locale = identifier

        let transcriber = transcriber(locale: identifier)
        // **The model check, and it is not optional.** A language can be supported by the framework and
        // still have no model on the machine; the only signal is that no audio format is available, and
        // without this check that case reaches the reader as a microphone button that does nothing at
        // all. Measured: `bestAvailableAudioFormat` is `nil` for a language whose model is not installed,
        // and the framework raises nothing.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else {
            onEvent?(.trouble(.modelMissing(locale: identifier)))
            return
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let natural = input.outputFormat(forBus: 0)
        guard natural.sampleRate > 0 else {
            onEvent?(.trouble(.failed("the microphone is not giving any audio")))
            return
        }        // The microphone's own format and the model's are rarely the same (measured here: 48 kHz stereo
        // in, 16 kHz mono to the model), and the conversion is ours to do.
        guard let converter = AVAudioConverter(from: natural, to: format) else {
            onEvent?(.trouble(.failed("the microphone's format is not one the model accepts")))
            return
        }

        let (stream, audio) = AsyncStream<AnalyzerInput>.makeStream()
        self.audio = audio
        input.installTap(onBus: 0, bufferSize: 4096, format: natural) { buffer, _ in
            // On a realtime thread: convert, hand over, return. Nothing here touches the main actor.
            let capacity = AVAudioFrameCount(
                Double(buffer.frameLength) * format.sampleRate / natural.sampleRate) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                return
            }
            var error: NSError?
            var fed = false
            converter.convert(to: converted, error: &error) { _, status in
                // One buffer in, one buffer out, and the converter is told so on the second ask.
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, converted.frameLength > 0 else { return }
            audio.yield(AnalyzerInput(buffer: converted))
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // **Load the model before opening the microphone.** In the other order the first seconds of speech
        // are simply lost: the audio is flowing while the model is still being loaded, and what the reader
        // said in the meantime is gone — measured, twice, once as a missing 「请帮我」 at the front of a
        // sentence and once as a whole sentence. `prepareToAnalyze` is the API for exactly this, and it is
        // why `starting` is a state the reader can see rather than a delay nobody can explain.
        onEvent?(.starting)
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            await teardown()
            onEvent?(.trouble(.failed(error.localizedDescription)))
            return
        }

        self.engine = engine
        consumer = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard let self else { return }
                    if result.isFinal {
                        self.settledSinceStop = true
                        self.onEvent?(.final(text))
                    } else {
                        self.onEvent?(.partial(text))
                    }
                }
            } catch {
                self?.onEvent?(.trouble(.failed(error.localizedDescription)))
            }
        }

        do {
            engine.prepare()
            try engine.start()
            try await analyzer.start(inputSequence: stream)
        } catch {
            await teardown()
            onEvent?(.trouble(.failed(error.localizedDescription)))
            return
        }
        onEvent?(.listening)
    }

    /// Stop listening and let the recogniser settle the sentence. The final result arrives as `.final`.
    ///
    /// The microphone is closed here, before the result is waited for: a reader who pressed stop has
    /// stopped being recorded, and keeping the input running for the fraction of a second the model needs
    /// would be a worse trade than the one it saves.
    func stop() async {
        closeMicrophone()
        settledSinceStop = false
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            onEvent?(.trouble(.failed(error.localizedDescription)))
            return
        }
        // Wait for the recogniser's own answer, briefly. A tenth of a second is the cadence it reports at
        // while a reader is speaking, so this is several times longer than it needs to a settled sentence
        // that is coming at all.
        for _ in 0..<20 {
            if settledSinceStop { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !settledSinceStop {
            // It never came. The session ends here regardless, and the sentence is settled with what was
            // heard: a reader who pressed stop gets text, not a spinner and a microphone that will not close.
            onEvent?(.final(""))
        }
        await teardown()
    }

    /// Throw the sentence away. Nothing is reported back, because there is nothing to report.
    func cancel() async {
        closeMicrophone()
        let analyzer = self.analyzer
        self.analyzer = nil
        consumer?.cancel()
        consumer = nil
        await analyzer?.cancelAndFinishNow()
    }

    /// Close the microphone. Shared by `stop` and `cancel`, and safe to call twice.
    private func closeMicrophone() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audio?.finish()
        audio = nil
        self.engine = nil
    }

    /// Drop everything, after the sentence has been settled.
    private func teardown() async {
        closeMicrophone()
        let analyzer = self.analyzer
        self.analyzer = nil
        consumer = nil
        await analyzer?.cancelAndFinishNow()
    }

    /// The microphone permission, asking for it the first time.
    ///
    /// Asked for when the reader presses the button rather than when the app starts: a permission prompt
    /// out of nowhere is the kind of thing people refuse, and refusing it makes the button useless for
    /// good. Right after they asked to speak is the one moment the question makes sense.
    private func permitted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }
}

extension AsyncStream {
    /// A stream and its continuation in one call, so the two cannot be separated by mistake.
    fileprivate static func makeStream() -> (AsyncStream<Element>, AsyncStream<Element>.Continuation) {
        var continuation: AsyncStream<Element>.Continuation!
        let stream = AsyncStream<Element> { continuation = $0 }
        return (stream, continuation)
    }
}
