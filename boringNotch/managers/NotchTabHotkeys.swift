//
//  NotchTabHotkeys.swift
//  boringNotch
//
//  ⌥1–⌥5 jump straight to a tab while a notch is open. Registered as system
//  hotkeys, and only while a notch is open: the panel can never become key,
//  so a key monitor would need Accessibility permission, whereas a
//  registered hotkey needs none. Option rather than Command so the shortcuts
//  an accidental hover would otherwise steal (browser and terminal tabs)
//  stay untouched.
//

import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class NotchTabHotkeys {
    static let shared = NotchTabHotkeys()

    /// Number-row key codes, in tab order.
    private static let keyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]
    private static let signature: OSType = 0x424E_5448 // 'BNTH'

    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    /// One entry per screen's notch, so closing one while another is still
    /// open doesn't release the keys.
    private var openNotches: Set<ObjectIdentifier> = []

    private init() {}

    func notchOpened(_ owner: AnyObject) {
        openNotches.insert(ObjectIdentifier(owner))
        register()
    }

    func notchClosed(_ owner: AnyObject) {
        openNotches.remove(ObjectIdentifier(owner))
        if openNotches.isEmpty {
            unregister()
        }
    }

    private func register() {
        guard hotKeys.isEmpty else { return }
        installHandler()

        for (index, keyCode) in Self.keyCodes.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            let status = RegisterEventHotKey(UInt32(keyCode), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeys.append(ref)
            }
        }
    }

    private func unregister() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let index = Int(id.id)
            DispatchQueue.main.async {
                NotchTabHotkeys.select(index)
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private static func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        withAnimation(.smooth) {
            BoringViewCoordinator.shared.currentView = tabs[index].view
        }
    }
}
