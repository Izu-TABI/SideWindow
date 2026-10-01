import Carbon.HIToolbox

/// Carbon のグローバルホットキー。アクセシビリティ権限なしで使える
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        let id = UInt32(HotKey.handlers.count + 1)
        HotKey.handlers[id] = handler
        HotKey.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5450_4E45), id: id) // 'TPNE'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetEventDispatcherTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKey.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
