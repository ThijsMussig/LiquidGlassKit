//
//  LiquidGlassBridge.swift  –  LiquidGlass
//  Dock + Passcode glass. Reads the enabled pref from Settings.
//

import UIKit
import Darwin

// MARK: - Device capability (adaptive quality)

/// Detects A11 (iPhone X / 8-series) and older as "low-end" for glass-rendering decisions.
private enum DeviceCapability {
    static let isLowEnd: Bool = {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        let model = String(cString: buf)
        // iPhone10,x = A11 (iPhone X / 8). Anything ≤ 10 (major part) is A11 or older.
        if model.hasPrefix("iPhone"),
           let major = model.dropFirst("iPhone".count).split(separator: ",").first.flatMap({ Int($0) }) {
            return major <= 10
        }
        return false
    }()

    /// Tint alpha — reduces compositing pressure on older GPUs.
    static let tintAlpha: CGFloat = isLowEnd ? 0.15 : 0.28

    /// Whether the device runs at 120 Hz (ProMotion).
    static let is120Hz: Bool = UIScreen.main.maximumFramesPerSecond >= 120

    /// Target FPS for the glass display link:
    ///   120 Hz screen → 75 fps (smooth without consuming full ProMotion budget)
    ///    60 Hz screen → 45 fps (above the visual threshold, well within GPU budget)
    static let preferredFPS: Int = is120Hz ? 75 : 45
}

// MARK: - GlassDisplayLink — real-time frame sync for notification + app library glass

/// Drives per-frame frame/cornerRadius synchronisation for registered glass view pairs.
/// Keeps reflections locked to the host view's bounds at display refresh rate instead of
/// relying on layoutSubviews, which fires at a lower and irregular frequency during scrolling.
private final class GlassDisplayLink {
    static let shared = GlassDisplayLink()

    private init() {
        // Stop the display link when the screen turns off or SpringBoard backgrounds — glass
        // views are invisible, there's no point burning CPU/GPU to keep them in sync.
        NotificationCenter.default.addObserver(
            self, selector: #selector(suspend),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(resume),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // Caches last-written values so we never touch a CALayer when nothing changed.
    // Using a struct array instead of a Dictionary<ObjectIdentifier, Entry> is
    // measurably faster in a 60–75 fps hot path (no hash overhead, cache-friendly).
    private struct Entry {
        weak var host:  UIView?
        weak var glass: LiquidGlassEffectView?
        let fallbackR: CGFloat
        var lastBounds: CGRect  = .zero
        var lastR:      CGFloat = 0
    }

    private var entries: [Entry] = []
    private var link: CADisplayLink?
    private var suspended = false

    // Proxy breaks the CADisplayLink ↔ GlassDisplayLink retain cycle.
    private final class Proxy: NSObject {
        weak var owner: GlassDisplayLink?
        @objc func tick() { owner?.tickAll() }
    }

    // MARK: Registration

    func register(host: UIView, glass: LiquidGlassEffectView, fallbackR: CGFloat) {
        // Replace if already registered (e.g. view reused after respring)
        if let idx = entries.firstIndex(where: { $0.host === host }) {
            entries[idx] = Entry(host: host, glass: glass, fallbackR: fallbackR)
        } else {
            entries.append(Entry(host: host, glass: glass, fallbackR: fallbackR))
        }
        if !suspended { ensureLink() }
    }

    func unregister(host: UIView) {
        entries.removeAll { $0.host === host || $0.host == nil }
        if entries.isEmpty { stopLink() }
    }

    // MARK: CADisplayLink lifecycle

    private func ensureLink() {
        guard link == nil else { return }
        let proxy = Proxy()
        proxy.owner = self
        let dl = CADisplayLink(target: proxy, selector: #selector(Proxy.tick))
        let fps = DeviceCapability.preferredFPS
        if #available(iOS 15.0, *) {
            dl.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(fps) * 0.8,
                maximum: Float(fps),
                preferred: Float(fps)
            )
        } else {
            dl.preferredFramesPerSecond = fps
        }
        dl.add(to: .main, forMode: .common)
        link = dl
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func suspend() { suspended = true;  stopLink() }
    @objc private func resume()  { suspended = false; if !entries.isEmpty { ensureLink() } }

    // MARK: Per-frame update — runs at 45 fps (60 Hz) or 75 fps (120 Hz)

    fileprivate func tickAll() {
        guard !entries.isEmpty else { stopLink(); return }

        // One CATransaction for the entire tick — disabling implicit animations removes
        // ~5–15 µs of animation-setup overhead per CALayer write per frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        var i = 0
        while i < entries.count {
            // Dead entry (host or glass was deallocated) — remove and continue.
            guard entries[i].host != nil, entries[i].glass != nil else {
                entries.remove(at: i); continue
            }
            let host = entries[i].host!
            let gv   = entries[i].glass!

            // Remove entries whose host has left the window (e.g. App Library dismissed).
            // They will be re-registered via didMoveToWindow when the view re-appears.
            // Views that still have a window but zero bounds (mid-layout) are kept.
            guard host.window != nil else { entries.remove(at: i); continue }
            guard host.bounds.width > 0 else { i += 1; continue }

            let b = host.bounds
            let r: CGFloat = host.layer.cornerRadius > 0.5 ? host.layer.cornerRadius : entries[i].fallbackR

            // Only write to CALayer when the value actually changed.
            // Even with disableActions, a layer property set marks the layer as needing
            // re-composite on the render server — skipping it is a real win.
            if entries[i].lastBounds != b {
                gv.frame = b
                entries[i].lastBounds = b
            }
            if abs(entries[i].lastR - r) > 0.5 {
                gv.layer.cornerRadius = r
                entries[i].lastR = r
            }
            i += 1
        }

        CATransaction.commit()
        if entries.isEmpty { stopLink() }
    }
}

// MARK: - Preferences
private let kSuite = "com.yourhandle.liquidglass"
private func pref(_ key: String, default def: Bool = true) -> Bool {
    UserDefaults(suiteName: kSuite)?.object(forKey: key) as? Bool ?? def
}
private func isEnabled()       -> Bool { pref("enabled") }
private func isDockEnabled()   -> Bool { isEnabled() && pref("dockEnabled") }
private func isFolderEnabled() -> Bool { isEnabled() && pref("folderEnabled") }
private func isPasscodeEnabled()      -> Bool { isEnabled() && pref("passcodeEnabled") }
private func isSwitchEnabled() -> Bool { isEnabled() && pref("switchEnabled") }
private func isSliderEnabled()        -> Bool { isEnabled() && pref("sliderEnabled") }
private func isNotificationEnabled()  -> Bool { isEnabled() && pref("notificationEnabled") }
private func isMediaPlayerEnabled()   -> Bool { isEnabled() && pref("mediaPlayerEnabled") }
private func isSearchBarEnabled()          -> Bool { isEnabled() && pref("searchBarEnabled") }
private func isLibrarySuggestionsEnabled() -> Bool { isEnabled() && pref("librarySuggestionsEnabled") }
private func isSpotlightSearchEnabled()    -> Bool { isEnabled() && pref("spotlightSearchEnabled") }
private func isQuickActionEnabled()        -> Bool { isEnabled() && pref("quickActionEnabled") }
private func isBannerEnabled()             -> Bool { isEnabled() && pref("bannerEnabled") }

// MARK: - Associated object keys
private enum K {
    static var gv: UInt8 = 0   // dock glass view
    static var pb: UInt8 = 0   // passcode button glass view
    static var fi: UInt8 = 0   // folder icon glass view
    static var fo: UInt8 = 0   // open folder background glass
    static var nc: UInt8 = 0   // notification cell glass view
    static var mp: UInt8 = 0   // media player glass view
    static var sb: UInt8 = 0   // search bar glass view
    static var ls: UInt8 = 0   // App Library suggestions glass view
    static var ss: UInt8 = 0   // Spotlight search pill glass view
    static var qa: UInt8 = 0   // Lock screen quick action glass view
    static var bn: UInt8 = 0   // Banner notification glass view
}

private func storedGlassView(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.gv) as? LiquidGlassEffectView
}
private func storeGlassView(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.gv, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

// MARK: - Helpers

// Check if a view has any icon-related descendants (we must never hide those)
private func hasIconDescendants(_ view: UIView) -> Bool {
    for sub in view.subviews {
        let n = String(describing: type(of: sub))
        if n.contains("Icon") || n.contains("SBApp") { return true }
        if hasIconDescendants(sub) { return true }
    }
    return false
}

// Recursively strip all dock material while preserving icon views.
// Rule: if a subview has icon descendants → clear its bg and recurse.
//        if it has no icon descendants → hide it entirely (it's pure decoration).
private func hideBackgrounds(in view: UIView) {
    for sub in view.subviews {
        let n = String(describing: type(of: sub))

        // Never touch icon views themselves
        if n.contains("Icon") || n.contains("Badge") || n.contains("SBApp") { continue }

        // UIVisualEffectView: nulling the effect makes it fully transparent
        if let vev = sub as? UIVisualEffectView {
            vev.effect = nil
            vev.backgroundColor = .clear
            continue
        }

        if hasIconDescendants(sub) {
            // Container holds icons — clear its fill but keep it visible and recurse
            sub.backgroundColor = .clear
            sub.layer.backgroundColor = UIColor.clear.cgColor
            hideBackgrounds(in: sub)
        } else {
            // Pure decoration (blur, highlight, shadow, background pill, etc.) — hide it
            sub.isHidden = true
        }
    }
}

private func showBackgrounds(in view: UIView) {
    for sub in view.subviews {
        sub.isHidden = false
        if let vev = sub as? UIVisualEffectView {
            vev.effect = UIBlurEffect(style: .systemMaterial)
        }
        showBackgrounds(in: sub)
    }
}

// Find the frame for the glass pill — use the dock's first background subview frame,
// or fall back to the dock bounds inset to match typical dock pill proportions.
private func backgroundPillFrame(in view: UIView) -> CGRect? {
    // Look for a platter/background subview that was previously visible
    for sub in view.subviews {
        let n = String(describing: type(of: sub))
        if n.contains("Platter") || n.contains("Background") {
            // Use its frame even though we've hidden it — the frame is still valid
            return sub.frame
        }
    }
    return nil
}

// MARK: - App Library Suggestions row (_SBHLibrarySuggestionsView)
// The full-width rounded card at the top of App Library showing 4 recent/suggested apps.

private func storedSuggestionsGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.ls) as? LiquidGlassEffectView
}
private func storeSuggestionsGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.ls, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyToLibrarySuggestions")
public func applyToLibrarySuggestions(_ view: UIView) {
    guard isLibrarySuggestionsEnabled(), view.bounds.width > 0 else { return }

    // Fast path — GlassDisplayLink owns frame + cornerRadius sync at display refresh rate.
    if let gv = storedSuggestionsGlass(for: view) {
        if gv.isHidden { gv.isHidden = false }
        if view.subviews.first !== gv { view.sendSubviewToBack(gv) }
        return
    }

    // ---- First-time setup (runs once per view instance) ----
    let fallbackR = view.bounds.height * 0.18
    let r = view.layer.cornerRadius > 0.5 ? view.layer.cornerRadius : fallbackR

    view.backgroundColor = .clear
    view.layer.backgroundColor = UIColor.clear.cgColor

    let effect = LiquidGlassEffect(style: .clear, isNative: false)
    effect.tintColor = UIColor.white.withAlphaComponent(DeviceCapability.tintAlpha)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = view.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = r
    gv.layer.cornerCurve = .continuous
    gv.clipsToBounds = true
    view.insertSubview(gv, at: 0)
    storeSuggestionsGlass(gv, for: view)
    let glassLayer = gv.layer

    // Strip background fill layers — once only, never repeated
    for sublayer in view.layer.sublayers ?? [] {
        if sublayer === glassLayer { continue }
        if sublayer.contents != nil { continue }
        guard let bg = sublayer.backgroundColor, bg.alpha > 0.01 else { continue }
        sublayer.isHidden = true
        sublayer.backgroundColor = UIColor.clear.cgColor
    }
    killBackdropLayers(in: view.layer, skipping: glassLayer)

    for sub in view.subviews {
        if sub === gv { continue }
        if sub is UIImageView || sub is UILabel { continue }
        if let vev = sub as? UIVisualEffectView { vev.effect = nil; vev.backgroundColor = .clear; continue }
        let n = String(describing: type(of: sub))
        if n.contains("Background") || n.contains("Backdrop") || n.contains("Shadow") ||
           n.contains("Material") || n.contains("Tint") {
            sub.isHidden = true
            killBackdropLayers(in: sub.layer)
        }
    }

    // Hand off to the display link for real-time 60 fps frame + corner sync
    GlassDisplayLink.shared.register(host: view, glass: gv, fallbackR: fallbackR)
}

// MARK: - Home screen Spotlight search pill (SBSearchBarTextField)

private func storedSpotlightSearchGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.ss) as? LiquidGlassEffectView
}
private func storeSpotlightSearchGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.ss, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyToSpotlightSearch")
public func applyToSpotlightSearch(_ textField: UIView) {
    guard isSpotlightSearchEnabled(), textField.bounds.width > 0 else { return }
    guard let parent = textField.superview else { return }

    let frameInParent = textField.convert(textField.bounds, to: parent)
    guard frameInParent.width > 0 else { return }
    let cornerR: CGFloat = frameInParent.height / 2

    // Sync existing glass — cheap path, runs every layoutSubviews
    if let gv = storedSpotlightSearchGlass(for: textField) {
        if gv.frame != frameInParent { gv.frame = frameInParent }
        if gv.layer.cornerRadius != cornerR { gv.layer.cornerRadius = cornerR }
        return
    }

    // ---- First-time setup only from here ----
    textField.backgroundColor = .clear
    textField.layer.backgroundColor = UIColor.clear.cgColor
    if let tf = textField as? UITextField {
        tf.borderStyle = .none
        tf.background = nil
    }
    for sub in textField.subviews {
        guard !(sub is LiquidGlassEffectView) else { continue }
        let n = String(describing: type(of: sub))
        if n.contains("Background") || n.contains("Backdrop") || n.contains("Material") ||
           n.contains("RoundedRect") || n.contains("Border") {
            sub.isHidden = true
        }
        if let vev = sub as? UIVisualEffectView { vev.effect = nil; vev.backgroundColor = .clear }
    }

    // Defer creation so the view hierarchy is fully laid out before we snapshot the frame.
    DispatchQueue.main.async {
        guard textField.window != nil,
              let parent = textField.superview,
              storedSpotlightSearchGlass(for: textField) == nil else { return }
        let frame = textField.convert(textField.bounds, to: parent)
        guard frame.width > 0 else { return }
        let cornerR: CGFloat = frame.height / 2
        let effect = LiquidGlassEffect(style: .clear, isNative: false)
        effect.tintColor = UIColor.white.withAlphaComponent(DeviceCapability.tintAlpha)
        let gv = LiquidGlassEffectView(effect: effect)
        gv.frame = frame
        gv.isUserInteractionEnabled = false
        gv.layer.cornerRadius = cornerR
        gv.layer.cornerCurve = .continuous
        gv.clipsToBounds = false
        if let idx = parent.subviews.firstIndex(of: textField) {
            parent.insertSubview(gv, at: idx)
        } else {
            parent.addSubview(gv)
        }
        storeSpotlightSearchGlass(gv, for: textField)
    }
}

// MARK: - Search bar (App Library SBHSearchTextField)

private func storedSearchBarGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.sb) as? LiquidGlassEffectView
}
private func storeSearchBarGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.sb, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyToSearchBar")
public func applyToSearchBar(_ textField: UIView) {
    guard isSearchBarEnabled(), textField.bounds.width > 0 else { return }
    guard let parent = textField.superview else { return }

    // Convert text field frame to parent coords
    let frameInParent = textField.convert(textField.bounds, to: parent)
    guard frameInParent.width > 0 else { return }
    let cornerR: CGFloat = frameInParent.height / 2

    // Sync existing glass — cheap path, runs every layoutSubviews
    if let gv = storedSearchBarGlass(for: textField) {
        if gv.frame != frameInParent { gv.frame = frameInParent }
        if gv.layer.cornerRadius != cornerR { gv.layer.cornerRadius = cornerR }
        return
    }

    // ---- First-time setup only from here ----
    // Make the UITextField itself fully transparent
    textField.backgroundColor = .clear
    textField.layer.backgroundColor = UIColor.clear.cgColor
    if let tf = textField as? UITextField {
        tf.borderStyle = .none
        tf.background = nil
    }
    // Hide background-drawing subviews (once)
    for sub in textField.subviews {
        guard !(sub is LiquidGlassEffectView) else { continue }
        let n = String(describing: type(of: sub))
        if n.contains("Background") || n.contains("Backdrop") || n.contains("RoundedRect") || n.contains("Border") {
            sub.isHidden = true
        }
        if let vev = sub as? UIVisualEffectView { vev.effect = nil; vev.backgroundColor = .clear }
    }

    // Defer initial glass creation to the next run loop so the view hierarchy
    // is fully laid out — prevents the glass appearing at the wrong (pre-layout)
    // position during respring and then jumping to the correct place.
    DispatchQueue.main.async {
        guard textField.window != nil,
              let parent = textField.superview,
              storedSearchBarGlass(for: textField) == nil else { return }
        let frame = textField.convert(textField.bounds, to: parent)
        guard frame.width > 0 else { return }
        let cornerR: CGFloat = frame.height / 2
        let effect = LiquidGlassEffect(style: .clear, isNative: false)
        effect.tintColor = UIColor.white.withAlphaComponent(0.28)
        let gv = LiquidGlassEffectView(effect: effect)
        gv.frame = frame
        gv.isUserInteractionEnabled = false
        gv.layer.cornerRadius = cornerR
        gv.layer.cornerCurve = .continuous
        gv.clipsToBounds = false
        if let idx = parent.subviews.firstIndex(of: textField) {
            parent.insertSubview(gv, at: idx)
        } else {
            parent.addSubview(gv)
        }
        storeSearchBarGlass(gv, for: textField)
    }
}

// MARK: - Dock

@_silgen_name("LGApplyToDockView")
public func applyToDockView(_ dock: UIView) {
    let on = isDockEnabled()

    // Always re-strip the material — iOS restores it between layoutSubviews calls
    if on {
        hideBackgrounds(in: dock)
        dock.backgroundColor = .clear
    }

    // Already set up — just sync frame
    if let gv = storedGlassView(for: dock) {
        if on {
            gv.isHidden = false
            let syncInset = dock.bounds.insetBy(dx: 10, dy: 6)
            let maxPillHeight: CGFloat = 83
            let syncFallback = syncInset.height > maxPillHeight
                ? CGRect(x: syncInset.minX, y: syncInset.minY, width: syncInset.width, height: maxPillHeight)
                : syncInset
            let pillFrame = backgroundPillFrame(in: dock) ?? syncFallback
            gv.frame = pillFrame
            gv.layer.cornerRadius = min(pillFrame.height, pillFrame.width) * 0.35
        } else {
            gv.isHidden = true
            showBackgrounds(in: dock)
        }
        return
    }

    guard on, dock.bounds.width > 0 else { return }

    // Use the background pill's frame if found, otherwise inset the full bounds.
    // Cap fallback height to ~83 pt so the glass pill isn't over-tall on iPhone X/newer
    // where SBDockView includes extra padding below the pill for the home indicator.
    let fallbackFrame: CGRect = {
        let inset = dock.bounds.insetBy(dx: 10, dy: 6)
        let maxPillHeight: CGFloat = 83
        if inset.height > maxPillHeight {
            let clipped = CGRect(x: inset.minX, y: inset.minY,
                                 width: inset.width, height: maxPillHeight)
            return clipped
        }
        return inset
    }()
    let pillFrame = backgroundPillFrame(in: dock) ?? fallbackFrame

    // .clear: same refraction/glare as regular, tintColor nil → materialTint stays .zero (no color)
    let effect = LiquidGlassEffect(style: .clear, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = pillFrame
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = min(pillFrame.height, pillFrame.width) * 0.44
    gv.layer.cornerCurve  = .continuous
    gv.clipsToBounds = false
    dock.insertSubview(gv, at: 0)
    storeGlassView(gv, for: dock)
}

// MARK: - Lock screen quick action buttons (flashlight / camera)

private func storedQuickActionGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.qa) as? LiquidGlassEffectView
}
private func storeQuickActionGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.qa, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyToLockQuickAction")
public func applyToLockQuickAction(_ btn: UIView) {
    guard isQuickActionEnabled(), btn.bounds.width > 0 else { return }

    // Fast path — glass already installed; sync frame + keep clear.
    if let gv = storedQuickActionGlass(for: btn) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        btn.backgroundColor = .clear
        btn.layer.backgroundColor = UIColor.clear.cgColor
        gv.frame = btn.bounds
        gv.layer.cornerRadius = btn.bounds.width * 0.5
        // Re-hide every non-glass subview every pass — iOS restores them.
        // Skip UIImageViews so the icon stays visible.
        for sub in btn.subviews where sub !== gv && !(sub is UIImageView) {
            sub.isHidden = true
            sub.alpha = 0
            sub.layer.opacity = 0
            killBackdropLayers(in: sub.layer)
        }
        // Ensure icon image views remain visible and on top.
        for sub in btn.subviews where sub is UIImageView {
            sub.isHidden = false
            sub.alpha = 1
            sub.layer.opacity = 1
            btn.bringSubviewToFront(sub)
        }
        // Kill any plain fill sublayers (not our metal layer).
        for sublayer in btn.layer.sublayers ?? [] {
            if sublayer === gv.layer { continue }
            if sublayer.contents != nil { continue }
            sublayer.backgroundColor = UIColor.clear.cgColor
            sublayer.opacity = 0
        }
        CATransaction.commit()
        return
    }

    // ---- First-time setup ----
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    // Aggressively clear everything on the button view.
    btn.backgroundColor = .clear
    btn.layer.backgroundColor = UIColor.clear.cgColor
    // Hide ALL subviews — the only things inside a quick action button are the
    // material circle and the icon image view. The icon is a UIImageView so we
    // re-show it after inserting the glass below.
    for sub in btn.subviews {
        sub.isHidden = true
        sub.alpha = 0
        sub.layer.opacity = 0
        killBackdropLayers(in: sub.layer)
    }
    // Kill fill sublayers.
    for sublayer in btn.layer.sublayers ?? [] {
        if sublayer.contents != nil { continue }
        sublayer.backgroundColor = UIColor.clear.cgColor
        sublayer.opacity = 0
    }
    killBackdropLayers(in: btn.layer)

    let effect = LiquidGlassEffect(style: .clear, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = btn.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = btn.bounds.width * 0.5
    gv.layer.cornerCurve  = .continuous
    gv.clipsToBounds = false
    btn.insertSubview(gv, at: 0)
    storeQuickActionGlass(gv, for: btn)

    // Bring icon views back to front so they render above glass.
    for sub in btn.subviews where sub !== gv {
        if sub is UIImageView {
            sub.isHidden = false
            sub.alpha = 1
            sub.layer.opacity = 1
            btn.bringSubviewToFront(sub)
        }
    }

    CATransaction.commit()
}

// MARK: - Passcode button

private func storedButtonGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.pb) as? LiquidGlassEffectView
}
private func storeButtonGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.pb, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

// Strip all visual material from a passcode button including CALayer-based circle fills.
private func stripButtonMaterial(in view: UIView) {
    // Clear any shape/fill layers that draw the button circle
    for sublayer in view.layer.sublayers ?? [] {
        if let shape = sublayer as? CAShapeLayer {
            shape.fillColor = UIColor.clear.cgColor
            shape.strokeColor = UIColor.clear.cgColor
            shape.backgroundColor = UIColor.clear.cgColor
        } else {
            sublayer.backgroundColor = UIColor.clear.cgColor
        }
    }
    // Clear view-level fills
    view.backgroundColor = .clear
    view.layer.backgroundColor = UIColor.clear.cgColor
    // Recurse into subviews
    for sub in view.subviews {
        if let vev = sub as? UIVisualEffectView {
            vev.effect = nil
            vev.backgroundColor = .clear
        } else {
            let n = String(describing: type(of: sub))
            if n.contains("Background") || n.contains("Backdrop") || n.contains("Shadow") {
                sub.isHidden = true
            } else {
                stripButtonMaterial(in: sub)
            }
        }
    }
}

@_silgen_name("LGApplyToPasscodeButton")
public func applyToPasscodeButton(_ btn: UIView) {
    guard isPasscodeEnabled(), btn.bounds.width > 0 else { return }

    // Fast path — glass already installed; sync frame only.
    // Do NOT call stripButtonMaterial here: it recurses through all subviews and
    // modifies CALayer properties while SpringBoard's dismiss animation is running,
    // which triggers a render-server assertion → safe mode.
    if let gv = storedButtonGlass(for: btn) {
        btn.backgroundColor = .clear
        btn.layer.backgroundColor = UIColor.clear.cgColor
        gv.frame = btn.bounds
        gv.layer.cornerRadius = btn.bounds.width * 0.5
        return
    }

    // First-time setup only — strip material once, then add glass.
    stripButtonMaterial(in: btn)
    btn.backgroundColor = .clear

    let effect = LiquidGlassEffect(style: .clear, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = btn.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    // Passcode buttons are circular
    gv.layer.cornerRadius = btn.bounds.width * 0.5
    gv.layer.cornerCurve  = .continuous
    gv.clipsToBounds = false
    btn.insertSubview(gv, at: 0)
    storeButtonGlass(gv, for: btn)
}

// MARK: - Folder icon (SBFolderIconImageView — the 60×60 rounded-rect grid view)

private func storedFolderIconGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.fi) as? LiquidGlassEffectView
}
private func storeFolderIconGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.fi, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

// MARK: - Open folder background (SBFolderBackgroundView)

private func storedOpenFolderGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.fo) as? LiquidGlassEffectView
}
private func storeOpenFolderGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.fo, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

/// Disable CABackdropLayer compositing recursively — needed because it renders at server level.
/// Pass skipLayer to protect a specific layer subtree (e.g. our glass view's backdrop).
private func killBackdropLayers(in layer: CALayer, skipping skipLayer: CALayer? = nil) {
    let backdropClass: AnyClass? = NSClassFromString("CABackdropLayer")
    for sub in layer.sublayers ?? [] {
        if let sl = skipLayer, sub === sl { continue }
        if let bc = backdropClass, sub.isKind(of: bc) {
            sub.setValue(false, forKey: "enabled")
            sub.opacity = 0
        }
        killBackdropLayers(in: sub, skipping: skipLayer)
    }
}

/// Walk a layer tree and set enabled=YES on all CABackdropLayers.
private func enableBackdropLayers(in layer: CALayer) {
    let backdropClass: AnyClass? = NSClassFromString("CABackdropLayer")
    for sub in layer.sublayers ?? [] {
        if let bc = backdropClass, sub.isKind(of: bc) {
            sub.setValue(true, forKey: "enabled")
            sub.opacity = 1
        }
        enableBackdropLayers(in: sub)
    }
}

/// Hide the glass immediately and schedule a reveal — call this every time the folder is about to open.
@_silgen_name("LGHideFolderGlass")
public func hideFolderGlass(_ view: UIView) {
    guard let gv = storedOpenFolderGlass(for: view) else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gv.isHidden = true
    killBackdropLayers(in: gv.layer)
    CATransaction.commit()
    deferFolderGlass(gv)
}

/// Keep the glass view fully hidden from the compositor while the folder animates.
/// isHidden=true removes it from the layer tree entirely — CABackdropLayer does zero work.
private func deferFolderGlass(_ gv: LiquidGlassEffectView) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
        // Re-enable backdrop layers against the now-stable background.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        enableBackdropLayers(in: gv.layer)
        CATransaction.commit()
        // One runloop pass so the compositor has captured a clean frame.
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gv.isHidden = false
            CATransaction.commit()
        }
    }
}

@_silgen_name("LGApplyToFolderBackground")
public func applyToFolderBackground(_ view: UIView) {
    guard isFolderEnabled(), view.bounds.width > 0 else { return }

    let r = max(view.layer.cornerRadius > 0 ? view.layer.cornerRadius : 0, 36)

    if let gv = storedOpenFolderGlass(for: view) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gv.frame = view.bounds
        gv.layer.cornerRadius = r
        CATransaction.commit()
        // Always defer — willMoveToWindow:newWindow hides it before every open.
        if gv.isHidden {
            deferFolderGlass(gv)
        }
        return
    }

    // First-time setup: clear background, kill blur subviews, insert glass.
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    view.backgroundColor = .clear
    view.layer.backgroundColor = UIColor.clear.cgColor

    for sub in view.subviews {
        sub.isHidden = true
        sub.layer.opacity = 0
        killBackdropLayers(in: sub.layer)
    }
    killBackdropLayers(in: view.layer)

    let effect = LiquidGlassEffect(style: .clear, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = view.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = r
    gv.layer.cornerCurve  = .continuous
    gv.clipsToBounds = true   // prevent refraction bleeding outside = black ring
    // Start fully hidden — removed from compositor, CABackdropLayer does no work.
    gv.isHidden = true
    killBackdropLayers(in: gv.layer)
    view.insertSubview(gv, at: 0)
    storeOpenFolderGlass(gv, for: view)

    CATransaction.commit()

    deferFolderGlass(gv)
}

@_silgen_name("LGApplyToFolderIcon")
public func applyToFolderIcon(_ view: UIView) {
    guard isFolderEnabled(), view.bounds.width > 0 else { return }

    // Clear view-level background color
    view.backgroundColor = .clear
    view.layer.backgroundColor = UIColor.clear.cgColor

    // Sync or create glass view
    let glassLayer: CALayer
    let r = view.layer.cornerRadius > 0 ? view.layer.cornerRadius : view.bounds.width * 0.22
    if let gv = storedFolderIconGlass(for: view) {
        gv.isHidden = false
        gv.frame = view.bounds
        gv.layer.cornerRadius = r
        view.sendSubviewToBack(gv)
        glassLayer = gv.layer
    } else {
        let effect = LiquidGlassEffect(style: .clear, isNative: false)
        let gv = LiquidGlassEffectView(effect: effect)
        gv.frame = view.bounds
        gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gv.isUserInteractionEnabled = false
        gv.layer.cornerRadius = r
        gv.layer.cornerCurve  = .continuous
        gv.clipsToBounds = true
        view.insertSubview(gv, at: 0)
        storeFolderIconGlass(gv, for: view)
        glassLayer = gv.layer
    }

    // Hide background CALayers. The grey fill layer has an explicit backgroundColor
    // set on it; icon draw layers have backgroundColor == nil (they render via display
    // callback). So only hide layers that have a visible, non-clear backgroundColor.
    for sublayer in view.layer.sublayers ?? [] {
        if sublayer === glassLayer { continue }
        if sublayer.contents != nil { continue }
        guard let bg = sublayer.backgroundColor, bg.alpha > 0.01 else { continue }
        sublayer.isHidden = true
        sublayer.backgroundColor = UIColor.clear.cgColor
    }

    // Hide any background subviews
    for sub in view.subviews {
        if let gv = storedFolderIconGlass(for: view), sub === gv { continue }
        if sub is UIImageView || sub is UILabel { continue }
        if let vev = sub as? UIVisualEffectView { vev.effect = nil; vev.backgroundColor = .clear; continue }
        let n = String(describing: type(of: sub))
        if n.contains("Background") || n.contains("Backdrop") || n.contains("Shadow") || n.contains("Material") {
            sub.isHidden = true
        }
    }
}

// MARK: - Lock screen media player (CSAdjunctItemView / MPUSystemMediaControlsView)

private func storedMediaPlayerGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.mp) as? LiquidGlassEffectView
}
private func storeMediaPlayerGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.mp, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

/// Recursively strip all blur/tint/material views and clear backgrounds.
/// glassView: our LiquidGlassEffectView — skipped entirely so its own CABackdropLayer is never killed.
private func stripMediaPlayerBackground(in view: UIView, glassView: UIView?) {
    if let gv = glassView, view === gv { return }
    view.backgroundColor = .clear
    view.layer.backgroundColor = UIColor.clear.cgColor
    view.layer.borderWidth = 0
    // Kill backdrop layers, but SKIP the glass view's layer subtree so we don't disable our own glass.
    let skipLayer = glassView?.layer
    killBackdropLayers(in: view.layer, skipping: skipLayer)
    for sub in view.subviews {
        if let gv = glassView, sub === gv { continue }
        if let vev = sub as? UIVisualEffectView {
            vev.effect = nil
            vev.backgroundColor = .clear
            vev.isHidden = true
            killBackdropLayers(in: vev.layer, skipping: skipLayer)
            continue
        }
        let n = String(describing: type(of: sub))
        if n.contains("Backdrop") || n.contains("Background") ||
           n.contains("Tint") || n.contains("Material") || n.contains("Shadow") {
            sub.isHidden = true
            killBackdropLayers(in: sub.layer, skipping: skipLayer)
            continue
        }
        // Preserve actual content (buttons, labels, images, sliders, artwork)
        sub.backgroundColor = .clear
        sub.layer.backgroundColor = UIColor.clear.cgColor
        sub.layer.borderWidth = 0
        killBackdropLayers(in: sub.layer, skipping: skipLayer)
        stripMediaPlayerBackground(in: sub, glassView: glassView)
    }
}

@_silgen_name("LGApplyToMediaPlayer")
public func applyToMediaPlayer(_ view: UIView) {
    guard isMediaPlayerEnabled(), view.bounds.width > 0 else { return }

    let r: CGFloat = {
        let cl = view.layer.cornerRadius
        return cl > 1 ? cl : 26
    }()

    // Fast path: already set up — sync frame + shallow strip without killing backdrop layers.
    // IMPORTANT: do NOT call killBackdropLayers here — it walks the CALayer tree regardless
    // of view guards, and would disable the glass view's own CABackdropLayer every layout pass.
    if let gv = storedMediaPlayerGlass(for: view) {
        gv.isHidden = false
        gv.frame = view.bounds
        gv.layer.cornerRadius = r
        // Shallow strip: clear the container and its direct children only.
        view.backgroundColor = .clear
        view.layer.backgroundColor = UIColor.clear.cgColor
        view.layer.borderWidth = 0
        for sub in view.subviews {
            if sub === gv { continue }
            if let vev = sub as? UIVisualEffectView { vev.effect = nil; vev.isHidden = true; continue }
            let n = String(describing: type(of: sub))
            if n.contains("Backdrop") || n.contains("Background") ||
               n.contains("Tint") || n.contains("Material") || n.contains("Shadow") {
                sub.isHidden = true; continue
            }
            sub.backgroundColor = .clear
            sub.layer.backgroundColor = UIColor.clear.cgColor
            sub.layer.borderWidth = 0
        }
        view.sendSubviewToBack(gv)
        return
    }

    // First-time setup: strip backgrounds then add glass.
    stripMediaPlayerBackground(in: view, glassView: nil)

    let effect = LiquidGlassEffect(style: .clearBlur, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = view.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = r
    gv.layer.cornerCurve = .continuous
    gv.clipsToBounds = false
    view.insertSubview(gv, at: 0)
    storeMediaPlayerGlass(gv, for: view)
}

/// Strip-only for inner control views (MPUSystemMediaControlsView etc.).
/// Does NOT add a glass view — the outer CSAdjunctItemView owns the single glass layer.
/// Fully recursive so grandchild backgrounds restored by UIKit are also caught.
@_silgen_name("LGStripMediaPlayerControls")
public func stripMediaPlayerControls(_ view: UIView) {
    guard isMediaPlayerEnabled() else { return }
    stripMediaPlayerBackground(in: view, glassView: nil)
}

// MARK: - Banner notification (NCNotificationShortLookView)

private func storedBannerGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.bn) as? LiquidGlassEffectView
}
private func storeBannerGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.bn, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyToBanner")
public func applyToBanner(_ banner: UIView) {
    guard isBannerEnabled(), banner.bounds.width > 0 else { return }

    // On the lock screen, NCNotificationShortLookView is a subview of NCNotificationListCell.
    // That outer cell already gets glassed by applyToNotificationCell — skip here to avoid
    // double glass.
    let cellClass: AnyClass? = NSClassFromString("NCNotificationListCell")
    if let cc = cellClass {
        var ancestor = banner.superview
        while let a = ancestor {
            if a.isKind(of: cc) { return }
            ancestor = a.superview
        }
    }

    // Fast path — glass already installed.
    if let gv = storedBannerGlass(for: banner) {
        if gv.isHidden { gv.isHidden = false }
        if banner.subviews.first !== gv { banner.sendSubviewToBack(gv) }
        return
    }

    let r: CGFloat = {
        let cl = banner.layer.cornerRadius
        return cl > 1 ? cl : 22
    }()

    stripNotificationBackground(in: banner, glassView: nil)

    // .regular style has a dynamic tintColor: dark glass in dark mode, light glass in light mode.
    let effect = LiquidGlassEffect(style: .regular, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = banner.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = r
    gv.layer.cornerCurve = .continuous
    gv.clipsToBounds = false
    banner.insertSubview(gv, at: 0)
    storeBannerGlass(gv, for: banner)

    GlassDisplayLink.shared.register(host: banner, glass: gv, fallbackR: 22)
}

// MARK: - Notification cell (NCNotificationListCell)

private func storedNotificationGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.nc) as? LiquidGlassEffectView
}
private func storeNotificationGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.nc, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

/// Recursively clear every background colour and kill every CABackdropLayer in a
/// notification cell subtree. UILabel / UIImageView have transparent backgrounds by
/// default, so only the tinted pill layer loses its fill.
/// NOTE: pass the stored glass view so we never recurse into it and kill its own backdropLayer.
private func stripNotificationBackground(in view: UIView, glassView: UIView?) {
    // Never touch our own glass view
    if let gv = glassView, view === gv { return }

    view.backgroundColor = .clear
    view.layer.backgroundColor = UIColor.clear.cgColor
    view.layer.borderWidth = 0
    view.layer.borderColor = UIColor.clear.cgColor
    // Kill CABackdropLayer compositor layers at this level
    killBackdropLayers(in: view.layer)

    for sub in view.subviews {
        // Never recurse into our own glass view
        if let gv = glassView, sub === gv { continue }

        // UIVisualEffectView: null the effect AND hide — can't just clear bg
        if let vev = sub as? UIVisualEffectView {
            vev.effect = nil
            vev.backgroundColor = .clear
            vev.isHidden = true
            killBackdropLayers(in: vev.layer)
            continue
        }
        let n = String(describing: type(of: sub))
        // Never recurse into UIButton — swipe-action "Clear" buttons live here and
        // stripping their subviews erases the title label rendering.
        if sub is UIButton { continue }
        // Named background-only views — hide entirely
        if n.contains("Backdrop") || n.contains("Background") ||
           n.contains("Tint") || n.contains("Material") || n.contains("WallpaperTint") {
            sub.isHidden = true
            killBackdropLayers(in: sub.layer)
            continue
        }
        // All other subviews: clear their fill and recurse
        sub.backgroundColor = .clear
        sub.layer.backgroundColor = UIColor.clear.cgColor
        sub.layer.borderWidth = 0
        sub.layer.borderColor = UIColor.clear.cgColor
        killBackdropLayers(in: sub.layer)
        stripNotificationBackground(in: sub, glassView: glassView)
    }
}

@_silgen_name("LGApplyToNotificationCell")
public func applyToNotificationCell(_ cell: UIView) {
    guard isNotificationEnabled(), cell.bounds.width > 0 else { return }

    // Skip nested NCNotificationListCell (group stacks have outer + inner cells).
    // Only the outermost cell gets glass; applying to inner ones creates double-glass.
    let cellClass: AnyClass? = NSClassFromString("NCNotificationListCell")
    if let cc = cellClass {
        var ancestor = cell.superview
        while let a = ancestor {
            if a.isKind(of: cc) { return }
            ancestor = a.superview
        }
    }

    // Fast path — GlassDisplayLink owns frame + cornerRadius sync at display refresh rate.
    // Zero subview iteration here; the one-time strip keeps backgrounds permanently clear.
    if let gv = storedNotificationGlass(for: cell) {
        if gv.isHidden { gv.isHidden = false }
        if cell.subviews.first !== gv { cell.sendSubviewToBack(gv) }
        return
    }

    // Only create glass on fully-expanded cells (identity transform).
    // Peeking / stacked cards have a scale+translate transform from NC; skip them until
    // the user expands the stack, at which point UIKit animates to identity and this
    // guard passes — glass is created lazily, one card at a time.
    guard cell.transform.isIdentity,
          CATransform3DIsIdentity(cell.layer.transform) else { return }

    let r: CGFloat = {
        let cl = cell.layer.cornerRadius
        return cl > 1 ? cl : 20
    }()

    // First-time setup — all heavy work runs exactly once
    stripNotificationBackground(in: cell, glassView: nil)

    let effect = LiquidGlassEffect(style: .regular, isNative: false)
    if DeviceCapability.isLowEnd {
        // Slightly reduce tint on older GPUs to ease compositing pressure
        effect.tintColor = UIColor.white.withAlphaComponent(DeviceCapability.tintAlpha)
    }
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = cell.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = r
    gv.layer.cornerCurve = .continuous
    gv.clipsToBounds = false
    cell.insertSubview(gv, at: 0)
    storeNotificationGlass(gv, for: cell)

    // Hand off to the display link for real-time frame + corner sync (30 fps on low-end)
    GlassDisplayLink.shared.register(host: cell, glass: gv, fallbackR: 20)
}

// MARK: - UISwitch → LiquidGlassSwitch overlay

/// Forwards value changes from the glass switch back to the hidden native UISwitch,
/// triggering any targets/actions the app already registered on it.
private class SwitchForwarder: NSObject {
    weak var nativeSwitch: UISwitch?

    @objc func glassSwitchChanged(_ sender: LiquidGlassSwitch) {
        guard let sw = nativeSwitch else { return }
        sw.setOn(sender.isOn, animated: false)
        sw.sendActions(for: .valueChanged)
    }
}

private enum KSw {
    static var gs:  UInt8 = 0   // stored LiquidGlassSwitch sibling
    static var fwd: UInt8 = 0   // stored SwitchForwarder
}

private func storedGlassSwitch(for sw: UISwitch) -> LiquidGlassSwitch? {
    objc_getAssociatedObject(sw, &KSw.gs) as? LiquidGlassSwitch
}

/// Hide only UISwitch's own private sublayers, leaving LiquidGlassSwitch's layer visible.
/// Must be called after every layoutSubviews because UISwitch rebuilds its sublayers.
private func hideNativeSwitchLayers(_ sw: UISwitch, glassLayer: CALayer) {
    sw.backgroundColor = .clear
    sw.layer.backgroundColor = UIColor.clear.cgColor
    for sublayer in sw.layer.sublayers ?? [] {
        if sublayer === glassLayer { continue }
        sublayer.opacity = 0
    }
}

/// Create the glass switch sibling and hide the native one.
@_silgen_name("LGSetupSwitchOverlay")
public func setupSwitchOverlay(_ sw: UISwitch) {
    guard isSwitchEnabled() else { return }
    guard storedGlassSwitch(for: sw) == nil else { return }
    // Defer until frame is real — syncSwitchOverlay will retry via layoutSubviews
    guard sw.bounds.width > 0 else { return }

    // Skip keyboard / IME accessories only
    if let sv = sw.superview {
        let n = String(describing: type(of: sv))
        guard !n.contains("Keyboard"),
              !n.contains("InputMethod"),
              !n.contains("InputAccessory") else { return }
    }

    let gs = LiquidGlassSwitch()
    gs.isOn = sw.isOn
    gs.onTintColor = sw.onTintColor
    gs.thumbTintColor = sw.thumbTintColor
    gs.isEnabled = sw.isEnabled
    // Center within UISwitch bounds (LiquidGlassSwitch is 63×28, UISwitch is 51×31)
    gs.center = CGPoint(x: sw.bounds.midX, y: sw.bounds.midY)

    let fwd = SwitchForwarder()
    fwd.nativeSwitch = sw
    gs.addTarget(fwd, action: #selector(SwitchForwarder.glassSwitchChanged(_:)), for: .valueChanged)

    // Allow the glass switch to visually overflow UISwitch's bounds
    sw.clipsToBounds = false
    sw.superview?.clipsToBounds = false

    // Add INSIDE UISwitch — hit-testing finds LiquidGlassSwitch as the deepest subview,
    // so UISwitch's own beginTracking: never fires.
    sw.addSubview(gs)
    sw.bringSubviewToFront(gs)

    // Hide UISwitch's own CALayers individually — we cannot use layer.opacity = 0
    // on UISwitch itself because that would also hide the LiquidGlassSwitch child layer.
    hideNativeSwitchLayers(sw, glassLayer: gs.layer)

    objc_setAssociatedObject(sw, &KSw.gs,  gs,  .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    objc_setAssociatedObject(sw, &KSw.fwd, fwd, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

/// Sync position + state — called every layoutSubviews on the native switch.
@_silgen_name("LGSyncSwitchOverlay")
public func syncSwitchOverlay(_ sw: UISwitch) {
    guard let gs = storedGlassSwitch(for: sw) else {
        // Setup was deferred — retry now that frame exists
        setupSwitchOverlay(sw)
        return
    }
    gs.center = CGPoint(x: sw.bounds.midX, y: sw.bounds.midY)
    if gs.isOn != sw.isOn { gs.setOn(sw.isOn, animated: false) }
    gs.isEnabled = sw.isEnabled
    sw.bringSubviewToFront(gs)
    // Re-hide UISwitch's layers every layout pass — UISwitch rebuilds them on state changes
    hideNativeSwitchLayers(sw, glassLayer: gs.layer)
}

/// Remove the glass switch and restore the native one.
@_silgen_name("LGTeardownSwitchOverlay")
public func teardownSwitchOverlay(_ sw: UISwitch) {
    if let gs = storedGlassSwitch(for: sw) {
        gs.removeFromSuperview()
    }
    objc_setAssociatedObject(sw, &KSw.gs,  nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    objc_setAssociatedObject(sw, &KSw.fwd, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    // Restore UISwitch layers
    for sublayer in sw.layer.sublayers ?? [] { sublayer.opacity = 1 }
    sw.backgroundColor = nil
}

// MARK: - UISlider → LiquidGlassSlider overlay

private class SliderForwarder: NSObject {
    weak var nativeSlider: UISlider?

    @objc func glassSliderChanged(_ sender: LiquidGlassSlider) {
        guard let s = nativeSlider else { return }
        s.setValue(sender.value, animated: false)
        s.sendActions(for: .valueChanged)
    }
}

private enum KSl {
    static var gs:  UInt8 = 0
    static var fwd: UInt8 = 0
}

private func storedGlassSlider(for s: UISlider) -> LiquidGlassSlider? {
    objc_getAssociatedObject(s, &KSl.gs) as? LiquidGlassSlider
}

/// Hide UISlider's own sublayers without touching the LiquidGlassSlider layer.
private func hideNativeSliderLayers(_ s: UISlider, glassLayer: CALayer) {
    s.backgroundColor = .clear
    s.layer.backgroundColor = UIColor.clear.cgColor
    for sublayer in s.layer.sublayers ?? [] {
        if sublayer === glassLayer { continue }
        sublayer.opacity = 0
    }
}

@_silgen_name("LGSetupSliderOverlay")
public func setupSliderOverlay(_ s: UISlider) {
    guard isSliderEnabled() else { return }
    guard storedGlassSlider(for: s) == nil else { return }
    guard s.bounds.width > 0 else { return }

    // Walk up the hierarchy and skip sliders that live on the lock screen or
    // inside the media player — those get glass from their parent card instead.
    var p: UIView? = s.superview
    while let ancestor = p {
        let n = String(describing: type(of: ancestor))
        // Media player container and its controls panel own their own glass.
        if n == "CSAdjunctItemView" || n == "MPUSystemMediaControlsView" { return }
        // Any lock screen surface (CoverSheet, CarPlay lock screen, etc.).
        if n.contains("CoverSheet") || n.contains("LockScreen") || n.contains("Dashboard") { return }
        // Keyboard/input accessories are already guarded below but catch them early too.
        if n.contains("Keyboard") || n.contains("InputMethod") || n.contains("InputAccessory") { return }
        p = ancestor.superview
    }
    // Also check the window class name — lock screen runs in SBCoverSheetWindow / CSCoverSheetWindow.
    if let winName = s.window.map({ String(describing: type(of: $0)) }),
       winName.contains("CoverSheet") || winName.contains("LockScreen") { return }

    let gs = LiquidGlassSlider()
    gs.frame = s.bounds
    gs.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gs.value           = s.value
    gs.minimumValue    = s.minimumValue
    gs.maximumValue    = s.maximumValue
    gs.isContinuous    = s.isContinuous
    gs.minimumTrackTintColor = s.minimumTrackTintColor
    gs.maximumTrackTintColor = s.maximumTrackTintColor
    gs.thumbTintColor  = s.thumbTintColor
    gs.isEnabled       = s.isEnabled
    gs.minimumValueImage = s.minimumValueImage
    gs.maximumValueImage = s.maximumValueImage

    let fwd = SliderForwarder()
    fwd.nativeSlider = s
    gs.addTarget(fwd, action: #selector(SliderForwarder.glassSliderChanged(_:)), for: .valueChanged)

    s.clipsToBounds = false
    s.superview?.clipsToBounds = false

    s.addSubview(gs)
    s.bringSubviewToFront(gs)
    hideNativeSliderLayers(s, glassLayer: gs.layer)

    objc_setAssociatedObject(s, &KSl.gs,  gs,  .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    objc_setAssociatedObject(s, &KSl.fwd, fwd, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGSyncSliderOverlay")
public func syncSliderOverlay(_ s: UISlider) {
    guard let gs = storedGlassSlider(for: s) else {
        setupSliderOverlay(s)
        return
    }
    gs.frame = s.bounds
    if gs.value != s.value           { gs.setValue(s.value, animated: false) }
    if gs.minimumValue != s.minimumValue { gs.minimumValue = s.minimumValue }
    if gs.maximumValue != s.maximumValue { gs.maximumValue = s.maximumValue }
    gs.isEnabled = s.isEnabled
    s.bringSubviewToFront(gs)
    hideNativeSliderLayers(s, glassLayer: gs.layer)
}

@_silgen_name("LGTeardownSliderOverlay")
public func teardownSliderOverlay(_ s: UISlider) {
    if let gs = storedGlassSlider(for: s) { gs.removeFromSuperview() }
    objc_setAssociatedObject(s, &KSl.gs,  nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    objc_setAssociatedObject(s, &KSl.fwd, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    for sublayer in s.layer.sublayers ?? [] { sublayer.opacity = 1 }
    s.backgroundColor = nil
}
