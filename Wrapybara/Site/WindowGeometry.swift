import AppKit
import Foundation

/// Where a window was when the app quit, captured well enough to put it back:
/// the frame, the screen it was on, and whether it was full screen.
///
/// The pure half of "reopen where it was". `NSWindow`'s frame autosave covers a
/// single rectangle for the whole app; a session of windows needs one rectangle
/// per window, the full-screen state, and a decision about what to do when the
/// display a window lived on is gone at relaunch. Those decisions live here as
/// values in and values out, so they can be tested without a window — which
/// matters, because "restored onto a screen that no longer exists" is exactly
/// the kind of failure that never shows up on the developer's own machine.
struct WindowGeometry: Codable, Equatable {

    // Stored as bare numbers rather than `NSRect`s: this value travels through
    // `UserDefaults` as JSON, and one key per number is what survives a
    // hand-edit or a file written by a different version.
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var screenX: Double
    var screenY: Double
    var screenWidth: Double
    var screenHeight: Double
    var isFullScreen: Bool

    /// The window's frame as a regular window, in global screen coordinates — the
    /// last frame it had before any full screen. A window quit in full screen is
    /// restored at this size and then sent full screen again; restoring the frame
    /// it happened to have *in* full screen would hand the relaunch a screen-sized
    /// rectangle that nobody ever chose.
    var frame: NSRect {
        NSRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }

    /// The frame of the screen `frame` was on. A screen is identified by its
    /// global frame, which is unique per display in any arrangement.
    var screenFrame: NSRect {
        NSRect(x: CGFloat(screenX), y: CGFloat(screenY),
               width: CGFloat(screenWidth), height: CGFloat(screenHeight))
    }

    init(frame: NSRect, screenFrame: NSRect, isFullScreen: Bool) {
        self.x = Double(frame.minX)
        self.y = Double(frame.minY)
        self.width = Double(frame.width)
        self.height = Double(frame.height)
        self.screenX = Double(screenFrame.minX)
        self.screenY = Double(screenFrame.minY)
        self.screenWidth = Double(screenFrame.width)
        self.screenHeight = Double(screenFrame.height)
        self.isFullScreen = isFullScreen
    }

    /// True when this carries a rectangle worth putting a window at, rather than
    /// the zeros a defaulted decode produces.
    var isUsable: Bool { width > 0 && height > 0 }

    // MARK: Resolving against the screens that exist now

    /// A screen's two rectangles as plain values, so placement can be decided —
    /// and tested — without a live `NSScreen`.
    struct Screen: Equatable {
        var frame: NSRect
        /// The frame minus the menu bar and the Dock: the part a window may occupy.
        var visibleFrame: NSRect
    }

    /// The frame to bring the window back at, given the screens that exist now.
    ///
    /// - The saved screen still exists (same global frame) and the saved frame is
    ///   on it: the saved frame, unchanged — the display arrangement it was saved
    ///   under still holds.
    /// - It doesn't (display unplugged, displays rearranged): the saved size,
    ///   moved whole onto the screen the saved frame overlapped the most — or the
    ///   first screen when it overlapped none — and pulled fully inside that
    ///   screen's *visible* frame. A window restored at the coordinates of a
    ///   missing display would be invisible, and one bigger than its new screen
    ///   unusable; both are prevented here rather than hoped away.
    func resolvedFrame(on screens: [Screen]) -> NSRect {
        guard !screens.isEmpty else { return frame }
        if screens.contains(where: { $0.frame == screenFrame && $0.frame.intersects(frame) }) {
            return frame
        }
        var best = screens[0]
        var bestOverlap: CGFloat = -1
        for candidate in screens {
            let overlap = Self.overlapArea(candidate.frame, frame)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = candidate
            }
        }
        return frame.constrained(to: best.visibleFrame)
    }

    private static func overlapArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case x, y, width, height
        case screenX, screenY, screenWidth, screenHeight
        case isFullScreen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.x = c.value(.x, or: 0)
        self.y = c.value(.y, or: 0)
        self.width = c.value(.width, or: 0)
        self.height = c.value(.height, or: 0)
        self.screenX = c.value(.screenX, or: 0)
        self.screenY = c.value(.screenY, or: 0)
        self.screenWidth = c.value(.screenWidth, or: 0)
        self.screenHeight = c.value(.screenHeight, or: 0)
        self.isFullScreen = c.value(.isFullScreen, or: false)
    }
}

extension WindowGeometry.Screen {
    init(screen: NSScreen) {
        self.init(frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
}

private extension NSRect {
    /// The smallest change that fits `self` inside `visible`: the size clamped,
    /// then the position slid in. The *visible* frame rather than the whole
    /// screen, because the menu bar and the Dock own their edges.
    func constrained(to visible: NSRect) -> NSRect {
        let size = NSSize(width: min(width, visible.width), height: min(height, visible.height))
        return NSRect(x: minX.clamped(to: visible.minX...(visible.maxX - size.width)),
                      y: minY.clamped(to: visible.minY...(visible.maxY - size.height)),
                      width: size.width, height: size.height)
    }
}
