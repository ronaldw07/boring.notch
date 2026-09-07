//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 16/08/2024.
//

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let clipboardHistoryPanel = Self("clipboardHistoryPanel", default: .init(.c, modifiers: [.shift, .command]))
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5, modifiers: [.function]))
    static let decreaseBacklight = Self("decreaseBacklight", default: .init(.f1, modifiers: [.command]))
    static let increaseBacklight = Self("increaseBacklight", default: .init(.f2, modifiers: [.command]))
    static let toggleSneakPeek = Self("toggleSneakPeek", default: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.i, modifiers: [.command, .shift]))

    // Bare digits, which is only safe because AppDelegate registers these
    // three with the system while a notch is open and unregisters them when
    // the last one closes — otherwise they would swallow every 1, 2 and 3
    // typed anywhere on the machine. Whether the pointer is actually over the
    // panel is then checked at the moment the key is pressed.
    static let showHomeTab = Self("showHomeTab", default: .init(.one))
    static let showShelfTab = Self("showShelfTab", default: .init(.two))
    static let showClipboardTab = Self("showClipboardTab", default: .init(.three))
}
