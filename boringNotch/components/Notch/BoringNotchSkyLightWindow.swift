//
//  BoringNotchSkyLightWindow.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-20.
//

import Cocoa
import SkyLightWindow
import Defaults
import Combine

extension SkyLightOperator {
    func undelegateWindow(_ window: NSWindow) {
        typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32
        
        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        guard let SLSRemoveWindowsFromSpaces = unsafeBitCast(
            dlsym(handler, "SLSRemoveWindowsFromSpaces"),
            to: F_SLSRemoveWindowsFromSpaces?.self
        ) else {
            return
        }
        
        // Remove the window from the SkyLight space
        _ = SLSRemoveWindowsFromSpaces(
            connection,
            [window.windowNumber] as CFArray,
            [space] as CFArray
        )
    }
}

class BoringNotchSkyLightWindow: NSPanel {
    private var isSkyLightEnabled: Bool = false
    
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        configureWindow()
        setupObservers()
    }
    
    private func configureWindow() {
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false
        
        // Force dark appearance regardless of system setting
        appearance = NSAppearance(named: .darkAqua)
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        
        // Apply initial sharing type setting
        updateSharingType()
    }
    
    private func setupObservers() {
        // Listen for changes to the hideFromScreenRecording setting
        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in
                self?.updateSharingType()
            }
            .store(in: &observers)
    }
    
    private func updateSharingType() {
        if Defaults[.hideFromScreenRecording] {
            sharingType = .none
        } else {
            sharingType = .readWrite
        }
    }
    
    func enableSkyLight() {
        if !isSkyLightEnabled {
            SkyLightOperator.shared.delegateWindow(self)
            isSkyLightEnabled = true
        }
    }
    
    func disableSkyLight() {
        if isSkyLightEnabled {
            SkyLightOperator.shared.undelegateWindow(self)
            isSkyLightEnabled = false
        }
    }
    
    private var observers: Set<AnyCancellable> = []
    
    /// Off except while a text field in the notch is being edited — a key
    /// window is the only way typing reaches it.
    static var acceptsKeyboardInput = false

    override var canBecomeKey: Bool { Self.acceptsKeyboardInput }
    override var canBecomeMain: Bool { false }
}

/// Lends the notch keyboard focus for the length of one edit, then hands it
/// back to whatever app had it. The panel is non-activating, so the other
/// app stays frontmost the whole time.
@MainActor
enum NotchKeyboardFocus {
    private static var previousApp: NSRunningApplication?

    static func begin() {
        previousApp = NSWorkspace.shared.frontmostApplication
        BoringNotchSkyLightWindow.acceptsKeyboardInput = true
        let mouse = NSEvent.mouseLocation
        NSApp.windows
            .compactMap { $0 as? BoringNotchSkyLightWindow }
            .first { $0.isVisible && $0.frame.contains(mouse) }?
            .makeKey()
    }

    static func end() {
        BoringNotchSkyLightWindow.acceptsKeyboardInput = false
        if NSApp.keyWindow is BoringNotchSkyLightWindow {
            NSApp.keyWindow?.resignKey()
            previousApp?.activate()
        }
        previousApp = nil
    }
}
