import AppKit
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
    let holdOnDuration: TimeInterval = 0.15
    let refractoryPeriod: TimeInterval = 0.35
    
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
            
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    
    // Audio engine components
    var stream: SCStream?
    var processor: AudioProcessor?
    let client: AnyObject
    let keyboardID: UInt64
    let initialBrightness: Float
    let initialAutoBrightness: Bool
    
    // State
    var currentMode: AudioProcessor.VisualizerMode = .dual
    var currentDelayMs: Double = 120.0
    var isRunning = false
    
    // UI elements to update state
    var startStopMenuItem: NSMenuItem!
    
    override init() {
        let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        guard let handle = dlopen(path, RTLD_NOW) else {
            fatalError("Failed to load CoreBrightness framework.")
        }
        
        guard let clientClass = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            fatalError("Could not locate class 'KeyboardBrightnessClient'.")
        }
        
        let clientInstance = clientClass.init()
        self.client = clientInstance as AnyObject
        
        guard let ids = client.copyKeyboardBacklightIDs?(), ids.count > 0,
              let kid = (ids[0] as AnyObject).uint64Value else {
            fatalError("No keyboard backlights detected.")
        }
        
        self.keyboardID = kid
        self.initialBrightness = client.brightnessForKeyboard?(kid) ?? 0.5
        self.initialAutoBrightness = client.isAutoBrightnessEnabledForKeyboard?(kid) ?? false
        
        super.init()
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Keyboard Strobe")
        }
        
        let menu = NSMenu()
        
        startStopMenuItem = NSMenuItem(title: "Start Strobe", action: #selector(toggleStrobe), keyEquivalent: "s")
        menu.addItem(startStopMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        let modeMenu = NSMenu()
        modeMenu.addItem(NSMenuItem(title: "Dual (Bass + Snare)", action: #selector(setModeDual), keyEquivalent: ""))
        modeMenu.addItem(NSMenuItem(title: "Bass Only", action: #selector(setModeBass), keyEquivalent: ""))
        modeMenu.addItem(NSMenuItem(title: "Snare Only", action: #selector(setModeSnare), keyEquivalent: ""))
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        
        let delayMenu = NSMenu()
        delayMenu.addItem(NSMenuItem(title: "0 ms", action: #selector(setDelay0), keyEquivalent: ""))
        delayMenu.addItem(NSMenuItem(title: "80 ms", action: #selector(setDelay80), keyEquivalent: ""))
        delayMenu.addItem(NSMenuItem(title: "120 ms (Default)", action: #selector(setDelay120), keyEquivalent: ""))
        delayMenu.addItem(NSMenuItem(title: "150 ms", action: #selector(setDelay150), keyEquivalent: ""))
        let delayItem = NSMenuItem(title: "Audio Delay", action: nil, keyEquivalent: "")
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    @objc func toggleStrobe() {
        if isRunning {
            stopCapture()
            startStopMenuItem.title = "Start Strobe"
        } else {
            startCapture()
            startStopMenuItem.title = "Stop Strobe"
        }
    }
    
    @objc func setModeDual() { currentMode = .dual; restartIfRunning() }
    @objc func setModeBass() { currentMode = .bass; restartIfRunning() }
    @objc func setModeSnare() { currentMode = .snare; restartIfRunning() }
    
    @objc func setDelay0() { currentDelayMs = 0; restartIfRunning() }
    @objc func setDelay80() { currentDelayMs = 80; restartIfRunning() }
    @objc func setDelay120() { currentDelayMs = 120; restartIfRunning() }
    @objc func setDelay150() { currentDelayMs = 150; restartIfRunning() }
    
    func restartIfRunning() {
        if isRunning {
            stopCapture()
            startCapture()
        }
    }
    
    func startCapture() {
        _ = client.enableAutoBrightness?(false, forKeyboard: keyboardID)
        
        SCShareableContent.getWithCompletionHandler { [weak self] (content, error) in
            guard let self = self, let content = content, let display = content.displays.first else { return }
            
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = false
            
            let streamDelegate = StreamDelegate()
            self.stream = SCStream(filter: filter, configuration: config, delegate: streamDelegate)
            
            self.processor = AudioProcessor(client: self.client, keyboardID: self.keyboardID, initialBrightness: self.initialBrightness, initialAutoBrightness: self.initialAutoBrightness, mode: self.currentMode, delayMs: self.currentDelayMs)
            
            try? self.stream?.addStreamOutput(self.processor!, type: .audio, sampleHandlerQueue: DispatchQueue.global(qos: .userInitiated))
            
            self.stream?.startCapture { error in
                if error == nil {
                    DispatchQueue.main.async {
                        self.isRunning = true
                    }
                }
            }
        }
    }
    
    func stopCapture() {
        stream?.stopCapture { _ in }
        stream = nil
        processor = nil
        isRunning = false
        
        _ = client.setBrightness?(initialBrightness, forKeyboard: keyboardID)
        _ = client.enableAutoBrightness?(initialAutoBrightness, forKeyboard: keyboardID)
    }
    
    @objc func quitApp() {
        if isRunning { stopCapture() }
        NSApplication.shared.terminate(nil)
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        if isRunning { stopCapture() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
