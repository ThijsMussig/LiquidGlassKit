 //
//  LiquidGlassView.swift
//  LiquidGlass
//
//  Created by Alexey Demin on 2025-12-05.
//

import UIKit
import Darwin  // dlopen / dlsym / RTLD_NOW for jbroot() runtime resolution
internal import simd
internal import MetalKit
internal import MetalPerformanceShaders

struct LiquidGlass {

    /// Maximum number of rectangles supported in the shader.
    static let maxRectangles = 16

    /// Mirror the Metal 'ShaderUniforms' exactly for buffer binding.
    struct ShaderUniforms {
        var resolution: SIMD2<Float> = .zero        // Frame size in pixels.
        var contentsScale: Float = .zero            // Scale factor. 2 for Retina; 3 for Super Retina.
        var touchPoint: SIMD2<Float> = .zero        // Touch position in points (upper-left origin).
        var shapeMergeSmoothness: Float = .zero     // Specifies the distance between elements at which they begin to merge (spacing).
        var cornerRadius: Float = .zero             // Base rounding (e.g., 24 for subtle chamfer). Circle if half the side.
        var cornerRoundnessExponent: Float = 2      // 1 = diamond; 2 = circle; 4 = squircle.
        var materialTint: SIMD4<Float> = .zero      // RGBA; e.g., subtle cyan (0.2, 0.8, 1.0, 1.0)
        var glassThickness: Float                   // Fake parallax depth (e.g., 8-16 px)
        var refractiveIndex: Float                  // 1.45-1.52 for borosilicate glass feel
        var dispersionStrength: Float               // 0.0-0.02; prismatic color split on edges
        var fresnelDistanceRange: Float             // px falloff from silhouette (e.g., 32)
        var fresnelIntensity: Float                 // 0.0-1.0; rim lighting boost
        var fresnelEdgeSharpness: Float             // Power 1.0=linear, 8.0=crisp
        var glareDistanceRange: Float               // Similar to fresnel, but for specular streaks
        var glareAngleConvergence: Float            // 0.0-π; focuses rays toward light dir
        var glareOppositeSideBias: Float            // >1.0 amplifies back-side highlights
        var glareIntensity: Float                   // 1.0-4.0; bloom-like edge fire
        var glareEdgeSharpness: Float               // Matches fresnel for consistency
        var glareDirectionOffset: Float             // Radians; tilts streak asymmetry
        var rectangleCount: Int32 = .zero           // Number of active rectangles
        var rectangles: (                           // Array of rectangles (x, y, width, height) in points, upper-left origin.
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
        ) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero,
             .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
        /// Motion reprojection UV offset. Zero after a fresh capture;
        /// non-zero on throttled frames when the view has moved.
        /// Written per-frame in draw() — NOT via updateUniforms().
        var captureOffset: SIMD2<Float> = .zero
        /// Mirrors backgroundTextureSizeCoefficient. Passed to the shader so it can remap
        /// input.uv into the center fraction of the capture texture, preserving edge buffer
        /// for captureOffset to shift into without immediately hitting clamp_to_edge.
        var textureSizeCoefficient: Float = 1
    }

    let shaderUniforms: ShaderUniforms
    let backgroundTextureSizeCoefficient: Double
    let backgroundTextureScaleCoefficient: Double
    let backgroundTextureBlurRadius: Double
    var tintColor: UIColor?
    var shadowOverlay: Bool = false
    /// When true this view always renders at native device FPS with full shader
    /// effects (no cheap-mode reduction). Used for interactive controls (sliders,
    /// switches) where animation quality matters more than background-glass savings.
    var fullQuality: Bool = false
    /// When false the capture scheduler never runs and no backdrop/screen capture
    /// is performed — the shader renders over a transparent background only.
    /// Used for thumb views (sliders/switches) to avoid the CABackdropLayer blur.
    var autoCapture: Bool = true
    /// When true, always use the root-view render path instead of CABackdropLayer.
    /// CABackdropLayer applies an OS-level compositor blur that cannot be turned off;
    /// root-view capture (layer.render) produces a clean, unblurred snapshot.
    /// Set on thumb presets so sliders/switches show sharp glass without any blur.
    var forceRootCapture: Bool = false

    static func thumb(magnification: Double = 1) -> Self {
        .init(
            shaderUniforms: .init(
                materialTint: .init(x: 0.9, y: 0.95, z: 1.0, w: 0.15), // Near-clear with cool bias.
                glassThickness: 10,
                refractiveIndex: 1.11,
                dispersionStrength: 5,
                fresnelDistanceRange: 70,
                fresnelIntensity: 0,
                fresnelEdgeSharpness: 0,
                glareDistanceRange: 30,
                glareAngleConvergence: 0,
                glareOppositeSideBias: 0,
                glareIntensity: 0.01,
                glareEdgeSharpness: -0.2,
                glareDirectionOffset: .pi * 0.9,
            ),
            backgroundTextureSizeCoefficient: 1 / magnification,
            backgroundTextureScaleCoefficient: magnification,
            backgroundTextureBlurRadius: 0,
            shadowOverlay: true,
            fullQuality: true,
            forceRootCapture: true,
        )
    }

    /// Like thumb but tuned for small pill elements (switches).
    /// Translucent frosted glass — shows background through, slight cool-white tint,
    /// no chromatic dispersion, near-flat refraction. No fresnel ring.
    static let switchThumb = Self.init(
        shaderUniforms: .init(
            materialTint: .zero, // No tint — pure glass
            glassThickness: 15,
            refractiveIndex: 0.75,   // < 1.0 → diverging lens: refracts outward (zoom-out / inward cave effect)
            dispersionStrength: 0,   // No chromatic aberration
            fresnelDistanceRange: 0,
            fresnelIntensity: 0,     // No white ring
            fresnelEdgeSharpness: 0,
            glareDistanceRange: 20,
            glareAngleConvergence: 0,
            glareOppositeSideBias: 0,
            glareIntensity: 0.015,
            glareEdgeSharpness: -0.1,
            glareDirectionOffset: .pi * 0.9,
        ),
        backgroundTextureSizeCoefficient: 1.0,
        backgroundTextureScaleCoefficient: 1.0,
        backgroundTextureBlurRadius: 0,
        shadowOverlay: true,
        fullQuality: true,
        forceRootCapture: true
    )

    static let lens = Self.init(
        shaderUniforms: .init(
            glassThickness: 6,
            refractiveIndex: 1.1,
            dispersionStrength: 15,
            fresnelDistanceRange: 70,
            fresnelIntensity: 0,
            fresnelEdgeSharpness: 0,
            glareDistanceRange: 30,
            glareAngleConvergence: 0.1,
            glareOppositeSideBias: 1,
            glareIntensity: 0.1,
            glareEdgeSharpness: -0.1,
            glareDirectionOffset: -.pi / 4,
        ),
        backgroundTextureSizeCoefficient: 1.1,
        backgroundTextureScaleCoefficient: 0.8,
        backgroundTextureBlurRadius: 0,
        shadowOverlay: true,
    )

    static let regular = Self.init(
        shaderUniforms: .init(
            glassThickness: 10,
            refractiveIndex: 1.5,
            dispersionStrength: 5,
            fresnelDistanceRange: 70,
            fresnelIntensity: 0,
            fresnelEdgeSharpness: 0,
            glareDistanceRange: 30,
            glareAngleConvergence: 0.1,
            glareOppositeSideBias: 1,
            glareIntensity: 0.1,
            glareEdgeSharpness: -0.15,
            glareDirectionOffset: -.pi / 4,
        ),
        backgroundTextureSizeCoefficient: 1.5,
        backgroundTextureScaleCoefficient: 0.2,
        backgroundTextureBlurRadius: 0.3,
        tintColor: UIColor { $0.userInterfaceStyle == .dark ? #colorLiteral(red: 0, green: 0.04958364581, blue: 0.09951775161, alpha: 0.7981493615) : #colorLiteral(red: 0.9023525731, green: 0.9509486998, blue: 1, alpha: 0.8002892298) }//.systemBackground.withAlphaComponent(0.8),
    )

    /// Same as regular but with no material tint — fully-transparent glass with only refraction.
    static let clear = Self.init(
        shaderUniforms: .init(
            materialTint: .zero,  // Explicitly zero — no white/dark tint at all
            glassThickness: 10,
            refractiveIndex: 1.5,
            dispersionStrength: 5,
            fresnelDistanceRange: 70,
            fresnelIntensity: 0,
            fresnelEdgeSharpness: 0,
            glareDistanceRange: 30,
            glareAngleConvergence: 0.1,
            glareOppositeSideBias: 1,
            glareIntensity: 0.1,
            glareEdgeSharpness: -0.15,
            glareDirectionOffset: -.pi / 4,
        ),
        backgroundTextureSizeCoefficient: 1.5,
        backgroundTextureScaleCoefficient: 0.2,
        backgroundTextureBlurRadius: 0.25,
        tintColor: nil
    )

    /// Like clear but with heavier blur and no tint — for panels that sit over busy content.
    static let clearBlur = Self.init(
        shaderUniforms: .init(
            materialTint: .zero,
            glassThickness: 10,
            refractiveIndex: 1.45,
            dispersionStrength: 4,
            fresnelDistanceRange: 70,
            fresnelIntensity: 0,
            fresnelEdgeSharpness: 0,
            glareDistanceRange: 30,
            glareAngleConvergence: 0.1,
            glareOppositeSideBias: 1,
            glareIntensity: 0.08,
            glareEdgeSharpness: -0.15,
            glareDirectionOffset: -.pi / 4,
        ),
        backgroundTextureSizeCoefficient: 1.5,
        backgroundTextureScaleCoefficient: 0.15,
        backgroundTextureBlurRadius: 1.2,
        tintColor: nil
    )
}

final class BackdropView: UIView {

    override class var layerClass: AnyClass {
        // CABackdropLayer is a private API that captures content behind the layer
        NSClassFromString("CABackdropLayer") ?? CALayer.self
    }

    init() {
        super.init(frame: .zero)

        // Configure backdrop view
        isUserInteractionEnabled = false
        layer.setValue(false, forKey: "layerUsesCoreImageFilters")

        // Configure backdrop layer properties (private API)
        layer.setValue(true, forKey: "windowServerAware")
        // Shared group name: all LiquidGlassViews share one CABackdropLayer capture group.
        // The WindowServer only composites the background once for all views in the same group
        // instead of N separate captures — the single biggest GPU win on A11/A12.
        // Each BackdropView MUST have a unique groupName. Sharing a groupName tells
        // WindowServer to use one composited capture region for all views in the group —
        // every view would then show the same background position, causing the glass to
        // be misaligned on any view that isn't at the capture origin.
        layer.setValue(UUID().uuidString, forKey: "groupName")
//        layer.setValue(1.0, forKey: "scale")  // Full resolution for capture
//        layer.setValue(0.0, forKey: "bleedAmount")
//        layer.setValue(false, forKey: "allowsHitTesting")
//        layer.setValue(true, forKey: "captureOnly")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class ShadowView: UIView {

    init() {
        super.init(frame: .zero)

        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.compositingFilter = "multiplyBlendMode"
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let shadowRadius = 3.5
        let path = UIBezierPath(roundedRect: bounds.insetBy(dx: -1, dy: -shadowRadius / 2), cornerRadius: bounds.height / 2)
        let innerPill = UIBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: shadowRadius / 2), cornerRadius: bounds.height / 2).reversing()
        path.append(innerPill)
        layer.shadowPath = path.cgPath
        layer.shadowRadius = shadowRadius
        layer.shadowOpacity = 0.2
        layer.shadowOffset = .init(width: 0, height: shadowRadius + 2)
    }
}

final class LiquidGlassRenderer {
    @MainActor static let shared = LiquidGlassRenderer()

    let device: MTLDevice
    let pipelineState: MTLRenderPipelineState

    /// One shared command queue for ALL LiquidGlassViews.
    /// The Metal driver serializes work per-queue; sharing one queue reduces driver overhead
    /// compared to N independent queues, and lets Metal track cross-view texture dependencies
    /// automatically (crucial for the shared async blur → render ordering).
    let commandQueue: MTLCommandQueue

    /// True on A11/A12-class hardware (iPhone X/8/11). Detected via GPU memory budget.
    /// These devices have ≤1.5 GB recommended working set vs 4 GB+ on A14+.
    let isLowPerformanceDevice: Bool

    /// Resolve a jailbreak-relative path (e.g. "/Library/LiquidGlass/…") to its real
    /// filesystem path under the active bootstrap:
    ///
    ///  • RootHide — calls jbroot() from libroothide (pre-loaded by the bootstrap) via
    ///    dlsym. RootHide installs files to /var/jb in the .deb but remaps that prefix
    ///    to a UUID-randomised hidden location at runtime; only jbroot() gives the real path.
    ///
    ///  • Rootless (Palera1n / Dopamine) — /var/jb prefix, no remapping needed.
    ///
    ///  • Rootful (Unc0ver / Taurine) — no prefix.
    static func jbRealPath(_ relativePath: String) -> String {
        // 1. Try RootHide's jbroot() — pre-loaded into every process, resolved by dlsym.
        //    libroothide exports the symbol "jbroot" as a C function: const char*(const char*)
        if let sym = dlsym(dlopen(nil, RTLD_NOW), "jbroot") {
            typealias JBRootFn = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>?
            let fn = unsafeBitCast(sym, to: JBRootFn.self)
            if let result = relativePath.withCString({ fn($0) }) {
                return String(cString: result)
            }
        }
        // 2. Rootless: prepend /var/jb
        if FileManager.default.fileExists(atPath: "/var/jb") {
            return "/var/jb" + relativePath
        }
        // 3. Rootful: use path as-is
        return relativePath
    }

    /// Number of LiquidGlassViews currently attached to a window.
    /// Used to auto-switch to cheap mode when many glass views are visible at once.
    private(set) var activeViewCount: Int = 0

    /// When true, shaders skip expensive dispersion/glare and capture runs at reduced scale.
    /// Automatically true on low-perf devices or when > 2 views are active.
    var shouldUseCheapMode: Bool {
        isLowPerformanceDevice || activeViewCount > 2
    }

    func registerView()   { activeViewCount += 1 }
    func unregisterView() { activeViewCount = max(0, activeViewCount - 1) }

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not supported")
        }
        self.device = device

        // Shared command queue — created once, reused by all LiquidGlassViews.
        guard let queue = device.makeCommandQueue() else {
            fatalError("Failed to create Metal command queue")
        }
        self.commandQueue = queue

        // A11/A12 GPU family (apple4/apple5) cannot run the full glass effect stack
        // across many simultaneous views without dropping frames. apple6 = A13+.
        // supportsFamily(_:) is available on iOS 13+, safe for our iOS 14 deployment target.
        self.isLowPerformanceDevice = !device.supportsFamily(.apple6)

#if SWIFT_PACKAGE
        let library = try! device.makeDefaultLibrary(bundle: .module)
#else
        // Resolve shader bundle: prefer a bundle embedded next to the binary (normal app / Swift Package
        // non-module builds), then fall back to the jailbreak tweak installation path.
        let mainBundle = Bundle(for: LiquidGlassView.self)
        let resolvedBundleURL: URL
        if let embeddedURL = mainBundle.url(forResource: "LiquidGlassKitShaderResources", withExtension: "bundle") {
            resolvedBundleURL = embeddedURL
        } else {
            // Jailbreak tweak layout. Resolve the path using whichever bootstrap is active:
            //
            //  • RootHide: files are installed to /var/jb/ in the .deb, but RootHide's detection
            //    bypass remaps /var/jb to a UUID-randomised hidden path at runtime. The only
            //    correct way to get the real path is via jbroot() from libroothide, which is
            //    pre-loaded into every process by the bootstrap. We call it through dlsym so
            //    we don't need to link against libroothide at build time.
            //
            //  • Rootless (Palera1n / Dopamine): plain /var/jb prefix, no remapping.
            //
            //  • Rootful (legacy Unc0ver / Taurine): no prefix at all.
            let relative = "/Library/LiquidGlass/LiquidGlassKitShaderResources.bundle"
            resolvedBundleURL = URL(fileURLWithPath: LiquidGlassRenderer.jbRealPath(relative))
        }
        guard let shaderBundle = Bundle(url: resolvedBundleURL) else {
            fatalError("[LiquidGlass] Could not open shader bundle at \(resolvedBundleURL.path)")
        }
        let library = try! device.makeDefaultLibrary(bundle: shaderBundle)
#endif

        let vertexFunction = library.makeFunction(name: "fullscreenQuad")!
        let fragmentFunction = library.makeFunction(name: "liquidGlassEffect")!

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm  // Match MTKView

        self.pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
}

final class LiquidGlassView: MTKView {

    let liquidGlass: LiquidGlass

    // No per-instance commandQueue — use LiquidGlassRenderer.shared.commandQueue.
    // Removing N per-instance queues eliminates N×(driver setup + scheduling overhead).
    var uniformsBuffer: MTLBuffer!
    var zeroCopyBridge: ZeroCopyBridge!

    // Background texture for the shader
    private var backgroundTexture: MTLTexture?

    /// Whether to automatically capture superview on a background schedule.
    /// Set to false for manual control via `captureBackground()`.
    var autoCapture: Bool = true {
        didSet {
            if autoCapture { startCaptureScheduler() } else { stopCaptureScheduler() }
        }
    }

    var touchPoint: CGPoint? = nil

    var frames: [CGRect] = []

    // Shadow overlay subview
    private weak var shadowView: ShadowView?

    // Backdrop capture view (stays in superview, contains only CABackdropLayer)
    private let backdropView = BackdropView()

    // MARK: - Capture scheduler (fully decoupled from the render CADisplayLink)
    //
    // The MTKView display link drives draw() at 30/20 fps — pure GPU work only.
    // A *separate* CADisplayLink runs at a lower preferred rate and is solely
    // responsible for CPU-side background captures. This guarantees the render
    // loop never waits on a screen capture; if a capture takes 8 ms the GPU
    // still gets its command buffer on time.
    //
    // Rate:  normal  → every 2nd display link tick at 30 Hz ≈ 15 captures/sec
    //        A11/A12 → every 3rd tick   at 20 Hz ≈  7 captures/sec
    private var captureDisplayLink: CADisplayLink?
    private var captureTick: Int = 0
    private var captureTickInterval: Int {
        LiquidGlassRenderer.shared.isLowPerformanceDevice ? 3 : 2
    }

    /// Effective texture scale coefficient — capped at 7% on A11/A12 for ~5× bandwidth savings.
    /// MUST be used for BOTH buffer allocation (layoutSubviews) and capture rendering so the
    /// ZeroCopyBridge pixel buffer dimensions always match what is rendered into it.
    /// fullQuality views (sliders, switches) are exempt — they need full-res texture.
    private var effectiveTextureScaleCoefficient: Double {
        if liquidGlass.fullQuality { return liquidGlass.backgroundTextureScaleCoefficient }
        return LiquidGlassRenderer.shared.isLowPerformanceDevice
            ? min(liquidGlass.backgroundTextureScaleCoefficient, 0.07)
            : liquidGlass.backgroundTextureScaleCoefficient
    }

    // Motion reprojection state — records where the background was last captured from.
    // draw() computes the UV delta each frame and injects it as captureOffset so the
    // glass stays aligned between captures (important on A11 with 7 captures/sec).
    private var lastCapturedBounds: CGRect = .zero
    private var lastCapturedCenter: CGPoint = .zero

    // App-state pause observers — held strongly so they stay active; removed on window leave.
    private var appBackgroundObserver: NSObjectProtocol?
    private var appForegroundObserver: NSObjectProtocol?

    init(_ liquidGlass: LiquidGlass) {
        self.liquidGlass = liquidGlass

        super.init(frame: .zero, device: LiquidGlassRenderer.shared.device)

        // Apply preset's autoCapture flag before willMove fires.
        autoCapture = liquidGlass.autoCapture

        if liquidGlass.shadowOverlay {
            let shadowView = ShadowView()
            addSubview(shadowView)
            self.shadowView = shadowView
        }
        setupMetal()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow != nil {
            LiquidGlassRenderer.shared.registerView()
            startCaptureScheduler()
            appBackgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                // Pause the render loop and kill the capture scheduler — nothing is visible.
                self?.isPaused = true
                self?.stopCaptureScheduler()
                self?.backgroundTexture = nil
            }
            appForegroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.isPaused = false
                self?.startCaptureScheduler()
            }
        } else {
            LiquidGlassRenderer.shared.unregisterView()
            stopCaptureScheduler()
            if let t = appBackgroundObserver { NotificationCenter.default.removeObserver(t) }
            if let t = appForegroundObserver { NotificationCenter.default.removeObserver(t) }
            appBackgroundObserver = nil
            appForegroundObserver = nil
        }
    }

    // MARK: - Capture scheduler

    private func startCaptureScheduler() {
        guard autoCapture, captureDisplayLink == nil else { return }
        let dl = CADisplayLink(target: self, selector: #selector(captureSchedulerFired))
        // Use .common so the scheduler fires even while a UIScrollView is tracking.
        // Captures every captureTickInterval frames keep the texture fresh enough that
        // captureOffset only needs to cover a few frames of movement (typically < 20pt),
        // which stays well within the 16.7% buffer provided by sizeCoefficient = 1.5.
        dl.add(to: .main, forMode: .common)
        captureDisplayLink = dl
        captureTick = captureTickInterval  // fire on very first tick
    }

    private func stopCaptureScheduler() {
        captureDisplayLink?.invalidate()
        captureDisplayLink = nil
    }

    @objc private func captureSchedulerFired() {
        captureTick += 1
        let boundsChanged = abs(bounds.width  - lastCapturedBounds.width)  > 1.0
                         || abs(bounds.height - lastCapturedBounds.height) > 1.0
        let needsFirst = backgroundTexture == nil
        if needsFirst || boundsChanged || captureTick >= captureTickInterval {
            captureTick = 0
            lastCapturedBounds = bounds
            captureBackground()
        }
    }

    func setupMetal() {
        guard let device else { return }

        // Use the shared command queue instead of a per-instance one.
        // One queue means fewer Metal driver serialisation points across all glass views.

        // Uniforms buffer (update per frame)
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<LiquidGlass.ShaderUniforms>.stride, options: [])!

        zeroCopyBridge = .init(device: device)

        // Make view transparent so we can see the effect
        isOpaque = false
        layer.isOpaque = false

        // framebufferOnly = true lets the driver skip the extra copy needed for
        // sampling the drawable — valid here because we never read the framebuffer.
        framebufferOnly = true

        // Full-quality views (sliders, switches) always render at native device FPS.
        // Background glass views are capped to halve GPU load.
        if liquidGlass.fullQuality {
            preferredFramesPerSecond = 0  // 0 = match display (60/120 Hz)
        } else {
            preferredFramesPerSecond = LiquidGlassRenderer.shared.isLowPerformanceDevice ? 20 : 30
        }

        isPaused = false
    }

    // MARK: - Background Capture

    func captureBackground() {
        // CABackdropLayer (used by captureBackdrop) applies an OS compositor blur that
        // cannot be disabled — use the root-view path for presets that need no blur.
        if liquidGlass.forceRootCapture || {
            if #available(iOS 26.2, *) { return true } else { return false }
        }() {
            captureRootView()
        } else {
            captureBackdrop()
        }
    }

    /// Captures the background content via root View using (presentation) Layer render.
    /// High CPU usage.
    func captureRootView() {
        guard let rootView = findRootView() else { return }

        let sizeCoefficient = liquidGlass.backgroundTextureSizeCoefficient
        let scaleCoefficient = layer.contentsScale * effectiveTextureScaleCoefficient

        // Determine our on-screen rect in the root view coordinate space.
        // IMPORTANT: During `UIView.animate`, the view's *model* layer jumps to the final frame
        // immediately; the in-flight position lives in the *presentation* layer. Using the
        // presentation layer makes the captured background track the view while it animates.
        let currentLayer = layer.presentation() ?? layer
        let frameInRoot = currentLayer.convert(currentLayer.bounds, to: rootView.layer)

        // Expand capture area around the MTKView center (in root view coordinates)
        let captureSize = CGSize(width: frameInRoot.width * sizeCoefficient,
                                 height: frameInRoot.height * sizeCoefficient)
        let captureRectInRoot = CGRect(x: frameInRoot.midX - captureSize.width / 2,
                                       y: frameInRoot.midY - captureSize.height / 2,
                                       width: captureSize.width,
                                       height: captureSize.height)

        backgroundTexture = zeroCopyBridge.render { context in
            // No need to hide this view — MTKView uses CAMetalLayer whose Metal content
            // is compositor-only and does NOT appear in layer.render(in:). Any attempt
            // to hide or zero opacity causes CA to composite a blank frame → flicker.
            context.scaleBy(x: scaleCoefficient, y: scaleCoefficient)
            context.translateBy(x: -captureRectInRoot.origin.x, y: -captureRectInRoot.origin.y)

            let rootViewLayer = rootView.layer.presentation() ?? rootView.layer
            rootViewLayer.render(in: context)
        }

        blurTexture()
        recordCaptureCenter()
    }

    /// Captures the background content via CABackdropLayer using drawHierarchy.
    /// Noticeable rendering delay.
    func captureBackdrop() {
        guard let superview else { return }

        let sizeCoefficient = liquidGlass.backgroundTextureSizeCoefficient
        let scaleCoefficient = layer.contentsScale * effectiveTextureScaleCoefficient

        // Calculate frame using presentation layer for smooth animation tracking
        let currentLayer = layer.presentation() ?? layer
        let frameInSuperview = currentLayer.convert(currentLayer.bounds, to: superview.layer)
        let captureSize = CGSize(width: frameInSuperview.width * sizeCoefficient,
                                 height: frameInSuperview.height * sizeCoefficient)
        let captureOrigin = CGPoint(x: frameInSuperview.midX - captureSize.width / 2,
                                    y: frameInSuperview.midY - captureSize.height / 2)
        
        // Position backdrop view and layer
        backdropView.frame = CGRect(origin: captureOrigin, size: captureSize)

        // Ensure backdrop view is in superview (below us)
        if backdropView.superview !== superview {
            superview.insertSubview(backdropView, belowSubview: self)
        }
        
        // MUST use drawHierarchy — CABackdropLayer content comes from WindowServer compositing
        // and is NOT accessible via layer.render(in:). Only drawHierarchy captures it.
        backgroundTexture = zeroCopyBridge.render { context in
            context.scaleBy(x: scaleCoefficient, y: scaleCoefficient)
            UIGraphicsPushContext(context)
            backdropView.drawHierarchy(in: backdropView.bounds, afterScreenUpdates: false)
            UIGraphicsPopContext()
        }

        blurTexture()
        recordCaptureCenter()
    }

    func blurTexture() {
        guard liquidGlass.backgroundTextureBlurRadius > 0,
              let device,
              let commandBuffer = LiquidGlassRenderer.shared.commandQueue.makeCommandBuffer(),
              var backgroundTexture else { return }

        // Apply GPU-accelerated Gaussian blur via MPS
        // On A11/A12 textures are captured at 7% scale. A small blur multiplier smooths
        // pixelation without washing out detail. 0.8× is a subtle polish pass — heavy
        // blur (≥1.2×) makes the glass look foggy and hides the refractive distortion.
        let blurRadius = LiquidGlassRenderer.shared.isLowPerformanceDevice
            ? liquidGlass.backgroundTextureBlurRadius * 0.8
            : liquidGlass.backgroundTextureBlurRadius
        let sigma = Float(blurRadius * layer.contentsScale)
        let blur = MPSImageGaussianBlur(device: device, sigma: sigma)
        blur.edgeMode = .clamp

        blur.encode(commandBuffer: commandBuffer, inPlaceTexture: &backgroundTexture, fallbackCopyAllocator: nil)
        // Do NOT call waitUntilCompleted() here — that blocks the main thread for the full
        // blur duration every frame. Committing without waiting is safe: the shared command
        // queue serialises the blur before the render encoder that reads backgroundTexture,
        // so Metal's dependency tracking guarantees ordering automatically.
        commandBuffer.commit()
    }

    /// Records the view's current presentation-layer midpoint in **window** coordinates
    /// as the anchor for motion reprojection. Using the window (screen) coordinate space
    /// means parent UIScrollView scrolling is visible as a position delta — superview
    /// coordinates do NOT change when a scroll view's contentOffset changes because the
    /// glass view's frame in its direct parent is fixed; only the window position moves.
    private func recordCaptureCenter() {
        guard let window else { return }
        let l = layer.presentation() ?? layer
        lastCapturedCenter = l.convert(CGPoint(x: l.bounds.midX, y: l.bounds.midY), to: window.layer)
    }

    func updateUniforms() {
        var uniforms = liquidGlass.shaderUniforms
        let scaleFactor = layer.contentsScale

        uniforms.resolution = .init(x: Float(bounds.width * scaleFactor),
                                    y: Float(bounds.height * scaleFactor))
        uniforms.contentsScale = Float(scaleFactor)

        uniforms.shapeMergeSmoothness = 0.2

        // Assign rectangles from frames array, or use bounds if empty
        let effectiveFrames = frames.isEmpty ? [bounds] : frames
        uniforms.rectangleCount = Int32(min(effectiveFrames.count, LiquidGlass.maxRectangles))

        // Convert CGRect frames to SIMD4<Float> (x, y, width, height)
        var rects: [SIMD4<Float>] = []
        for i in 0..<LiquidGlass.maxRectangles {
            if i < effectiveFrames.count {
                let frame = effectiveFrames[i]
                rects.append(SIMD4<Float>(
                    Float(frame.origin.x),
                    Float(frame.origin.y),
                    Float(frame.width),
                    Float(frame.height)
                ))
            } else {
                rects.append(.zero)
            }
        }
        uniforms.rectangles = (
            rects[0], rects[1], rects[2], rects[3],
            rects[4], rects[5], rects[6], rects[7],
            rects[8], rects[9], rects[10], rects[11],
            rects[12], rects[13], rects[14], rects[15]
        )

        if let touchPoint {
            uniforms.touchPoint = .init(x: Float(touchPoint.x), y: Float(touchPoint.y))
        }

//        uniforms.cornerRoundnessExponent = (layer.cornerCurve == .continuous) ? 4 : 2
        uniforms.cornerRadius = Float(layer.cornerRadius)

        if let tintColor = liquidGlass.tintColor {
            uniforms.materialTint = tintColor.toSimdFloat4()
        }

        // Cheap mode: when more than 2 glass views are active (e.g. notification stack)
        // or on a low-performance device, disable expensive per-fragment effects that add
        // GPU time without significantly changing the glass look at small sizes.
        // Full-quality views (thumb in sliders/switches) are always exempt.
        if !liquidGlass.fullQuality && LiquidGlassRenderer.shared.shouldUseCheapMode {
            uniforms.dispersionStrength = 0
            uniforms.glareIntensity = 0
        }

        // Keep textureSizeCoefficient in sync so the shader knows how to remap UVs.
        uniforms.textureSizeCoefficient = Float(liquidGlass.backgroundTextureSizeCoefficient)

        uniformsBuffer.contents().assumingMemoryBound(to: LiquidGlass.ShaderUniforms.self).pointee = uniforms

//        setNeedsDisplay()
//        draw(bounds)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        updateUniforms()

        let scale = layer.contentsScale * liquidGlass.backgroundTextureSizeCoefficient * effectiveTextureScaleCoefficient
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        zeroCopyBridge.setupBuffer(width: width, height: height)

        shadowView?.frame = bounds
    }

    override func draw(_ rect: CGRect) {
        // FAST PATH — pure GPU work only. Capture never happens here.
        // Background texture is updated by the separate captureSchedulerFired() display link.
        guard let drawable = currentDrawable,
              let renderPassDesc = currentRenderPassDescriptor,
              let commandBuffer = LiquidGlassRenderer.shared.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return }

        // Motion reprojection: compute how far the view has moved on screen since the last
        // capture and write the UV-space delta into the uniforms buffer so the shader corrects
        // for it every frame. Using window (screen) coordinates is critical — superview coords
        // are static during UIScrollView scrolling because the view's frame within its direct
        // parent never changes; only the window-relative position reflects scroll movement.
        if autoCapture, let window {
            let l = layer.presentation() ?? layer
            let screenPos = l.convert(CGPoint(x: l.bounds.midX, y: l.bounds.midY), to: window.layer)
            let captureW = Float(bounds.width  * liquidGlass.backgroundTextureSizeCoefficient)
            let captureH = Float(bounds.height * liquidGlass.backgroundTextureSizeCoefficient)
            uniformsBuffer.contents()
                .assumingMemoryBound(to: LiquidGlass.ShaderUniforms.self)
                .pointee.captureOffset = SIMD2<Float>(
                    captureW > 0 ? Float(screenPos.x - lastCapturedCenter.x) / captureW : 0,
                    captureH > 0 ? Float(screenPos.y - lastCapturedCenter.y) / captureH : 0
                )
        }

        encoder.setRenderPipelineState(LiquidGlassRenderer.shared.pipelineState)
        encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
        
        if let texture = backgroundTexture {
            encoder.setFragmentTexture(texture, index: 0)
        }

        // Draw fullscreen quad (vertices generated in vertex shader)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

extension UIColor {
    func toSimdFloat4() -> SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return .init(x: Float(r), y: Float(g), z: Float(b), w: Float(a))
    }
}

// Helpers: Lerp for damping, UIColor to Half4
//private func lerp(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
//    return a * (1 - t) + b * t
//}

extension UIView {
    /// Finds the root view in the view hierarchy.
    func findRootView() -> UIView? {
        var current: UIView? = superview
        while let parent = current?.superview {
            current = parent
        }
        return current
    }
}
