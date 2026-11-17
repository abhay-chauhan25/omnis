import AppKit
import Carbon.HIToolbox

/// A system-wide key combination. This uses the long-standing hot-key
/// service, which needs no Accessibility or Input Monitoring permission
/// because the app is told only about its own combination, not other keys.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Returns nil if the combination could not be registered (usually
    /// because another app or the system already owns it).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { hotKey.action() }
                return noErr
            },
            1, &eventType, context, &handlerRef
        )
        guard installed == noErr else { return nil }

        let identifier = EventHotKeyID(signature: OSType(0x4F4D_4E53) /* "OMNS" */, id: 1)
        let registered = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr, hotKeyRef != nil else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    static func controlSpace(action: @escaping () -> Void) -> HotKey? {
        HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey), action: action)
    }
}
