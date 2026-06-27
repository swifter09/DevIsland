import AppKit
import Carbon.HIToolbox

/// 全局快捷键：⌘Y 允许 / ⌘N 拒绝当前待批准请求。
///
/// 面板是 .nonactivatingPanel（canBecomeKey=false），拿不到键盘焦点，
/// 所以普通 SwiftUI .keyboardShortcut 不生效。这里用 Carbon RegisterEventHotKey：
/// - 系统级注册，会「消费」按键（不会再漏给当前终端，避免 ⌘N 误触发"新建窗口"）；
/// - 只在有待批准请求时 enable()，请求清空后 disable()，把全局占用窗口压到最小。
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onAllow: (() -> Void)?
    var onDeny: (() -> Void)?

    private var allowRef: EventHotKeyRef?
    private var denyRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var installed = false

    private static let allowID: UInt32 = 1
    private static let denyID: UInt32 = 2
    private static let signature: OSType = 0x4456_4953 // 'DVIS'

    private init() {}

    func enable() {
        guard allowRef == nil, denyRef == nil else { return }   // 已启用
        installHandler()
        allowRef = register(keyCode: UInt32(kVK_ANSI_Y), id: Self.allowID)
        denyRef = register(keyCode: UInt32(kVK_ANSI_N), id: Self.denyID)
    }

    func disable() {
        if let r = allowRef { UnregisterEventHotKey(r); allowRef = nil }
        if let r = denyRef { UnregisterEventHotKey(r); denyRef = nil }
    }

    private func register(keyCode: UInt32, id: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        RegisterEventHotKey(keyCode, UInt32(cmdKey), hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        return ref
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                switch hkID.id {
                case HotKeyManager.allowID: mgr.onAllow?()
                case HotKeyManager.denyID: mgr.onDeny?()
                default: break
                }
            }
            return noErr
        }, 1, &spec, selfPtr, &handler)
    }
}
