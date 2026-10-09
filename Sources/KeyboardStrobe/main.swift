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

/// Owns the keyboard backlight. Every effect asks it for light and it writes one
/// level, so the music strobe, the typing pulse and the notification flash can run
/// together without fighting over the LEDs.
final class Backlight {
    enum Effect { case strobe, typing, notifications }

    private let client: AnyObject
    private let keyboardID: UInt64
    private let queue = DispatchQueue(label: "keyboardstrobe.backlight", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private var active = Set<Effect>()
    private var owning = false
    private var savedBrightness: Float = 0.5
    private var savedAutoBrightness = false
    private var lastWritten: Float = -1

    private var maxBrightness: Float = 1.0
    private var audioOn = false
    private var typingUntil = Date.distantPast
    private var flashes = [(on: Date, off: Date)]()

    // The LEDs take a moment to respond, so anything shorter than this is invisible.
    private let typingHold: TimeInterval = 0.22
    private let flashOn: TimeInterval = 0.16
    private let flashGap: TimeInterval = 0.14
    private let flashCount = 3

    init(client: AnyObject, keyboardID: UInt64) {
        self.client = client
        self.keyboardID = keyboardID
    }

    func set(_ effect: Effect, enabled: Bool) {
        queue.async {
            if enabled { self.active.insert(effect) } else { self.active.remove(effect) }
            if effect == .strobe && !enabled { self.audioOn = false }
            if effect == .typing && !enabled { self.typingUntil = .distantPast }
            if effect == .notifications && !enabled { self.flashes.removeAll() }
            self.tick()
        }
    }

    func setMaxBrightness(_ value: Float) { queue.async { self.maxBrightness = value; self.tick() } }

    /// From the audio thread: is a beat lit right now?
    func setAudio(_ on: Bool) {
        queue.async {
            guard self.audioOn != on else { return }
            self.audioOn = on
            self.tick()
        }
    }

    /// A key went down. Which key is never looked at.
    func keyPressed() {
        queue.async {
            guard self.active.contains(.typing) else { return }
            self.typingUntil = Date().addingTimeInterval(self.typingHold)
            self.tick()
        }
    }

    /// A notification arrived: blink a few times.
    func notificationArrived() {
        queue.async {
            guard self.active.contains(.notifications), self.flashes.isEmpty else { return }
            var start = Date()
            for _ in 0..<self.flashCount {
                self.flashes.append((on: start, off: start.addingTimeInterval(self.flashOn)))
                start = start.addingTimeInterval(self.flashOn + self.flashGap)
            }
            self.tick()
        }
    }

    /// Give the backlight back before the app exits. Blocks until it is done.
    func shutdown() {
        queue.sync {
            self.active.removeAll()
            self.flashes.removeAll()
            self.audioOn = false
            self.typingUntil = .distantPast
            self.tick()
        }
    }

    /// The strobe and the typing pulse keep the keyboard dark between beats and
    /// keystrokes, so they hold the backlight for as long as they are on. Waiting
    /// for a notification changes nothing: the backlight is only taken for the
    /// blink itself, then handed back exactly as it was found.
    private func take() {
        savedBrightness = client.brightnessForKeyboard?(keyboardID) ?? 0.5
        savedAutoBrightness = client.isAutoBrightnessEnabledForKeyboard?(keyboardID) ?? false
        _ = client.enableAutoBrightness?(false, forKeyboard: keyboardID)
        lastWritten = -1
        owning = true

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func handBack() {
        timer?.cancel()
        timer = nil
        owning = false
        _ = client.setBrightness?(savedBrightness, forKeyboard: keyboardID)
        _ = client.enableAutoBrightness?(savedAutoBrightness, forKeyboard: keyboardID)
    }

    private func tick() {
        let now = Date()
        if let last = flashes.last, now >= last.off { flashes.removeAll() }

        let needed = active.contains(.strobe) || active.contains(.typing) || !flashes.isEmpty
        if needed && !owning { take() }
        if !needed {
            if owning { handBack() }
            return
        }

        let lit: Bool
        if !flashes.isEmpty {
            // A notification blink overrides everything else until it finishes.
            lit = flashes.contains(where: { now >= $0.on && now < $0.off })
        } else {
            lit = audioOn || now < typingUntil
        }

        let level = lit ? maxBrightness : 0
        if level != lastWritten {
            lastWritten = level
            _ = client.setBrightness?(level, forKeyboard: keyboardID)
        }
    }
}

/// Reports every key press, without ever looking at which key it was.
/// Needs the Input Monitoring permission.
final class TypingMonitor {
    var onKey: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static var isAllowed: Bool { CGPreflightListenEventAccess() }
    static func requestAccess() { _ = CGRequestListenEventAccess() }

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<TypingMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if type == .keyDown {
                monitor.onKey?()
            }
            return Unmanaged.passUnretained(event)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                             options: .listenOnly, eventsOfInterest: mask,
                                             callback: callback,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        source = newSource
        return true
    }

    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }
}

/// Notices when a notification banner comes on screen.
///
/// macOS has no public way to hear about other apps' notifications. What can be
/// seen without any extra permission is the Notification Centre process putting
/// its window on screen, which it does to draw a banner. Two limits follow:
/// opening Notification Centre by hand looks the same, and a notification that
/// shows no banner (a Focus mode, or banners switched off for that app) is missed.
final class NotificationMonitor {
    var onNotification: (() -> Void)?
    private var timer: Timer?
    private var wasShowing = false

    func start() {
        guard timer == nil else { return }
        wasShowing = Self.bannerOnScreen()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let showing = Self.bannerOnScreen()
            if showing && !self.wasShowing { self.onNotification?() }
            self.wasShowing = showing
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    static func bannerOnScreen() -> Bool {
        // Found by bundle id: the process name is translated ("Notification Centre", ...).
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .map { Int($0.processIdentifier) })
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int, pids.contains(pid),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return false }
            return width > 40 && height > 20
        }
    }
}

class AudioProcessor: NSObject, SCStreamOutput {
    let backlight: Backlight
    
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
    var delayDuration: TimeInterval // Configurable delay in seconds
    
    // Mode settings
    var mode: VisualizerMode
    
    enum VisualizerMode {
        case dual  // Flash on both Bass (kicks) and Treble (snares/claps)
        case bass  // Flash only on Bass kicks
        case snare // Flash only on Snare hits/claps
    }

    init(backlight: Backlight, mode: VisualizerMode, delayMs: Double) {
        self.backlight = backlight
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
            
            backlight.setAudio(isLightOn)
            
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var statusItem: NSStatusItem!
    
    // Audio engine components
    var stream: SCStream?
    var processor: AudioProcessor?
    let client: AnyObject
    let keyboardID: UInt64
    let backlight: Backlight
    let typingMonitor = TypingMonitor()
    let notificationMonitor = NotificationMonitor()
    
    // State
    var currentMode: AudioProcessor.VisualizerMode = .dual
    var currentDelayMs: Double = 120.0
    var currentMaxBrightness: Float = 1.0
    var isRunning = false
    var typingPulseOn = false
    var notificationFlashOn = false
    
    // UI elements to update state
    var startStopMenuItem: NSMenuItem!
    var typingMenuItem: NSMenuItem!
    var notificationMenuItem: NSMenuItem!
    
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
        self.backlight = Backlight(client: clientInstance as AnyObject, keyboardID: kid)
        
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
        
        typingMenuItem = NSMenuItem(title: "Typing Pulse", action: #selector(toggleTypingPulse), keyEquivalent: "t")
        menu.addItem(typingMenuItem)
        notificationMenuItem = NSMenuItem(title: "Notification Flash", action: #selector(toggleNotificationFlash), keyEquivalent: "n")
        menu.addItem(notificationMenuItem)
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
        
        let brightnessMenu = NSMenu()
        brightnessMenu.addItem(NSMenuItem(title: "100% (Maximum Contrast)", action: #selector(setBrightness100), keyEquivalent: ""))
        brightnessMenu.addItem(NSMenuItem(title: "75% (Faster Fade)", action: #selector(setBrightness75), keyEquivalent: ""))
        brightnessMenu.addItem(NSMenuItem(title: "50% (Fastest/Snappiest Fade)", action: #selector(setBrightness50), keyEquivalent: ""))
        let brightnessItem = NSMenuItem(title: "Max Brightness", action: nil, keyEquivalent: "")
        brightnessItem.submenu = brightnessMenu
        menu.addItem(brightnessItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
        
        typingMonitor.onKey = { [weak self] in self?.backlight.keyPressed() }
        notificationMonitor.onNotification = { [weak self] in self?.backlight.notificationArrived() }
        
        // Bring back what was switched on last time.
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "typingPulse") { setTypingPulse(true, askForAccess: false) }
        if defaults.bool(forKey: "notificationFlash") { setNotificationFlash(true) }
    }
    
    @objc func toggleTypingPulse() { setTypingPulse(!typingPulseOn, askForAccess: true) }
    @objc func toggleNotificationFlash() { setNotificationFlash(!notificationFlashOn) }
    
    func setTypingPulse(_ on: Bool, askForAccess: Bool) {
        if on {
            guard typingMonitor.start() else {
                // macOS will not hand key presses to an app until the user allows it.
                if askForAccess {
                    TypingMonitor.requestAccess()
                    let alert = NSAlert()
                    alert.messageText = "Typing Pulse needs Input Monitoring"
                    alert.informativeText = "Open System Settings → Privacy & Security → Input Monitoring, switch Keyboard Strobe on, then choose Typing Pulse again.\n\nKeyboard Strobe only counts key presses. It never reads which keys you type."
                    alert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
                return
            }
        } else {
            typingMonitor.stop()
        }
        typingPulseOn = on
        backlight.set(.typing, enabled: on)
        UserDefaults.standard.set(on, forKey: "typingPulse")
    }
    
    func setNotificationFlash(_ on: Bool) {
        if on { notificationMonitor.start() } else { notificationMonitor.stop() }
        notificationFlashOn = on
        backlight.set(.notifications, enabled: on)
        UserDefaults.standard.set(on, forKey: "notificationFlash")
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
    
    @objc func setModeDual() { currentMode = .dual; updateProcessor() }
    @objc func setModeBass() { currentMode = .bass; updateProcessor() }
    @objc func setModeSnare() { currentMode = .snare; updateProcessor() }
    
    @objc func setDelay0() { currentDelayMs = 0; updateProcessor() }
    @objc func setDelay80() { currentDelayMs = 80; updateProcessor() }
    @objc func setDelay120() { currentDelayMs = 120; updateProcessor() }
    @objc func setDelay150() { currentDelayMs = 150; updateProcessor() }
    
    @objc func setBrightness100() { currentMaxBrightness = 1.0; updateProcessor() }
    @objc func setBrightness75() { currentMaxBrightness = 0.2; updateProcessor() }
    @objc func setBrightness50() { currentMaxBrightness = 0.05; updateProcessor() }
    
    func updateProcessor() {
        backlight.setMaxBrightness(currentMaxBrightness)
        if let proc = processor {
            proc.mode = currentMode
            proc.delayDuration = currentDelayMs / 1000.0
        }
    }
    
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTypingPulse) { menuItem.state = typingPulseOn ? .on : .off }
        else if menuItem.action == #selector(toggleNotificationFlash) { menuItem.state = notificationFlashOn ? .on : .off }
        else if menuItem.action == #selector(setModeDual) { menuItem.state = (currentMode == .dual) ? .on : .off }
        else if menuItem.action == #selector(setModeBass) { menuItem.state = (currentMode == .bass) ? .on : .off }
        else if menuItem.action == #selector(setModeSnare) { menuItem.state = (currentMode == .snare) ? .on : .off }
        
        else if menuItem.action == #selector(setDelay0) { menuItem.state = (currentDelayMs == 0) ? .on : .off }
        else if menuItem.action == #selector(setDelay80) { menuItem.state = (currentDelayMs == 80) ? .on : .off }
        else if menuItem.action == #selector(setDelay120) { menuItem.state = (currentDelayMs == 120) ? .on : .off }
        else if menuItem.action == #selector(setDelay150) { menuItem.state = (currentDelayMs == 150) ? .on : .off }
        
        else if menuItem.action == #selector(setBrightness100) { menuItem.state = (currentMaxBrightness == 1.0) ? .on : .off }
        else if menuItem.action == #selector(setBrightness75) { menuItem.state = (currentMaxBrightness == 0.2) ? .on : .off }
        else if menuItem.action == #selector(setBrightness50) { menuItem.state = (currentMaxBrightness == 0.05) ? .on : .off }
        
        return true
    }
    
    func startCapture() {
        backlight.setMaxBrightness(currentMaxBrightness)
        backlight.set(.strobe, enabled: true)
        
        SCShareableContent.getWithCompletionHandler { [weak self] (content, error) in
            guard let self = self, let content = content, let display = content.displays.first else { return }
            
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = false
            
            let streamDelegate = StreamDelegate()
            self.stream = SCStream(filter: filter, configuration: config, delegate: streamDelegate)
            
            self.processor = AudioProcessor(backlight: self.backlight, mode: self.currentMode, delayMs: self.currentDelayMs)
            
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
        
        backlight.set(.strobe, enabled: false)
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        if isRunning { stopCapture() }
        typingMonitor.stop()
        notificationMonitor.stop()
        backlight.shutdown()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
