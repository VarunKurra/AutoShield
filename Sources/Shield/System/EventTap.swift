import AppKit
import CoreGraphics
import Synchronization

/// A system-wide keyboard tap on its own run loop.
///
/// The callback is on the critical path of every keystroke on the machine, so
/// it does very little: read an atomic mode, note the character in the typed
/// buffer, compare a key code, and return. Anything slower happens on another
/// queue. The one exception is a Return that arrives before the watcher has
/// scored the latest keystroke; that gets a synchronous local check, which is
/// about a millisecond, because letting the message through is the worse bug.
final class EventTap {

    enum Mode: Int32 {
        /// Pass everything through; record typing and watch for the send key.
        case watching = 0
        /// A draft is held. The keyboard belongs to Shield until it is resolved.
        case holding = 1
        /// Do nothing at all (excluded app, secure field, feature off).
        case idle = 2
    }

    /// Stamped onto events Shield posts so the tap ignores its own output.
    static let ourEventMarker: Int64 = 0x5348_4C44  // "SHLD"

    private var modeStorage = ManagedAtomicInt32(.idle)

    /// True when the current draft is over threshold. Written by the scorer,
    /// read by the tap. A cache lookup, never an inference call.
    private var armedStorage = ManagedAtomicInt32(0)

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    /// What the person has typed into the frontmost app, keystroke by
    /// keystroke. The fallback for apps whose text Accessibility cannot see.
    let typed = TypedBuffer()

    /// Called on the main queue after the tap swallowed a send key.
    var onSendKey: (() -> Void)?
    var onHoldAction: ((HoldAction) -> Void)?
    /// Fired when macOS revokes the tap, so the UI can say so.
    var onDisabled: (() -> Void)?
    /// Asked on the tap thread when Return arrives unarmed but the typed
    /// buffer has changed since the watcher last scored it. Must be fast.
    var freshCheck: ((String) -> Bool)?

    enum HoldAction: Equatable {
        /// Return: rewrite (and send, if Return is what triggered the hold).
        case primary
        /// Escape: back to the field to fix it by hand.
        case edit
        /// Command-Delete: take the offending words out.
        case remove
        /// Backspace or an arrow key: the person is already fixing it.
        case typedThrough
        /// A printable key while held. Swallowed; the panel nudges.
        case blockedKey
    }

    var mode: Mode {
        get { Mode(rawValue: modeStorage.load()) ?? .idle }
        set { modeStorage.store(newValue.rawValue) }
    }

    var isArmed: Bool {
        get { armedStorage.load() == 1 }
        set { armedStorage.store(newValue ? 1 : 0) }
    }

    private let running = ManagedAtomicInt32(0)
    var isRunning: Bool { running.load() == 1 }

    // MARK: Lifecycle

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)

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
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        source = src

        let t = Thread { [weak self] in
            guard let self, let src else { return }
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
        }
        t.name = "shield.eventtap"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
        running.store(1)
        return true
    }

    func stop() {
        guard isRunning else { return }
        running.store(0)
        mode = .idle
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        // The source belongs to the tap thread's run loop, so stopping that
        // run loop is what tears it down.
        thread?.cancel()
        if let runLoop { CFRunLoopStop(runLoop) }
        thread = nil
        source = nil
        tap = nil
        runLoop = nil
    }

    // MARK: The hot path

    static let keyReturn: Int64 = 36
    static let keyEnter: Int64 = 76      // numeric keypad
    static let keyEscape: Int64 = 53
    static let keyDelete: Int64 = 51
    static let keyForwardDelete: Int64 = 117
    static let keyTab: Int64 = 48
    static let navigationKeys: Set<Int64> = [123, 124, 125, 126, 115, 119, 116, 121]

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches the tap off if it ever runs long. Turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            DispatchQueue.main.async { [weak self] in self?.onDisabled?() }
            return Unmanaged.passUnretained(event)
        }

        // Our own synthetic input goes straight through.
        if event.getIntegerValueField(.eventSourceUserData) == EventTap.ourEventMarker {
            return Unmanaged.passUnretained(event)
        }

        let m = Mode(rawValue: modeStorage.load()) ?? .idle

        if type == .leftMouseDown || type == .rightMouseDown {
            // A click moves the caret or the focus; what was typed before it
            // is no longer a contiguous run ending at the insertion point.
            if m == .watching { typed.breakContinuity() }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        guard m != .idle else { return Unmanaged.passUnretained(event) }

        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let shortcut = flags.contains(.maskCommand) || flags.contains(.maskControl)

        if m == .holding {
            switch key {
            case EventTap.keyReturn, EventTap.keyEnter:
                dispatch(.primary); return nil
            case EventTap.keyEscape:
                dispatch(.edit); return nil
            case EventTap.keyDelete where flags.contains(.maskCommand):
                dispatch(.remove); return nil
            case EventTap.keyDelete, EventTap.keyForwardDelete:
                // Deleting is fixing. Let it through and step aside.
                typed.record(event: event, key: key, flags: flags)
                dispatch(.typedThrough)
                return Unmanaged.passUnretained(event)
            default:
                if shortcut || EventTap.navigationKeys.contains(key) || key == EventTap.keyTab {
                    // Shortcuts (Command-Tab, Command-Z) and navigation pass:
                    // the person is moving, not adding to the message.
                    if EventTap.navigationKeys.contains(key) { dispatch(.typedThrough) }
                    return Unmanaged.passUnretained(event)
                }
                // Typing more onto a held message is not allowed. The key is
                // dropped and the panel says so.
                dispatch(.blockedKey)
                return nil
            }
        }

        // Watching.
        let isSend = (key == EventTap.keyReturn || key == EventTap.keyEnter)
        guard isSend else {
            typed.record(event: event, key: key, flags: flags)
            return Unmanaged.passUnretained(event)
        }
        // Shift-Return and friends insert a newline; they are not a send.
        if flags.contains(.maskShift) || flags.contains(.maskAlternate) || shortcut {
            typed.record(event: event, key: key, flags: flags)
            return Unmanaged.passUnretained(event)
        }

        var hold = armedStorage.load() == 1
        if !hold, let check = freshCheck, let fresh = typed.unscoredText() {
            // The watcher has not seen the last keystrokes yet. Score them now
            // rather than let the message go on a stale verdict.
            hold = check(fresh)
        }
        guard hold else {
            typed.noteSend()
            return Unmanaged.passUnretained(event)
        }

        // Swallow now, explain on the main thread.
        DispatchQueue.main.async { [weak self] in self?.onSendKey?() }
        return nil
    }

    private func dispatch(_ action: HoldAction) {
        DispatchQueue.main.async { [weak self] in self?.onHoldAction?(action) }
    }

    // MARK: Synthesising input

    /// Synthetic input is posted from one serial queue so a rewrite's
    /// backspaces, its text, and the Return that follows always land in order.
    static let synth = DispatchQueue(label: "shield.synth", qos: .userInteractive)

    private static func source() -> CGEventSource? {
        let src = CGEventSource(stateID: .hidSystemState)
        src?.userData = ourEventMarker
        return src
    }

    private static func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags = [], src: CGEventSource) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: ourEventMarker)
        e.post(tap: .cghidEventTap)
    }

    /// Re-posts the Return the user pressed, marked so the tap ignores it.
    static func repostReturn(after delay: TimeInterval = 0.06) {
        synth.asyncAfter(deadline: .now() + delay) {
            guard let src = source() else { return }
            post(CGKeyCode(keyReturn), down: true, src: src)
            post(CGKeyCode(keyReturn), down: false, src: src)
        }
    }

    /// Deletes `count` characters behind the caret, then types `text`.
    /// The universal fallback for fields Accessibility cannot write to.
    static func replaceBehindCaret(deleting count: Int, typing text: String) {
        synth.async {
            guard let src = source() else { return }
            for _ in 0..<max(0, count) {
                post(CGKeyCode(keyDelete), down: true, src: src)
                post(CGKeyCode(keyDelete), down: false, src: src)
                usleep(1_800)
            }
            typeText(text, src: src)
        }
    }

    /// Select-all then type, for single-message fields that refuse an AX write.
    static func replaceAllWithKeys(_ text: String) {
        synth.async {
            guard let src = source() else { return }
            post(0, down: true, flags: .maskCommand, src: src)     // ⌘A
            post(0, down: false, flags: .maskCommand, src: src)
            usleep(20_000)
            post(CGKeyCode(keyDelete), down: true, src: src)
            post(CGKeyCode(keyDelete), down: false, src: src)
            usleep(10_000)
            typeText(text, src: src)
        }
    }

    private static func typeText(_ text: String, src: CGEventSource) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            i += 16
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
            chunk.withUnsafeBufferPointer { p in
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: p.baseAddress)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: p.baseAddress)
            }
            down.setIntegerValueField(.eventSourceUserData, value: ourEventMarker)
            up.setIntegerValueField(.eventSourceUserData, value: ourEventMarker)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(2_500)
        }
    }
}

/// The last few hundred characters typed into the frontmost app.
///
/// Kept in memory only, never written anywhere, and reset whenever the target
/// app changes or the person goes quiet for two minutes. It exists because
/// some of the places people type — Google Docs, canvas editors, games — draw
/// their own text and expose nothing to Accessibility.
final class TypedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chars: [Character] = []
    private var pid: pid_t = 0
    private var lastKeyAt = Date.distantPast
    /// Where the current unbroken run of typing starts. A click or an arrow
    /// key moves the caret somewhere Shield cannot see, so everything before
    /// this index is kept for judging but never edited by keystroke.
    private var segmentStart = 0
    private var selectAllPending = false
    private var version = 0
    private var scoredVersion = 0
    /// Characters added, ever. Deleting never raises it, so "has the person
    /// typed anything new since X" is one comparison.
    private var inserts = 0

    static let limit = 800
    static let idleReset: TimeInterval = 120

    struct Snapshot: Equatable {
        var text: String
        var pid: pid_t
        /// Character offset where the caret-adjacent run of typing begins.
        var segmentStart: Int
        var version: Int
        var lastKeyAt: Date
        var inserts: Int = 0
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(text: String(chars), pid: pid, segmentStart: segmentStart,
                        version: version, lastKeyAt: lastKeyAt, inserts: inserts)
    }

    /// The buffer's text if it changed since the watcher last scored it.
    func unscoredText() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard version != scoredVersion, !chars.isEmpty else { return nil }
        scoredVersion = version
        return String(chars)
    }

    func markScored(_ v: Int) {
        lock.lock(); if v > scoredVersion { scoredVersion = v }; lock.unlock()
    }

    func reset() {
        lock.lock()
        chars.removeAll(keepingCapacity: true)
        segmentStart = 0
        selectAllPending = false
        version += 1
        lock.unlock()
    }

    func breakContinuity() {
        lock.lock(); segmentStart = chars.count; lock.unlock()
    }

    /// A send went through: whatever was typed has left the field.
    func noteSend() { reset() }

    /// Replaces everything from `offset` (in characters) to the end.
    func replaceTail(from offset: Int, with text: String) {
        lock.lock()
        let cut = min(max(0, offset), chars.count)
        chars.removeSubrange(cut...)
        chars.append(contentsOf: text)
        version += 1
        lock.unlock()
    }

    func append(_ s: String, pid target: pid_t) {
        lock.lock()
        if target != pid { chars.removeAll(); pid = target; segmentStart = 0 }
        chars.append(contentsOf: s)
        trim()
        version += 1
        inserts += s.count
        lastKeyAt = Date()
        lock.unlock()
    }

    private func trim() {
        if chars.count > TypedBuffer.limit {
            let drop = chars.count - TypedBuffer.limit
            chars.removeFirst(drop)
            segmentStart = max(0, segmentStart - drop)
        }
    }

    private func clear() {
        chars.removeAll(); segmentStart = 0; version += 1
    }

    /// Deletes behind the caret, but only inside the current run: after a
    /// click Shield does not know what a Backspace removes.
    private func deleteBack(word: Bool) {
        guard chars.count > segmentStart else { return }
        if word {
            while chars.count > segmentStart, let last = chars.last, last.isWhitespace { chars.removeLast() }
            while chars.count > segmentStart, let last = chars.last, !last.isWhitespace { chars.removeLast() }
        } else {
            chars.removeLast()
        }
        version += 1
    }

    /// Called on the tap thread for every keystroke that is not ours.
    func record(event: CGEvent, key: Int64, flags: CGEventFlags) {
        let target = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
        let now = Date()

        lock.lock(); defer { lock.unlock() }

        if target != 0 && target != pid {
            clear(); pid = target; selectAllPending = false
        }
        if now.timeIntervalSince(lastKeyAt) > TypedBuffer.idleReset, !chars.isEmpty {
            clear()
        }

        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            // Shortcuts are not writing. ⌘C on someone else's message must
            // never look like the person just typed it.
            switch key {
            case 0:  selectAllPending = true                     // ⌘A
            case 9:                                              // ⌘V
                DispatchQueue.main.async { [weak self] in
                    guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { return }
                    self?.append(String(s.suffix(TypedBuffer.limit)), pid: target)
                }
            case 6, 7, 16:                                       // ⌘Z ⌘X ⌘Y
                clear()
            case EventTap.keyDelete:                             // ⌘⌫ deletes the line
                clear()
            default: break
            }
            return
        }

        switch key {
        case EventTap.keyDelete:
            lastKeyAt = now
            if selectAllPending { clear(); selectAllPending = false; return }
            deleteBack(word: flags.contains(.maskAlternate))
            return
        case EventTap.keyForwardDelete:
            segmentStart = chars.count
            return
        case EventTap.keyTab:
            clear()
            return
        case EventTap.keyEscape:
            return
        default:
            if EventTap.navigationKeys.contains(key) { segmentStart = chars.count; return }
        }

        var length = 0
        var buf = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buf)
        guard length > 0 else { return }
        let s = String(utf16CodeUnits: buf, count: length)
        let printable = s.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\r" }
        guard printable else { return }
        lastKeyAt = now
        if selectAllPending { chars.removeAll(); segmentStart = 0; selectAllPending = false }
        chars.append(contentsOf: s.replacingOccurrences(of: "\r", with: "\n"))
        trim()
        version += 1
        inserts += 1
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
