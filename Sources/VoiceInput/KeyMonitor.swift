import Cocoa

final class KeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?
    var onFnDoubleTap: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnPressed = false

    private var lastFnDownTime: Double = 0
    private var lastFnUpTime: Double = 0
    private var suppressNextFnUp: Bool = false

    /// Start monitoring. Returns false if accessibility permission is missing.
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        lastFnDownTime = 0
        lastFnUpTime = 0
        suppressNextFnUp = false
    }

    // MARK: - Private

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if the system disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let fnDown = flags.contains(.maskSecondaryFn)

        if fnDown && !fnPressed {
            let now = CACurrentMediaTime()
            let gapBetweenTaps = now - lastFnDownTime
            let prevTapDuration = lastFnUpTime - lastFnDownTime

            if gapBetweenTaps < 0.40 && prevTapDuration > 0 && prevTapDuration < 0.30 {
                // Second tap of a double-tap. Set fnPressed so the paired Fn-up
                // enters the normal branch and records lastFnUpTime correctly.
                fnPressed = true
                suppressNextFnUp = true
                // Do NOT update lastFnDownTime — prevents triple-tap re-triggering.
                DispatchQueue.main.async { [weak self] in self?.onFnDoubleTap?() }
            } else {
                lastFnDownTime = now
                fnPressed = true
                DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
            }
            return nil // suppress Fn press (prevents emoji picker)
        } else if !fnDown && fnPressed {
            let now = CACurrentMediaTime()
            lastFnUpTime = now  // always record for future double-tap detection
            fnPressed = false

            if suppressNextFnUp {
                suppressNextFnUp = false
                return nil  // suppress Fn-up for the second tap; do not fire onFnUp
            }

            DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
            return nil // suppress Fn release
        }

        return Unmanaged.passRetained(event)
    }
}
