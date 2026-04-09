//
//  LiquidGlassBridge.swift  –  LiquidGlass
//  Dock + Passcode glass. Reads the enabled pref from Settings.
//

import UIKit

// MARK: - Preferences
private let kSuite = "com.yourhandle.liquidglass"
private func pref(_ key: String, default def: Bool = true) -> Bool {
    UserDefaults(suiteName: kSuite)?.object(forKey: key) as? Bool ?? def
}
private func isEnabled()       -> Bool { pref("enabled") }
private func isDockEnabled()   -> Bool { isEnabled() && pref("dockEnabled") }
private func isFolderEnabled() -> Bool { isEnabled() && pref("folderEnabled") }
private func isSwitchEnabled() -> Bool { isEnabled() && pref("switchEnabled") }
private func isSliderEnabled()        -> Bool { isEnabled() && pref("sliderEnabled") }
private func isNotificationEnabled()  -> Bool { isEnabled() && pref("notificationEnabled") }
private func isMediaPlayerEnabled()   -> Bool { isEnabled() && pref("mediaPlayerEnabled") }

// MARK: - Associated object keys
private enum K {
    static var gv: UInt8 = 0   // dock glass view
    static var pb: UInt8 = 0   // passcode button glass view
    static var fi: UInt8 = 0   // folder icon glass view
    static var fo: UInt8 = 0   // open folder background glass
    static var nc: UInt8 = 0   // notification cell glass view
    static var mp: UInt8 = 0   // media player glass view
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
    guard isEnabled(), btn.bounds.width > 0 else { return }

    // Always re-strip — SpringBoard restores material between layout passes
    stripButtonMaterial(in: btn)
    btn.backgroundColor = .clear

    // Sync frame if already set up
    if let gv = storedButtonGlass(for: btn) {
        gv.frame = btn.bounds
        gv.layer.cornerRadius = btn.bounds.width * 0.5
        return
    }

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

    let r = view.layer.cornerRadius > 0 ? view.layer.cornerRadius : 22

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

    let r: CGFloat = {
        let cl = cell.layer.cornerRadius
        return cl > 1 ? cl : 20
    }()

    // Fast path: already set up — sync frame + shallow strip.
    // IMPORTANT: do NOT call killBackdropLayers(in: cell.layer) here.
    // That function walks the CALayer tree regardless of view guards and would
    // disable the glass view's own CABackdropLayer on every layout pass, breaking rendering.
    if let gv = storedNotificationGlass(for: cell) {
        gv.isHidden = false
        gv.frame = cell.bounds
        gv.layer.cornerRadius = r
        cell.backgroundColor = .clear
        cell.layer.backgroundColor = UIColor.clear.cgColor
        cell.layer.borderWidth = 0
        for sub in cell.subviews {
            if sub === gv { continue }
            if let vev = sub as? UIVisualEffectView { vev.effect = nil; vev.isHidden = true; continue }
            sub.backgroundColor = .clear
            sub.layer.backgroundColor = UIColor.clear.cgColor
            sub.layer.borderWidth = 0
        }
        cell.sendSubviewToBack(gv)
        return
    }

    // Only create glass on cells that are fully expanded (identity transform).
    // Peeking / stacked cells behind the top card have a scale+translate transform
    // applied by NC. Skipping them avoids creating concurrent CABackdropLayers for
    // every buried card (the lag source).
    // When the user taps to expand the stack, UIKit animates each card to identity;
    // layoutSubviews fires during that animation, this guard passes, and glass is
    // created lazily — one card at a time.
    guard cell.transform.isIdentity,
          CATransform3DIsIdentity(cell.layer.transform) else { return }

    // First-time setup: strip backgrounds once, then insert glass.
    stripNotificationBackground(in: cell, glassView: nil)

    let effect = LiquidGlassEffect(style: .regular, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = cell.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = r
    gv.layer.cornerCurve = .continuous
    gv.clipsToBounds = false
    cell.insertSubview(gv, at: 0)
    storeNotificationGlass(gv, for: cell)
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
