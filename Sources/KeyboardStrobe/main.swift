import Foundation
import ScreenCaptureKit
import AVFoundation

@objc class KeyboardBrightnessDummy: NSObject {
    @objc func setBrightness(_ brightness: Float, forKeyboard keyboardID: UInt64) -> Bool { return false }
    @objc func brightnessForKeyboard(_ keyboardID: UInt64) -> Float { return 0.0 }
    @objc func copyKeyboardBacklightIDs() -> NSArray? { return nil }
    @objc func enableAutoBrightness(_ enable: Bool, forKeyboard keyboardID: UInt64) -> Bool { return false }
    @objc func isAutoBrightnessEnabledForKeyboard(_ keyboardID: UInt64) -> Bool { return false }
}

class StreamDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("\n[Stream] Stopped with error: \(error)")
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

class AudioProcessor: NSObject, SCStreamOutput {
    let client: AnyObject
    let keyboardID: UInt64
    let initialBrightness: Float
    let initialAutoBrightness: Bool
    
    // Low-Pass Filter state to isolate bass frequencies (fc ≈ 120 Hz)
    var lpfBassLast: Float = 0.0
    
    // High-Pass Filter state to isolate snare/mid-high transients (fc ≈ 1200 Hz)
    var lpfSnareLast: Float = 0.0
    
    // Onset Detection Histories (last ~500ms)
    var bassHistory = [Float]()
    var snareHistory = [Float]()
    let historySize = 25
    
    var lastDetectedTime = Date()
    
    // Timing parameters to handle MacBook hardware LED latency
    let holdOnDuration: TimeInterval = 0.09
    let refractoryPeriod: TimeInterval = 0.20
    
    // Delay queue for perfect audio sync calibration
    struct BeatEvent {
        let triggerTime: Date
        let turnOffTime: Date
    }
    var beatQueue = [BeatEvent]()
    let delayDuration: TimeInterval // Configurable delay in seconds
    
    // Mode settings
    let mode: VisualizerMode
    
    enum VisualizerMode {
        case dual  // Flash on both Bass (kicks) and Treble (snares/claps)
        case bass  // Flash only on Bass kicks
        case snare // Flash only on Snare hits/claps
    }
    
    init(client: AnyObject, keyboardID: UInt64, initialBrightness: Float, initialAutoBrightness: Bool, mode: VisualizerMode, delayMs: Double) {
        self.client = client
        self.keyboardID = keyboardID
        self.initialBrightness = initialBrightness
        self.initialAutoBrightness = initialAutoBrightness
        self.mode = mode
        self.delayDuration = delayMs / 1000.0
        super.init()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = formatDescription.audioStreamBasicDescription,
              let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame) else {
            return
        }
        
        try? sampleBuffer.withAudioBufferList { audioBufferList, blockBuffer in
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer) else {
                return
            }
            guard let floatChannelData = pcmBuffer.floatChannelData else { return }
            let frameLength = Int(pcmBuffer.frameLength)
            if frameLength == 0 { return }
            
            let sampleRate = Float(asbd.mSampleRate)
            
            // --- Band 1: Bass Kick Isolation (LPF at 120Hz) ---
            let fcBass: Float = 120.0
            let alphaBass = (2.0 * Float.pi * fcBass) / sampleRate
            var bassSum: Float = 0
            
            // --- Band 2: Snare/Clap Isolation (HPF at 1200Hz) ---
            let fcSnare: Float = 1200.0
            let alphaSnare = (2.0 * Float.pi * fcSnare) / sampleRate
            var snareSum: Float = 0
            
            for i in 0..<frameLength {
                let sample = floatChannelData[0][i]
                
                // Bass Filter
                lpfBassLast = lpfBassLast + alphaBass * (sample - lpfBassLast)
                bassSum += lpfBassLast * lpfBassLast
                
                // Snare Filter
                lpfSnareLast = lpfSnareLast + alphaSnare * (sample - lpfSnareLast)
                let highPassedSample = sample - lpfSnareLast
                snareSum += highPassedSample * highPassedSample
            }
            
            let bassRms = sqrt(bassSum / Float(frameLength))
            let snareRms = sqrt(snareSum / Float(frameLength))
            
            // Update sliding windows
            bassHistory.append(bassRms)
            if bassHistory.count > historySize { bassHistory.removeFirst() }
            
            snareHistory.append(snareRms)
            if snareHistory.count > historySize { snareHistory.removeFirst() }
            
            let avgBass = bassHistory.reduce(0, +) / Float(bassHistory.count)
            let avgSnare = snareHistory.reduce(0, +) / Float(snareHistory.count)
            
            // Onset triggers
            let now = Date()
            
            var isBeatDetected = false
            
            let hasBassOnset = bassRms > 0.0002 && bassRms > avgBass * 1.20
            let hasSnareOnset = snareRms > 0.0003 && snareRms > avgSnare * 1.25
            
            switch mode {
            case .dual:
                isBeatDetected = hasBassOnset || hasSnareOnset
            case .bass:
                isBeatDetected = hasBassOnset
            case .snare:
                isBeatDetected = hasSnareOnset
            }
            
            // If a beat is detected outside the refractory period, queue a future trigger
            if isBeatDetected && now.timeIntervalSince(lastDetectedTime) >= refractoryPeriod {
                lastDetectedTime = now
                
                let triggerTime = now.addingTimeInterval(delayDuration)
                let turnOffTime = triggerTime.addingTimeInterval(holdOnDuration)
                beatQueue.append(BeatEvent(triggerTime: triggerTime, turnOffTime: turnOffTime))
            }
            
            // Filter out old/expired beat events
            beatQueue = beatQueue.filter { $0.turnOffTime > now }
            
            // Check if we are currently inside any active beat's trigger window
            let isLightOn = beatQueue.contains(where: { now >= $0.triggerTime && now <= $0.turnOffTime })
            
            let targetBrightness: Float = isLightOn ? 1.0 : 0.0
            _ = client.setBrightness?(targetBrightness, forKeyboard: keyboardID)
            
            // Terminal visualizer feedback
            let bar = (targetBrightness == 1.0) ? "████████████████████" : "░░░░░░░░░░░░░░░░░░░░"
            let stateName = (targetBrightness == 1.0) ? "ON " : "OFF"
            let modeName = String(describing: mode).uppercased()
            let delayStr = String(format: "%.0fms", delayDuration * 1000.0)
            print("\rMode: \(modeName) | Delay: \(delayStr) | Beat: \(stateName) | [\(bar)] (Bass: \(String(format: "%.4f", bassRms)) | Snare: \(String(format: "%.4f", snareRms)))", terminator: "")
            fflush(stdout)
        }
    }
}

func printHelp() {
    print("""
    Keyboard Strobe - macOS Keyboard Audio Visualizer
    
    Usage: keyboard-strobe [options]
    
    Options:
      --bass-only    Pulse only to bass kick drums (heavy rhythm).
      --snare-only   Pulse only to mid-high frequencies like snare drum and claps.
      --delay <ms>   Delay the light flashes by <ms> milliseconds to perfectly sync with
                     audio latency (e.g. Bluetooth speakers, AirPods, or built-in system buffer).
                     Default is 120 (120ms).
      --help         Display this help message.
      
    By default, keyboard-strobe monitors both bass and snare bands for optimal beat matching.
    """)
}

func main() {
    let args = CommandLine.arguments
    if args.contains("--help") || args.contains("-h") {
        printHelp()
        return
    }
    
    var mode = AudioProcessor.VisualizerMode.dual
    if args.contains("--bass-only") {
        mode = .bass
    } else if args.contains("--snare-only") {
        mode = .snare
    }
    
    var delayMs: Double = 120.0
    if let delayIndex = args.firstIndex(of: "--delay"), delayIndex + 1 < args.count {
        if let customDelay = Double(args[delayIndex + 1]) {
            delayMs = customDelay
        }
    }
    
    let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
    guard let handle = dlopen(path, RTLD_NOW) else {
        print("Error: Failed to load CoreBrightness framework.")
        return
    }
    defer { dlclose(handle) }
    
    guard let clientClass = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
        print("Error: Could not locate class 'KeyboardBrightnessClient'.")
        return
    }
    
    let clientInstance = clientClass.init()
    let client = clientInstance as AnyObject
    
    guard let ids = client.copyKeyboardBacklightIDs?(), ids.count > 0 else {
        print("Error: No keyboard backlights detected.")
        return
    }
    
    guard let keyboardID = (ids[0] as AnyObject).uint64Value else {
        print("Error: Could not determine keyboard ID.")
        return
    }
    
    let initialBrightness = client.brightnessForKeyboard?(keyboardID) ?? 0.5
    let initialAutoBrightness = client.isAutoBrightnessEnabledForKeyboard?(keyboardID) ?? false
    
    _ = client.enableAutoBrightness?(false, forKeyboard: keyboardID)
    
    // Get shareable content for ScreenCaptureKit
    let sema = DispatchSemaphore(value: 0)
    var shareableContent: SCShareableContent?
    var captureError: Error?
    
    SCShareableContent.getWithCompletionHandler { (content, error) in
        shareableContent = content
        captureError = error
        sema.signal()
    }
    
    _ = sema.wait(timeout: .now() + 5.0)
    
    if let error = captureError {
        print("Error getting shareable content: \(error)")
        _ = client.enableAutoBrightness?(initialAutoBrightness, forKeyboard: keyboardID)
        return
    }
    
    guard let content = shareableContent, let display = content.displays.first else {
        print("Error: No displays found for screen capture.")
        _ = client.enableAutoBrightness?(initialAutoBrightness, forKeyboard: keyboardID)
        return
    }
    
    let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = false
    
    let streamDelegate = StreamDelegate()
    let stream = SCStream(filter: filter, configuration: config, delegate: streamDelegate)
    
    let processor = AudioProcessor(client: client, keyboardID: keyboardID, initialBrightness: initialBrightness, initialAutoBrightness: initialAutoBrightness, mode: mode, delayMs: delayMs)
    
    do {
        try stream.addStreamOutput(processor, type: .audio, sampleHandlerQueue: DispatchQueue.global(qos: .userInitiated))
    } catch {
        print("Error adding stream output: \(error)")
        _ = client.enableAutoBrightness?(initialAutoBrightness, forKeyboard: keyboardID)
        return
    }
    
    var startError: Error?
    let startSema = DispatchSemaphore(value: 0)
    
    stream.startCapture { error in
        startError = error
        startSema.signal()
    }
    
    _ = startSema.wait(timeout: .now() + 5.0)
    
    if let error = startError {
        print("Error starting capture: \(error)")
        _ = client.enableAutoBrightness?(initialAutoBrightness, forKeyboard: keyboardID)
        return
    }
    
    print("\n=== Keyboard Audio Visualizer (Disco Beat Sync) ===")
    print("Status: Running.")
    print("Source: Direct Internal macOS Audio Output (No mic).")
    print("Detection: Dual-band (Kick LPF 120Hz + Snare HPF 1200Hz).")
    print("Timing: Calibrated delay of \(Int(delayMs))ms (use --delay to adjust).")
    print("To stop: Press Ctrl+C in this terminal window.")
    print("====================================================\n")
    
    signal(SIGINT) { _ in
        print("\nStopping visualizer...")
        CFRunLoopStop(CFRunLoopGetMain())
    }
    
    CFRunLoopRun()
    
    let stopSema = DispatchSemaphore(value: 0)
    stream.stopCapture { _ in
        stopSema.signal()
    }
    _ = stopSema.wait(timeout: .now() + 3.0)
    
    _ = client.setBrightness?(initialBrightness, forKeyboard: keyboardID)
    _ = client.enableAutoBrightness?(initialAutoBrightness, forKeyboard: keyboardID)
    print("Restored original keyboard brightness to \(initialBrightness * 100)%")
    print("Restored original auto-brightness state to \(initialAutoBrightness)")
}

main()
