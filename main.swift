// PROTOTYPE: AirPods head motion as a mouse. Single file, built to test whether the idea feels good.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreMotion

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/HeadMouseSpike.log")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try? FileHandle(forWritingTo: logURL)
func logLine(_ s: String) { logHandle?.write(("\(Date().timeIntervalSince1970) \(s)\n").data(using: .utf8)!) }

func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { min(max(v, a), b) }
func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
func wrapAngle(_ a: Double) -> Double {
    var v = a
    while v > .pi { v -= 2 * .pi }
    while v < -.pi { v += 2 * .pi }
    return v
}

// Our own events carry this tag, so the tap below can tell them from real trackpad or keyboard input.
let ownEventTag: Int64 = 0x484D5350
var lastPhysicalInput: TimeInterval = 0
var lastPhysicalReason = ""
var ownEventsSeen = 0, physicalEventsSeen = 0
var inputTap: CFMachPort?

func installInputTap() {
    let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    inputTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let inputTap { CGEvent.tapEnable(tap: inputTap, enable: true) }
            logLine("input tap re-enabled")
        } else if event.getIntegerValueField(.eventSourceUserData) == ownEventTag {
            ownEventsSeen += 1
        } else {
            physicalEventsSeen += 1
            lastPhysicalInput = Date.timeIntervalSinceReferenceDate
            lastPhysicalReason = "\(type.rawValue)"
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil)
    guard let inputTap, let source = CFMachPortCreateRunLoopSource(nil, inputTap, 0) else { logLine("input tap FAILED: no pause on physical input"); return }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: inputTap, enable: true)
    logLine("input tap installed")
}

final class RingView: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard progress > 0 else { return }
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let track = NSBezierPath(); track.appendArc(withCenter: c, radius: 17, startAngle: 0, endAngle: 360)
        track.lineWidth = 4; NSColor.black.withAlphaComponent(0.35).setStroke(); track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: 17, startAngle: 90, endAngle: 90 - 360 * progress, clockwise: true)
        arc.lineWidth = 4; arc.lineCapStyle = .round; NSColor.systemTeal.setStroke(); arc.stroke()
    }
}

final class HeadMouse: NSObject, CMHeadphoneMotionManagerDelegate {
    let motion = CMHeadphoneMotionManager()
    let src = CGEventSource(stateID: .privateState)
    let defaults = UserDefaults.standard
    var statusItem: NSStatusItem!
    let ringWindow: NSWindow
    let ring = RingView(frame: NSRect(x: 0, y: 0, width: 48, height: 48))

    var active = false
    var precision = false
    var dwellEnabled = false
    var invertX: Bool { get { defaults.bool(forKey: "invertX") } set { defaults.set(newValue, forKey: "invertX") } }
    var invertY: Bool { get { defaults.bool(forKey: "invertY") } set { defaults.set(newValue, forKey: "invertY") } }
    var invertScroll: Bool { get { defaults.bool(forKey: "invertScroll") } set { defaults.set(newValue, forKey: "invertScroll") } }

    // Motion state
    var last: (yaw: Double, pitch: Double, t: TimeInterval)?
    var rollNeutral: Double?
    var roll = 0.0, yaw = 0.0, pitch = 0.0
    var smoothX = 0.0, smoothY = 0.0, pendingX = 0.0, pendingY = 0.0
    var scrolling = false
    var sampleCount = 0
    var streaming = false

    // Dwell state
    var anchor = CGPoint.zero, anchorTime = Date.timeIntervalSinceReferenceDate
    var lastClickPoint = CGPoint(x: -9999, y: -9999)
    var armed = false
    var pausedLogged = false

    override init() {
        ringWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 48, height: 48), styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        ringWindow.isOpaque = false
        ringWindow.backgroundColor = .clear
        ringWindow.ignoresMouseEvents = true
        ringWindow.hasShadow = false
        ringWindow.level = .screenSaver
        ringWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ringWindow.contentView = ring
        motion.delegate = self
        src?.userData = ownEventTag
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        logLine("launch accessibility=\(trusted) motionAvailable=\(motion.isDeviceMotionAvailable) motionAuth=\(CMHeadphoneMotionManager.authorizationStatus().rawValue)")
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.heartbeat() }
        // Starting the stream is what triggers the Motion prompt, so ask at launch.
        if CMHeadphoneMotionManager.authorizationStatus() == .notDetermined {
            promptingForMotion = true
            motion.startDeviceMotionUpdates(to: .main) { _, _ in }
            logLine("requested motion permission")
        }
    }
    var promptingForMotion = false

    // MARK: Menu
    func rebuildMenu() {
        let trusted = AXIsProcessTrusted()
        statusItem.button?.title = active ? (precision ? "🎧 ON·slow" : "🎧 ON") : "🎧 off"
        let m = NSMenu()
        func info(_ t: String) { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; m.addItem(i) }
        func item(_ t: String, _ a: Selector, _ on: Bool = false) {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self; i.state = on ? .on : .off; m.addItem(i)
        }
        info(streaming ? "AirPods motion: streaming" : (active ? "AirPods motion: waiting for AirPods" : "AirPods motion: idle"))
        if !trusted { info("⚠️ Accessibility not granted: no cursor or clicks") }
        if CMHeadphoneMotionManager.authorizationStatus() == .denied { info("⚠️ Motion access denied: no head tracking") }
        m.addItem(.separator())
        item(active ? "Turn off (⌃⌥H)" : "Turn on (⌃⌥H)", #selector(toggleActive))
        item("Slow mode (⌃⌥P)", #selector(togglePrecision), precision)
        item("Pause-to-click (⌃⌥D)", #selector(toggleDwell), dwellEnabled)
        item("Re-center tilt (⌃⌥R)", #selector(recenter))
        m.addItem(.separator())
        item("Flip left/right", #selector(flipX), invertX)
        item("Flip up/down", #selector(flipY), invertY)
        item("Flip scroll", #selector(flipScroll), invertScroll)
        m.addItem(.separator())
        item("Quit", #selector(quit))
        statusItem.menu = m
    }

    @objc func toggleActive() { setActive(!active) }
    @objc func togglePrecision() { precision.toggle(); logLine("precision=\(precision)"); rebuildMenu() }
    @objc func toggleDwell() { dwellEnabled.toggle(); armed = false; ring.progress = 0; ringWindow.orderOut(nil); logLine("dwell=\(dwellEnabled)"); rebuildMenu() }
    @objc func recenter() { rollNeutral = nil; logLine("recenter"); }
    @objc func flipX() { invertX.toggle(); rebuildMenu() }
    @objc func flipY() { invertY.toggle(); rebuildMenu() }
    @objc func flipScroll() { invertScroll.toggle(); rebuildMenu() }
    @objc func quit() { setActive(false); NSApp.terminate(nil) }

    func setActive(_ on: Bool) {
        active = on
        last = nil; rollNeutral = nil; smoothX = 0; smoothY = 0; pendingX = 0; pendingY = 0
        scrolling = false; armed = false; ring.progress = 0; ringWindow.orderOut(nil)
        streaming = false
        if on {
            startStream()
            if let p = CGEvent(source: nil)?.location { anchor = p; lastClickPoint = p }
        } else {
            motion.stopDeviceMotionUpdates()
        }
        logLine("active=\(on)")
        rebuildMenu()
    }

    func startStream() {
        streamStartedAt = now
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, err in
            if let err { logLine("motion error: \(err)"); return }
            if let m { self?.onMotion(m) }
        }
    }
    var ignoreDisconnectUntil: TimeInterval = 0
    var streamStartedAt: TimeInterval = 0
    var lastSampleAt: TimeInterval = 0
    var postedMoves = 0, pausedTicks = 0, runningTicks = 0
    var pauseReason = ""

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) { logLine("airpods connected"); rebuildMenu() }
    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        // Restarting the stream reports a disconnect too, so it must not switch the app off.
        if now < ignoreDisconnectUntil { logLine("disconnect ignored during restart"); return }
        logLine("airpods disconnected: turning off")
        if active { setActive(false) }
    }

    // MARK: Motion to pending cursor movement
    func onMotion(_ m: CMDeviceMotion) {
        sampleCount += 1
        lastSampleAt = now
        if !streaming { streaming = true; rebuildMenu() }
        let a = m.attitude
        yaw = a.yaw; pitch = a.pitch
        guard let prev = last else {
            last = (a.yaw, a.pitch, m.timestamp); rollNeutral = a.roll; return
        }
        let dt = max(m.timestamp - prev.t, 0.001)
        let dYaw = wrapAngle(a.yaw - prev.yaw), dPitch = a.pitch - prev.pitch
        last = (a.yaw, a.pitch, m.timestamp)

        if rollNeutral == nil { rollNeutral = a.roll }
        let r = wrapAngle(a.roll - (rollNeutral ?? a.roll))
        roll = r
        // Tilt zone with hysteresis: enter at 15 degrees, leave at 10.
        if !scrolling && abs(r) > 0.26 { scrolling = true; armed = false; logLine("scroll start roll=\(r)") }
        else if scrolling && abs(r) < 0.17 { scrolling = false; logLine("scroll end"); resetAnchor() }
        // Slowly follow posture changes while the head is close to level.
        if abs(r) < 0.12, let n = rollNeutral { rollNeutral = n + wrapAngle(a.roll - n) * 0.002 }
        if scrolling { pendingX = 0; pendingY = 0; smoothX = 0; smoothY = 0; return }

        // Slow head motion gets low gain for accuracy, fast motion crosses the screen.
        let w = hypot(dYaw, dPitch) / dt
        let deadzone = 0.05
        let keep = clamp((w - deadzone) / deadzone, 0, 1)
        let s = clamp((w - 0.15) / (1.2 - 0.15), 0, 1)
        var gain = 350 + (2600 - 350) * (s * s * (3 - 2 * s))
        if precision { gain *= 0.25 }
        let dx = -dYaw * gain * keep * (invertX ? -1 : 1)
        let dy = -dPitch * gain * keep * (invertY ? -1 : 1)
        smoothX += (dx - smoothX) * 0.5
        smoothY += (dy - smoothY) * 0.5
        pendingX += smoothX
        pendingY += smoothY
    }

    // MARK: Output at 120 Hz
    func physicalInputRecent() -> Bool {
        guard now - lastPhysicalInput < 0.8 else { return false }
        pauseReason = lastPhysicalReason
        return true
    }

    func tick() {
        guard active, let cur = CGEvent(source: nil)?.location else { return }
        if physicalInputRecent() {
            pausedTicks += 1
            if !pausedLogged { logLine("paused: \(pauseReason)"); pausedLogged = true }
            pendingX = 0; pendingY = 0; hideRing(); armed = false; anchor = cur; anchorTime = now
            return
        }
        runningTicks += 1
        if pausedLogged { logLine("resumed"); pausedLogged = false }
        if scrolling { scrollTick(); hideRing(); return }

        let stepX = pendingX * 0.3, stepY = pendingY * 0.3
        pendingX -= stepX; pendingY -= stepY
        var p = cur
        if abs(stepX) > 0.05 || abs(stepY) > 0.05 {
            p = confine(CGPoint(x: cur.x + stepX, y: cur.y + stepY), from: cur)
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            postedMoves += 1
        }
        dwellTick(p)
    }

    var now: TimeInterval { Date.timeIntervalSinceReferenceDate }

    func confine(_ p: CGPoint, from cur: CGPoint) -> CGPoint {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &n)
        let rects = ids.prefix(Int(n)).map { CGDisplayBounds($0) }
        if rects.contains(where: { $0.contains(p) }) { return p }
        let home = rects.first(where: { $0.contains(cur) }) ?? rects.first ?? .zero
        return CGPoint(x: clamp(p.x, home.minX, home.maxX - 1), y: clamp(p.y, home.minY, home.maxY - 1))
    }

    func scrollTick() {
        let mag = clamp((abs(roll) - 0.17) / (0.7 - 0.17), 0, 1)
        let speed = 60 + pow(mag, 1.5) * 1800  // points per second
        let dir: Double = (roll > 0 ? -1 : 1) * (invertScroll ? -1 : 1)
        scrollRemainder += dir * speed / 120
        let whole = Int32(scrollRemainder)
        guard whole != 0 else { return }
        scrollRemainder -= Double(whole)
        CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: whole, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }
    var scrollRemainder = 0.0

    func resetAnchor() { if let p = CGEvent(source: nil)?.location { anchor = p; anchorTime = now } }
    func hideRing() { if ring.progress != 0 { ring.progress = 0; ringWindow.orderOut(nil) } }

    // Pause-to-click. It fires once after a deliberate move, then re-arms only after moving away.
    func dwellTick(_ p: CGPoint) {
        guard dwellEnabled else { return }
        let radius: Double = precision ? 5 : 12
        if dist(p, anchor) > radius {
            anchor = p; anchorTime = now; hideRing()
            if dist(p, lastClickPoint) > 30 { armed = true }
            return
        }
        guard armed else { return }
        let held = now - anchorTime
        let progress = clamp((held - 0.2) / 0.8, 0, 1)
        if progress > 0 { showRing(at: p, progress: progress) }
        if progress >= 1 { click(at: p) }
    }

    func showRing(at p: CGPoint, progress: Double) {
        let h = CGDisplayBounds(CGMainDisplayID()).height
        ringWindow.setFrameOrigin(NSPoint(x: p.x - 24, y: h - p.y - 24))
        if !ringWindow.isVisible { ringWindow.orderFrontRegardless() }
        ring.progress = progress
    }

    func click(at p: CGPoint) {
        armed = false; lastClickPoint = p; hideRing()
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventClickState, value: 1)
            e?.post(tap: .cghidEventTap)
        }
        logLine("click at \(Int(p.x)),\(Int(p.y))")
    }

    func heartbeat() {
        if promptingForMotion, CMHeadphoneMotionManager.authorizationStatus() != .notDetermined {
            promptingForMotion = false
            if !active { motion.stopDeviceMotionUpdates() }
            logLine("motion permission answered: \(CMHeadphoneMotionManager.authorizationStatus().rawValue)")
            rebuildMenu()
        }
        guard active else { return }
        // Motion can take over 10s to begin and sometimes needs a new session. Rebuild after 20s of silence.
        let auth = CMHeadphoneMotionManager.authorizationStatus()
        if auth == .authorized, now - max(lastSampleAt, streamStartedAt) > 20 {
            logLine("no motion for 20s: restarting stream")
            ignoreDisconnectUntil = now + 2
            streaming = false
            motion.stopDeviceMotionUpdates()
            startStream()
        } else if streaming && now - lastSampleAt > 2 {
            streaming = false; last = nil
        }
        logLine("motionAuth=\(auth.rawValue)")
        logLine(String(format: "hb samples=%d posted=%d running=%d pausedTicks=%d yaw=%.2f pitch=%.2f roll=%.2f scrolling=%@ precision=%@ dwell=%@ ax=%@ own=%d physical=%d",
                       sampleCount, postedMoves, runningTicks, pausedTicks, yaw, pitch, roll, "\(scrolling)", "\(precision)", "\(dwellEnabled)", "\(AXIsProcessTrusted())", ownEventsSeen, physicalEventsSeen))
        rebuildMenu()
    }
}

// Global hotkeys. Carbon's API needs no extra permission.
var controller: HeadMouse!
let hotkeys: [(UInt32, () -> Void)] = [
    (UInt32(kVK_ANSI_H), { controller.toggleActive() }),
    (UInt32(kVK_ANSI_P), { controller.togglePrecision() }),
    (UInt32(kVK_ANSI_D), { controller.toggleDwell() }),
    (UInt32(kVK_ANSI_R), { controller.recenter() }),
]
func installHotkeys() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        if Int(id.id) < hotkeys.count { hotkeys[Int(id.id)].1() }
        return noErr
    }, 1, &spec, nil, nil)
    for (i, hk) in hotkeys.enumerated() {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hk.0, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x484D5350, id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
        logLine("hotkey \(i) status=\(status)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
controller = HeadMouse()
installHotkeys()
installInputTap()
app.run()
