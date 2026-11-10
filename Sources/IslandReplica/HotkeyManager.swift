import AppKit
import Carbon
import Combine

/// Registers only a single explicit global shortcut; does not monitor other keys.
@MainActor final class HotkeyManager: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var message = "未启用"
    private var keyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onActivate: () -> Void
    private let keyID = EventHotKeyID(signature: 0x49534c44, id: 1)

    init(onActivate: @escaping () -> Void) { self.onActivate = onActivate }
    func start() {
        guard keyRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x49534c44, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in manager.onActivate() }
            return noErr
        }
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard handlerStatus == noErr else { message = "无法注册快捷键（\(handlerStatus)）"; return }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_I), UInt32(cmdKey | optionKey), keyID, GetApplicationEventTarget(), 0, &keyRef)
        guard result == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }; handlerRef = nil
            message = "快捷键不可用，可能已被占用（\(result)）"; return
        }
        enabled = true; message = "⌥⌘I 已启用"
    }
    func stop() {
        if let keyRef { UnregisterEventHotKey(keyRef) }; keyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }; handlerRef = nil
        enabled = false; message = "未启用"
    }
}
