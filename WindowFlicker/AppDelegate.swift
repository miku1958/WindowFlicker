//
//  AppDelegate.swift
//  WindowFlicker
//
//

import Cocoa

func print(_ item: Any) {
#if DEBUG
    Swift.print(item)
#endif
}

@objc(Application)
class Application: NSApplication {
    override init() {
        super.init()
        self.delegate = AppDelegate.shared
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var draggedWindow: AXUIElement?
    enum Direction {
        case left, right
    }
    private var draggingDirections: [Direction] = []
    private var lastDraggingVelocity: CGPoint?
    private var lastDraggingSize: CGSize?
    private var lastDraggingPosition: CGPoint?
    private var windowOriginalSizeMap: [AXUIElement: CGSize] = [:]
    private func clearDraggingDirections() {
        print("Clearing dragging directions")
        draggingDirections.removeAll()
    }
    private lazy var debounceClearDraggingDirections = DispatchQueue.debounce(delay: 0.3) { [weak self] in
        self?.clearDraggingDirections()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibilityIfNeeded()
        setUpEventTap()
    }
    
    // MARK: Accessibility
    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            fatalError("Accessibility permission is required. Please enable it in System Preferences > Security & Privacy > Privacy > Accessibility.")
        }
    }
    
    // MARK: CGEvent Tap
    private func setUpEventTap() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) |
        (1 << CGEventType.leftMouseDragged.rawValue) |
        (1 << CGEventType.leftMouseUp.rawValue)
        
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                let `self` = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.setUpEventTap()
                    }
                } else {
                    DispatchQueue.main.async {
                        self.handle(event: event, type: type)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())) else {
            fatalError("Unable to create event tap – does the app have the Screen Recording permission?")
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    var windowSize: CGSize? {
        guard let window = draggedWindow else {
            print("windowSize: No window being dragged")
            return nil
        }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value)
        guard let value else {
            print("windowSize: No size attribute found for the dragged window")
            return nil
        }
        var currentSize: CGSize = .zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &currentSize) else {
            print("windowSize: Failed to get size value from AXValue")
            return nil
        }
        print("windowSize: Current size is \(currentSize)")
        return currentSize
    }
    
    var windowPosition: CGPoint? {
        guard let window = draggedWindow else {
            print("windowPosition: No window being dragged")
            return nil
        }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value)
        guard let value else {
            print("windowPosition: No position attribute found for the dragged window")
            return nil
        }
        var currentPoint: CGPoint = .zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &currentPoint) else {
            print("windowPosition: Failed to get position value from AXValue")
            return nil
        }
        print("windowPosition: Current position is \(currentPoint)")
        return currentPoint
    }
    
    private func handle(event: CGEvent, type: CGEventType) {
        switch type {
        case .leftMouseDown:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                let point = carbonScreenPointFromCocoaScreenPoint(mouseLocation: NSEvent.mouseLocation)
                print("Mouse down at: \(point)")
                draggedWindow = windowUnderCursor(x: point.x, y: point.y)
                lastDraggingSize = windowSize
                print("lastDraggingSize = \(String(describing: lastDraggingSize))")
            }
            clearDraggingDirections()
        case .leftMouseUp:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                if let last = lastDraggingVelocity?.x {
                    let endDirection: Direction = last < 0 ? .left : .right
                    print("End direction: \(endDirection)")
                    if endDirection != draggingDirections.last {
                        draggingDirections.append(endDirection)
                        print("Dragging directions added: \(endDirection)")
                    }
                }
                if let window = draggedWindow {
                    snap(window: window, releaseLocation: event.location)
                }
                print("Mouse velocity: —————————————end———————————————————")
                draggedWindow = nil
                clearDraggingDirections()
                lastDraggingVelocity = nil
                lastDraggingSize = nil
                lastDraggingPosition = nil
            }
        default:
            guard let window = draggedWindow else {
                print("No window being dragged")
                return
            }
            guard let windowSize, windowSize == lastDraggingSize else {
                print("Window size has changed or is not available")
                windowOriginalSizeMap[window] = nil
                return
            }
            guard let windowPosition else {
                print("Window position is not available")
                return
            }

            if lastDraggingPosition != nil, lastDraggingPosition != windowPosition {
                if let size = windowOriginalSizeMap[window], windowSize != size {
                    DispatchQueue.main.async { [self] in
                        var position: CGPoint?
                        if windowSize.width != size.width {
                            position = event.location
                            position!.x -= size.width / 2
                        }
                        setSize(size, of: window, to: position)
                        lastDraggingSize = size
                    }
                }
            }
            if lastDraggingPosition != windowPosition {
                lastDraggingPosition = windowPosition
            }
            
            let velocity = CGPoint(
                x: event.getDoubleValueField(.mouseEventDeltaX),
                y: event.getDoubleValueField(.mouseEventDeltaY)
            )
            print("Mouse velocity: \(velocity)")
            
            defer {
                print("lastDraggingVelocity = \(velocity)")
                lastDraggingVelocity = velocity
            }
            
            guard abs(velocity.x) * 2 >= abs(velocity.y) else {
                print("Mouse is not moving horizontally enough")
                return
            }

            guard abs(velocity.x) >= 25 else {
                print("Mouse velocity is too low to determine dragging direction")
                return
            }
            
            debounceClearDraggingDirections()
            
            let direction: Direction = velocity.x < 0 ? .left : .right
            print("current direction: \(direction)")
            
            if direction != draggingDirections.last {
                draggingDirections.append(direction)
                print("Dragging directions added")
            }
        }
    }
    
    private func carbonScreenPointFromCocoaScreenPoint(mouseLocation point: NSPoint) -> CGPoint {
        var foundScreen: NSScreen?
        var targetPoint: CGPoint?
        for screen in NSScreen.screens {
            if NSPointInRect(point, screen.frame) {
                foundScreen = screen
            }
        }
        if let screen = foundScreen {
            let screenHeight = screen.frame.size.height
            targetPoint = CGPoint(x: point.x, y: screenHeight - point.y - 1)
        }
        return targetPoint ?? CGPoint(x: 0.0, y: 0.0)
    }
    
    let systemWideElement = AXUIElementCreateSystemWide()
    // MARK: Window Utilities
    private func windowUnderCursor(x: CGFloat, y: CGFloat) -> AXUIElement? {
        // Accessibility hit‑testing to find the element under the mouse, then ascend until we reach the containing window.

        var hitElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWideElement, Float(x), Float(y), &hitElement)
        if result != .success {
            return nil
        }
        
        // Climb up the hierarchy until we hit a top‑level window (AXWindow role)
        var current: AXUIElement? = hitElement
        while let element = current {
            var roleCF: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleCF) == .success,
               let role = roleCF as? String,
               role == kAXWindowRole as String {
                return element
            }
            var parentCF: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentCF) != .success {
                break
            }
            current = parentCF as! AXUIElement?
        }
        return nil
    }
    
    private var screenFromMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSPointInRect(mouseLocation, $0.frame) }) ?? NSScreen.main
    }
    
    private func snap(window: AXUIElement, releaseLocation: CGPoint) {
        guard let screen = screenFromMouse else { return }
        let screenFrame = screen.visibleFrame
        print("Screen frame: \(screenFrame)")
        let newSize = CGSize(width: screenFrame.width / 2, height: screenFrame.height)
        
        guard draggingDirections.count >= 2 else {
            print("Not enough dragging directions to determine snap direction")
            return
        }

        let direction = draggingDirections.last!
        let isLeftHalf = direction == .left
        
        let newOrigin = CGPoint(x: isLeftHalf ? screenFrame.minX : screenFrame.midX, y: -(screenFrame.minY - NSScreen.screens[0].frame.maxY + screenFrame.height))
        print("newOrigin: \(newOrigin)")
        
        if let windowSize {
            print("Current size: \(windowSize)")
            windowOriginalSizeMap[window] = windowSize
        }
        setSize(newSize, of: window, to: newOrigin)
    }
    
    private func setSize(_ size: CGSize, of window: AXUIElement, to position: CGPoint?) {
        print("set position: \(String(describing: position))")
        if var position {
            let posValue = AXValueCreate(.cgPoint, &position)!
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            print("set size: \(size)")
            var size = size
            let sizeValue = AXValueCreate(.cgSize, &size)!
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }
}

