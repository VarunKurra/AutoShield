import AppKit
import CoreGraphics
import Synchronization

/// A system-wide keyboard tap on its own run loop.
///
/// The callback is on the critical path of every keystroke on the machine, so
/// it does exactly three things: read an atomic mode, compare a key code, and
/// return. Anything slower happens on another queue.
final class EventTap {

    enum Mode: Int32 {
        /// Pass everything through; just watch for the send key.
        case watching = 0
        /// A draft is held. Return, Escape and Command-Delete belong to Shield.
        case holding = 1
        /// Do nothing at all (excluded app, secure field, feature off).
        case idle = 2
    }

    /// Stamped onto events Shield re-posts so the tap ignores its own output.
    static let ourEventMarker: Int64 = 0x5348_4C44  // "SHLD"

    /// Set from the main thread, read from the tap thread. Int32 so the read
    /// is a single aligned load.
    private var modeStorage = ManagedAtomicInt32(.idle)

    /// True when the current draft is over threshold. Written by the scorer,
    /// read by the tap. A cache lookup, never an inference call.
    private var armedStorage = ManagedAtomicInt32(0)

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    /// Called on the main queue. Return true to swallow the event.
    var onSendKey: (() -> Bool)?
    var onHoldAction: ((HoldAction) -> Void)?
    /// Fired when macOS revokes the tap, so the UI can say so.
    var onDisabled: (() -> Void)?

    enum HoldAction { case sendAnyway, edit, delete, typedThrough }

    var mode: Mode {
        get { Mode(rawValue: modeStorage.load()) ?? .idle }
        set { modeStorage.store(newValue.rawValue) }
    }

    var isArmed: Bool {
        get { armedStorage.load() == 1 }
        set { armedStorage.store(newValue ? 1 : 0) }
    }

    private(set) var isRunning = false

    // MARK: Lifecycle

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(proxy: proxy, type: type, event: event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)

        let t = Thread { [weak self] in
            guard let self, let source = self.source else { return }
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
        }
        t.name = "shield.eventtap"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        mode = .idle
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        // The source belongs to the tap thread's run loop, so stopping that
        // run loop is what tears it down; removing it from here would target
        // the wrong loop.
        thread?.cancel()
        if let runLoop { CFRunLoopStop(runLoop) }
        thread = nil
        source = nil
        tap = nil
        runLoop = nil
    }

    // MARK: The hot path

    private static let keyReturn: Int64 = 36
    private static let keyEnter: Int64 = 76      // numeric keypad
    private static let keyEscape: Int64 = 53
    private static let keyDelete: Int64 = 51

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches the tap off if it ever runs long. Turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            DispatchQueue.main.async { [weak self] in self?.onDisabled?() }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // Our own re-posted keystrokes go straight through.
        if event.getIntegerValueField(.eventSourceUserData) == EventTap.ourEventMarker {
            return Unmanaged.passUnretained(event)
        }

        let m = Mode(rawValue: modeStorage.load()) ?? .idle
        guard m != .idle else { return Unmanaged.passUnretained(event) }

        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if m == .holding {
            switch key {
            case EventTap.keyReturn, EventTap.keyEnter:
                dispatch(.sendAnyway)
                return nil
            case EventTap.keyEscape:
                dispatch(.edit)
                return nil
            case EventTap.keyDelete where flags.contains(.maskCommand):
                dispatch(.delete)
                return nil
            default:
                // Typing again is editing. Let the key through and dismiss.
                dispatch(.typedThrough)
                return Unmanaged.passUnretained(event)
            }
        }

        // Watching. Only a plain Return can be a send.
        guard key == EventTap.keyReturn || key == EventTap.keyEnter else {
            return Unmanaged.passUnretained(event)
        }
        // Shift-Return and friends insert a newline; they are not a send.
        if flags.contains(.maskShift) || flags.contains(.maskAlternate) || flags.contains(.maskControl) {
            return Unmanaged.passUnretained(event)
        }
        guard armedStorage.load() == 1 else { return Unmanaged.passUnretained(event) }

        // Armed: swallow now, explain on the main thread.
        DispatchQueue.main.async { [weak self] in _ = self?.onSendKey?() }
        return nil
    }

    private func dispatch(_ action: HoldAction) {
        DispatchQueue.main.async { [weak self] in self?.onHoldAction?(action) }
    }

    // MARK: Synthesising input

    /// Re-posts the Return the user pressed, marked so the tap ignores it.
    static func repostReturn() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        src.userData = ourEventMarker
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyReturn), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyReturn), keyDown: false)
        else { return }
        down.setIntegerValueField(.eventSourceUserData, value: ourEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: ourEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Select-all then delete, for fields that refuse an AX value write.
    static func clearFocusedFieldWithKeys() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        src.userData = ourEventMarker
        let aKey: CGKeyCode = 0
        let deleteKey: CGKeyCode = 51
        func post(_ key: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { return }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: ourEventMarker)
            e.post(tap: .cghidEventTap)
        }
        post(aKey, true, .maskCommand)
        post(aKey, false, .maskCommand)
        post(deleteKey, true, [])
        post(deleteKey, false, [])
    }
}

/// A lock-free int32 the tap thread reads on every keystroke. Taking a lock
/// here would put the watcher thread on the critical path of the keyboard.
final class ManagedAtomicInt32: @unchecked Sendable {
    private let storage: Atomic<Int32>

    init(_ value: Int32) { storage = Atomic(value) }
    convenience init(_ mode: EventTap.Mode) { self.init(mode.rawValue) }

    func load() -> Int32 { storage.load(ordering: .relaxed) }
    func store(_ value: Int32) { storage.store(value, ordering: .relaxed) }
}
