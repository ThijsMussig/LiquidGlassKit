/*
 * LiquidGlassAL.x  –  App Library Metal Glass
 *
 * Replaces the LiquidGlassKit-based App Library pod rendering with a
 * custom Metal renderer based on winaviation-tweaks/liquidass.
 * The renderer directly samples a pre-captured wallpaper texture and
 * applies GPU-computed edge displacement + specular highlight.
 *
 * Scope: SBHLibraryCategoryPodBackgroundView (the category pod cards).
 *        Suggestions pod and search bar keep the LiquidGlassKit path.
 *
 * Original rendering code © winaviation-tweaks/liquidass, adapted here
 * under the same open-source spirit with renamed symbols and our own
 * preferences layer.
 */

#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Preferences (our own suite, same keys as the rest of the tweak)
// ─────────────────────────────────────────────────────────────────────────────
static NSString *const kALSuite = @"com.yourhandle.liquidglass";

static NSUserDefaults *LGAL_prefs(void) {
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [[NSUserDefaults alloc] initWithSuiteName:kALSuite]; });
    return d;
}

static BOOL LGAL_enabled(void) {
    id v = [LGAL_prefs() objectForKey:@"enabled"];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : YES;
}
static BOOL LGAL_libraryEnabled(void) {
    if (!LGAL_enabled()) return NO;
    id v = [LGAL_prefs() objectForKey:@"libraryPodEnabled"];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : YES;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Metal Shader (runtime-compiled, avoids needing a pre-built .metallib)
// ─────────────────────────────────────────────────────────────────────────────
static NSString * const kALMetalSource =
    @"// fullscreen quad + glass shading\n"
    "// kept as a string so the tweak can compile it at runtime\n"
    "\n"
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct Uniforms {\n"
    "    float2 resolution;\n"
    "    float2 screenResolution;\n"
    "    float2 cardOrigin;\n"
    "    float2 wallpaperResolution;\n"
    "    float  radius;\n"
    "    float  bezelWidth;\n"
    "    float  glassThickness;\n"
    "    float  refractionScale;\n"
    "    float  refractiveIndex;\n"
    "    float  specularOpacity;\n"
    "    float  specularAngle;\n"
    "    float  blur;\n"
    "    float2 wallpaperOrigin;\n"
    "};\n"
    "\n"
    "kernel void blurH(texture2d<float, access::read>  src    [[texture(0)]],\n"
    "                  texture2d<float, access::write> dst    [[texture(1)]],\n"
    "                  constant float&                 radius [[buffer(0)]],\n"
    "                  uint2 gid [[thread_position_in_grid]]) {\n"
    "    uint W = src.get_width(), H = src.get_height();\n"
    "    if (gid.x >= W || gid.y >= H) return;\n"
    "    if (radius < 0.5) { dst.write(src.read(gid), gid); return; }\n"
    "    float4 acc = float4(0);\n"
    "    float  wgt = 0;\n"
    "    int    r   = int(ceil(radius * 2.5));\n"
    "    for (int dx = -r; dx <= r; dx++) {\n"
    "        uint2 p = uint2(clamp(int(gid.x) + dx, 0, int(W) - 1), gid.y);\n"
    "        float  s = dx / max(radius, 0.001);\n"
    "        float  w = exp(-0.5 * s * s);\n"
    "        acc += src.read(p) * w;\n"
    "        wgt += w;\n"
    "    }\n"
    "    dst.write(acc / wgt, gid);\n"
    "}\n"
    "\n"
    "kernel void blurV(texture2d<float, access::read>  src    [[texture(0)]],\n"
    "                  texture2d<float, access::write> dst    [[texture(1)]],\n"
    "                  constant float&                 radius [[buffer(0)]],\n"
    "                  uint2 gid [[thread_position_in_grid]]) {\n"
    "    uint W = src.get_width(), H = src.get_height();\n"
    "    if (gid.x >= W || gid.y >= H) return;\n"
    "    if (radius < 0.5) { dst.write(src.read(gid), gid); return; }\n"
    "    float4 acc = float4(0);\n"
    "    float  wgt = 0;\n"
    "    int    r   = int(ceil(radius * 2.5));\n"
    "    for (int dy = -r; dy <= r; dy++) {\n"
    "        uint2 p = uint2(gid.x, clamp(int(gid.y) + dy, 0, int(H) - 1));\n"
    "        float  s = dy / max(radius, 0.001);\n"
    "        float  w = exp(-0.5 * s * s);\n"
    "        acc += src.read(p) * w;\n"
    "        wgt += w;\n"
    "    }\n"
    "    dst.write(acc / wgt, gid);\n"
    "}\n"
    "\n"
    "float2 refractRay(float2 normal, float eta) {\n"
    "    float cosI = -normal.y;\n"
    "    float k    = 1.0 - eta * eta * (1.0 - cosI * cosI);\n"
    "    if (k < 0.0) return float2(0.0);\n"
    "    float kSqrt = sqrt(k);\n"
    "    return float2(\n"
    "        -(eta * cosI + kSqrt) * normal.x,\n"
    "         eta - (eta * cosI + kSqrt) * normal.y\n"
    "    );\n"
    "}\n"
    "\n"
    "float surfaceConvexSquircle(float x) {\n"
    "    return pow(1.0 - pow(1.0 - x, 4.0), 0.25);\n"
    "}\n"
    "\n"
    "float rawRefraction(float bezelRatio, float glassThickness, float bezelWidth, float eta) {\n"
    "    float x     = clamp(bezelRatio, 0.05, 0.95);\n"
    "    float y     = surfaceConvexSquircle(x);\n"
    "    float y2    = surfaceConvexSquircle(x + 0.001);\n"
    "    float deriv = (y2 - y) / 0.001;\n"
    "    float mag   = sqrt(deriv * deriv + 1.0);\n"
    "    float2 n    = float2(-deriv / mag, -1.0 / mag);\n"
    "    float2 r    = refractRay(n, eta);\n"
    "    if (length(r) < 0.0001 || abs(r.y) < 0.0001) return 0.0;\n"
    "    float remaining = y * bezelWidth + glassThickness;\n"
    "    return r.x * (remaining / r.y);\n"
    "}\n"
    "\n"
    "float displacementAtRatio(float bezelRatio, float glassThickness,\n"
    "                          float bezelWidth, float eta) {\n"
    "    float peak = rawRefraction(0.05, glassThickness, bezelWidth, eta);\n"
    "    if (abs(peak) < 0.0001) return 0.0;\n"
    "    float raw     = rawRefraction(bezelRatio, glassThickness, bezelWidth, eta);\n"
    "    float norm    = raw / peak;\n"
    "    float falloff = 1.0 - smoothstep(0.0, 1.0, bezelRatio);\n"
    "    return norm * falloff;\n"
    "}\n"
    "\n"
    "struct VertexOut {\n"
    "    float4 position [[position]];\n"
    "    float2 localUV;\n"
    "};\n"
    "\n"
    "vertex VertexOut vertexShader(uint vid [[vertex_id]]) {\n"
    "    float2 pos[6] = {\n"
    "        float2(-1,-1), float2(1,-1), float2(-1,1),\n"
    "        float2(-1, 1), float2(1,-1), float2(1, 1)\n"
    "    };\n"
    "    float2 uv[6] = {\n"
    "        float2(0,1), float2(1,1), float2(0,0),\n"
    "        float2(0,0), float2(1,1), float2(1,0)\n"
    "    };\n"
    "    VertexOut out;\n"
    "    out.position = float4(pos[vid], 0, 1);\n"
    "    out.localUV  = uv[vid];\n"
    "    return out;\n"
    "}\n"
    "\n"
    "fragment float4 fragmentShader(VertexOut                in         [[stage_in]],\n"
    "                               texture2d<float>       blurredTex [[texture(0)]],\n"
    "                               constant Uniforms&     u          [[buffer(0)]]) {\n"
    "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
    "\n"
    "    float2 px = in.localUV * u.resolution;\n"
    "    float W = u.resolution.x, H = u.resolution.y;\n"
    "    float R = u.radius, bezel = u.bezelWidth;\n"
    "    float eta = 1.0 / u.refractiveIndex;\n"
    "\n"
    "    bool inLeft   = px.x < R,      inRight  = px.x > W - R;\n"
    "    bool inTop    = px.y < R,      inBottom = px.y > H - R;\n"
    "    bool inCorner = (inLeft || inRight) && (inTop || inBottom);\n"
    "\n"
    "    float cx = inLeft ? px.x - R : inRight  ? px.x - (W - R) : 0.0;\n"
    "    float cy = inTop  ? px.y - R : inBottom ? px.y - (H - R) : 0.0;\n"
    "    float distFromCenter = length(float2(cx, cy));\n"
    "\n"
    "    if (inCorner && distFromCenter > R + 1.0) discard_fragment();\n"
    "\n"
    "    float distFromSide;\n"
    "    float2 dir;\n"
    "    if (inCorner) {\n"
    "        distFromSide = max(0.0, R - distFromCenter);\n"
    "        dir = distFromCenter > 0.001 ? normalize(float2(cx, cy)) : float2(0);\n"
    "    } else {\n"
    "        float dL = px.x, dR = W - px.x, dT = px.y, dB = H - px.y;\n"
    "        float dMin = min(min(dL, dR), min(dT, dB));\n"
    "        distFromSide = dMin;\n"
    "        dir = float2(\n"
    "            (dL < dR  && dL == dMin) ? -1.0 : (dR <= dL && dR == dMin) ? 1.0 : 0.0,\n"
    "            (dT < dB  && dT == dMin) ? -1.0 : (dB <= dT && dB == dMin) ? 1.0 : 0.0\n"
    "        );\n"
    "    }\n"
    "\n"
    "    float edgeOpacity = inCorner ? clamp(1.0 - max(0.0, distFromCenter - R), 0.0, 1.0) : 1.0;\n"
    "    float bezelRatio  = clamp(distFromSide / bezel, 0.0, 1.0);\n"
    "\n"
    "    float normDisp = (distFromSide < bezel)\n"
    "        ? displacementAtRatio(bezelRatio, u.glassThickness, bezel, eta)\n"
    "        : 0.0;\n"
    "    float2 dispPx = -dir * normDisp * bezel * u.refractionScale * edgeOpacity;\n"
    "\n"
    "    float2 screenPx = u.cardOrigin + px + dispPx;\n"
    "    float2 imgPx    = screenPx - u.wallpaperOrigin;\n"
    "    float2 sampleUV = clamp(imgPx / u.wallpaperResolution, 0.0, 1.0);\n"
    "\n"
    "    float4 bgColor = blurredTex.sample(s, sampleUV);\n"
    "\n"
    "    float2 lightDir   = float2(cos(u.specularAngle), -sin(u.specularAngle));\n"
    "    float  specDot    = dot(dir, lightDir);\n"
    "    float  strokePx   = 1.5;\n"
    "    float  strokeMask = clamp(1.0 - (distFromSide / strokePx), 0.0, 1.0);\n"
    "\n"
    "    float  lobeStart  = 0.66;\n"
    "    float  lobeWidth  = 0.14;\n"
    "    float  primary    = smoothstep(lobeStart, lobeStart + lobeWidth,  specDot);\n"
    "    float  secondary  = smoothstep(lobeStart, lobeStart + lobeWidth, -specDot);\n"
    "    float  cornerSpec = smoothstep(0.52, 0.88, abs(specDot));\n"
    "    float  specLobe   = inCorner ? cornerSpec : (primary + secondary);\n"
    "\n"
    "    float  specular   = specLobe * strokeMask * u.specularOpacity * edgeOpacity;\n"
    "    bgColor.rgb += specular;\n"
    "\n"
    "    return float4(bgColor.rgb, edgeOpacity);\n"
    "}\n"
    "";

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Uniforms
// ─────────────────────────────────────────────────────────────────────────────
typedef struct {
    vector_float2 resolution;
    vector_float2 screenResolution;
    vector_float2 cardOrigin;
    vector_float2 wallpaperResolution;
    float         radius;
    float         bezelWidth;
    float         glassThickness;
    float         refractionScale;
    float         refractiveIndex;
    float         specularOpacity;
    float         specularAngle;
    float         blur;
    vector_float2 wallpaperOrigin;
} LGALUniforms;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Shared color space
// ─────────────────────────────────────────────────────────────────────────────
static CGColorSpaceRef LGAL_sharedRGBColorSpace(void) {
    static CGColorSpaceRef sCS = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sCS = CGColorSpaceCreateDeviceRGB(); });
    return sCS;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Image validation
// ─────────────────────────────────────────────────────────────────────────────
static BOOL LGAL_imageLooksBlack(UIImage *img) {
    if (!img) return YES;
    CGImageRef cg = img.CGImage;
    if (!cg) return YES;
    unsigned char px[9 * 4] = {0};
    CGContextRef ctx = CGBitmapContextCreate(px, 3, 3, 8, 3 * 4,
        LGAL_sharedRGBColorSpace(), kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) return YES;
    CGContextDrawImage(ctx, CGRectMake(0, 0, 3, 3), cg);
    CGContextRelease(ctx);
    int nonBlack = 0;
    for (int i = 0; i < 9; i++)
        if (px[i*4] + px[i*4+1] + px[i*4+2] > 30) nonBlack++;
    return nonBlack < 3;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Wallpaper window / image finding
// ─────────────────────────────────────────────────────────────────────────────
static UIView *LGAL_findSubviewOfClass(UIView *root, Class cls) {
    if (![root isKindOfClass:cls]) {
        for (UIView *sub in root.subviews) {
            UIView *r = LGAL_findSubviewOfClass(sub, cls);
            if (r) return r;
        }
        return nil;
    }
    return root;
}

static UIWindow *LGAL_getWallpaperWindow(void) {
    static Class wCls, sceneCls;
    if (!sceneCls) sceneCls = [UIWindowScene class];
    if (!wCls)    wCls    = NSClassFromString(@"_SBWallpaperWindow");
    UIWindow *fallback = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:sceneCls]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if ([w isKindOfClass:wCls]) return w;
            if (!fallback) {
                static Class wsCls;
                if (!wsCls) wsCls = NSClassFromString(@"_SBWallpaperSecureWindow");
                if ([w isKindOfClass:wsCls]) fallback = w;
            }
        }
    }
    return fallback;
}

static UIImageView *LGAL_getWallpaperImageView(UIWindow *win) {
    static Class repCls, staticCls, ivCls;
    if (!repCls)    repCls    = NSClassFromString(@"PBUISnapshotReplicaView");
    if (!staticCls) staticCls = NSClassFromString(@"SBFStaticWallpaperImageView");
    if (!ivCls)     ivCls     = [UIImageView class];
    UIView *replica = LGAL_findSubviewOfClass(win, repCls);
    if (replica) {
        for (UIView *sub in replica.subviews)
            if ([sub isKindOfClass:ivCls] && ((UIImageView *)sub).image)
                return (UIImageView *)sub;
    }
    UIImageView *iv = (UIImageView *)LGAL_findSubviewOfClass(win, staticCls);
    return iv.image ? iv : nil;
}

static CGPoint LGAL_centeredWallpaperOriginForImage(UIImage *image) {
    if (!image) return CGPointZero;
    CGSize screen = UIScreen.mainScreen.bounds.size;
    return CGPointMake((screen.width - image.size.width) * 0.5,
                       (screen.height - image.size.height) * 0.5);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – SpringBoard wallpaper file decoding (iOS < 16 fallback)
// ─────────────────────────────────────────────────────────────────────────────
static BOOL LGAL_isAtLeastiOS16(void) {
    static BOOL result = NO, checked = NO;
    if (!checked) {
        checked = YES;
        result  = [[NSProcessInfo processInfo]
                    isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){16, 0, 0}];
    }
    return result;
}

static NSString *LGAL_springBoardWallpaperDirectory(void) {
    static NSString *sPath = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *candidates = @[@"/var/mobile/Library/SpringBoard"];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *path in candidates) {
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir) {
                sPath = [path copy]; break;
            }
        }
    });
    return sPath;
}

static NSString *LGAL_preferredSpringBoardWallpaperPath(void) {
    if (LGAL_isAtLeastiOS16()) return nil;
    NSString *root = LGAL_springBoardWallpaperDirectory();
    if (!root.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *candidates = @[
        [root stringByAppendingPathComponent:@"HomeBackground.cpbitmap"],
        [root stringByAppendingPathComponent:@"HomeBackgroundThumbnail.jpg"],
    ];
    for (NSString *p in candidates) if ([fm fileExistsAtPath:p]) return p;
    return nil;
}

static UIImage *LGAL_decodeCPBitmapAtPath(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (![data isKindOfClass:[NSData class]] || data.length < 24) return nil;
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    uint32_t wLE = 0, hLE = 0;
    memcpy(&wLE, bytes + length - (4 * 5), 4);
    memcpy(&hLE, bytes + length - (4 * 4), 4);
    size_t width = CFSwapInt32LittleToHost(wLE), height = CFSwapInt32LittleToHost(hLE);
    if (!width || !height || width > 10000 || height > 10000) return nil;
    static const size_t kAligns[] = { 16, 8, 4 };
    size_t lineSize = 0, chosenAlign = 0;
    for (size_t i = 0; i < 3; i++) {
        size_t align = kAligns[i];
        size_t ls = ((width + align - 1) / align) * align;
        if (ls * height * 4 <= length - 20) { lineSize = ls; chosenAlign = align; break; }
    }
    if (!lineSize || !chosenAlign) return nil;
    NSMutableData *rgba = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *dst = rgba.mutableBytes;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            size_t src = (x * 4) + (y * lineSize * 4);
            size_t d   = (x * 4) + (y * width * 4);
            if (src + 3 >= length) return nil;
            dst[d+0] = bytes[src+2]; dst[d+1] = bytes[src+1];
            dst[d+2] = bytes[src+0]; dst[d+3] = bytes[src+3];
        }
    }
    CGDataProviderRef prov = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
    if (!prov) return nil;
    CGImageRef cg = CGImageCreate(width, height, 8, 32, width * 4, LGAL_sharedRGBColorSpace(),
        kCGBitmapByteOrderDefault | kCGImageAlphaLast, prov, NULL, NO, kCGRenderingIntentDefault);
    CGDataProviderRelease(prov);
    if (!cg) return nil;
    CGFloat scale = UIScreen.mainScreen.scale ?: 1.0;
    UIImage *img = [UIImage imageWithCGImage:cg scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return img;
}

static UIImage *LGAL_loadSpringBoardWallpaperImage(void) {
    NSString *path = LGAL_preferredSpringBoardWallpaperPath();
    if (!path) return nil;
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"] ||
        [ext isEqualToString:@"png"])
        return [UIImage imageWithContentsOfFile:path];
    if ([ext isEqualToString:@"cpbitmap"])
        return LGAL_decodeCPBitmapAtPath(path);
    return nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Wallpaper snapshot cache
// ─────────────────────────────────────────────────────────────────────────────
static UIImage *sALCachedSnapshot      = nil;
static UIImage *sALInterceptedWallpaper = nil;

static BOOL LGAL_drawHomescreenWallpaper(CGSize screenSize) {
    UIImage *asset = LGAL_loadSpringBoardWallpaperImage();
    if (asset) {
        CGPoint origin = LGAL_centeredWallpaperOriginForImage(asset);
        [asset drawInRect:CGRectMake(origin.x, origin.y, asset.size.width, asset.size.height)];
        return YES;
    }
    if (sALInterceptedWallpaper) {
        [sALInterceptedWallpaper drawInRect:CGRectMake(0, 0, screenSize.width, screenSize.height)];
        return YES;
    }
    UIWindow *win = LGAL_getWallpaperWindow();
    if (!win) return NO;
    UIImageView *iv = LGAL_getWallpaperImageView(win);
    if (iv.image) {
        [win drawViewHierarchyInRect:CGRectMake(0, 0, screenSize.width, screenSize.height)
                 afterScreenUpdates:NO];
        return YES;
    }
    [win.layer renderInContext:UIGraphicsGetCurrentContext()];
    return YES;
}

static void LGAL_refreshSnapshot(void) {
    if (!LGAL_enabled()) { sALCachedSnapshot = nil; return; }
    UIImage *asset = LGAL_loadSpringBoardWallpaperImage();
    if (asset) { sALCachedSnapshot = asset; return; }
    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    CGFloat scale     = UIScreen.mainScreen.scale;
    UIGraphicsBeginImageContextWithOptions(screenSize, YES, scale);
    BOOL ok = LGAL_drawHomescreenWallpaper(screenSize);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!ok || LGAL_imageLooksBlack(img)) return;
    sALCachedSnapshot = img;
}

static UIImage *LGAL_getSnapshot(CGPoint *outOrigin) {
    if (!LGAL_enabled()) { if (outOrigin) *outOrigin = CGPointZero; return nil; }
    UIImage *asset = LGAL_loadSpringBoardWallpaperImage();
    if (asset && outOrigin)
        *outOrigin = LGAL_centeredWallpaperOriginForImage(asset);
    else if (outOrigin)
        *outOrigin = CGPointZero;
    if (!sALCachedSnapshot) LGAL_refreshSnapshot();
    return sALCachedSnapshot;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Metal Texture Cache (zero-copy CPU → GPU)
// ─────────────────────────────────────────────────────────────────────────────
@interface LGALTextureCache : NSObject
@property (nonatomic, strong) id<MTLTexture> bgTexture;
@property (nonatomic, strong) id<MTLTexture> blurTmpTexture;
@property (nonatomic, strong) id<MTLTexture> blurredTexture;
@property (nonatomic, strong) id bridge;
@property (nonatomic, assign) float          bakedBlurRadius;
@end
@implementation LGALTextureCache @end

@interface LGALZeroCopyBridge : NSObject
@property (nonatomic, strong) id<MTLDevice>       device;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;
@property (nonatomic, assign) CVPixelBufferRef       pixelBuffer;
@property (nonatomic, assign) CVMetalTextureRef      cvTexture;
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (BOOL)setupBufferWithWidth:(size_t)w height:(size_t)h;
- (id<MTLTexture>)renderWithActions:(void (^)(CGContextRef ctx))actions;
@end

@implementation LGALZeroCopyBridge

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (!self) return nil;
    _device = device;
    CVMetalTextureCacheRef cache = NULL;
    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess)
        _textureCache = cache;
    return self;
}

- (void)dealloc {
    if (_cvTexture)    { CFRelease(_cvTexture);    _cvTexture = NULL; }
    if (_pixelBuffer)  { CVPixelBufferRelease(_pixelBuffer); _pixelBuffer = NULL; }
    if (_textureCache) { CFRelease(_textureCache); _textureCache = NULL; }
}

- (BOOL)setupBufferWithWidth:(size_t)w height:(size_t)h {
    if (!_textureCache || !w || !h) return NO;
    if (_cvTexture)   { CFRelease(_cvTexture);   _cvTexture = NULL; }
    if (_pixelBuffer) { CVPixelBufferRelease(_pixelBuffer); _pixelBuffer = NULL; }
    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey:                @YES,
        (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey:              @YES,
        (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey:      @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:               @{}
    };
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &_pixelBuffer) != kCVReturnSuccess)
        return NO;
    CVMetalTextureRef cvTex = NULL;
    if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache,
        _pixelBuffer, nil, MTLPixelFormatBGRA8Unorm, w, h, 0, &cvTex) != kCVReturnSuccess)
        return NO;
    _cvTexture = cvTex;
    return YES;
}

- (id<MTLTexture>)renderWithActions:(void (^)(CGContextRef ctx))actions {
    if (!_pixelBuffer || !_textureCache || !_cvTexture) return nil;
    CVPixelBufferLockBaseAddress(_pixelBuffer, 0);
    void *data = CVPixelBufferGetBaseAddress(_pixelBuffer);
    size_t w = CVPixelBufferGetWidth(_pixelBuffer);
    size_t h = CVPixelBufferGetHeight(_pixelBuffer);
    size_t bpr = CVPixelBufferGetBytesPerRow(_pixelBuffer);
    CGContextRef ctx = CGBitmapContextCreate(data, w, h, 8, bpr,
        LGAL_sharedRGBColorSpace(), kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!ctx) { CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0); return nil; }
    if (actions) actions(ctx);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
    CVMetalTextureCacheFlush(_textureCache, 0);
    return CVMetalTextureGetTexture(_cvTexture);
}
@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Metal Pipeline (shared across all LGALGlassViews)
// ─────────────────────────────────────────────────────────────────────────────
static id<MTLDevice>               sALDevice;
static id<MTLRenderPipelineState>  sALPipeline;
static id<MTLComputePipelineState> sALBlurH;
static id<MTLComputePipelineState> sALBlurV;
static id<MTLCommandQueue>         sALCommandQueue;
static MTLComputePassDescriptor   *sALComputeDesc;
static NSMapTable                 *sALTextureCacheMap;  // UIImage → {scale → LGALTextureCache}

static NSNumber *LGAL_texScaleKey(CGFloat scale) {
    return @((NSInteger)lrint(scale * 1000.0));
}
static LGALTextureCache *LGAL_getCachedTexture(UIImage *image, CGFloat scale) {
    return [sALTextureCacheMap objectForKey:image][LGAL_texScaleKey(scale)];
}
static void LGAL_setCachedTexture(UIImage *image, CGFloat scale, LGALTextureCache *entry) {
    NSMutableDictionary *d = [sALTextureCacheMap objectForKey:image];
    if (!d) { d = [NSMutableDictionary dictionary]; [sALTextureCacheMap setObject:d forKey:image]; }
    d[LGAL_texScaleKey(scale)] = entry;
}

static void LGAL_prewarmPipelines(void) {
    sALDevice = MTLCreateSystemDefaultDevice();
    if (!sALDevice) return;
    NSError *err = nil;
    id<MTLLibrary> lib = [sALDevice newLibraryWithSource:kALMetalSource
                                                  options:[MTLCompileOptions new]
                                                    error:&err];
    if (!lib) { NSLog(@"[LiquidGlassAL] Metal compile error: %@", err); return; }
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction   = [lib newFunctionWithName:@"vertexShader"];
    desc.fragmentFunction = [lib newFunctionWithName:@"fragmentShader"];
    MTLRenderPipelineColorAttachmentDescriptor *ca = desc.colorAttachments[0];
    ca.pixelFormat                 = MTLPixelFormatBGRA8Unorm;
    ca.blendingEnabled             = YES;
    ca.rgbBlendOperation           = MTLBlendOperationAdd;
    ca.alphaBlendOperation         = MTLBlendOperationAdd;
    ca.sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
    ca.destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
    ca.sourceAlphaBlendFactor      = MTLBlendFactorOne;
    ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    sALPipeline = [sALDevice newRenderPipelineStateWithDescriptor:desc error:&err];
    sALBlurH = [sALDevice newComputePipelineStateWithFunction:[lib newFunctionWithName:@"blurH"] error:&err];
    sALBlurV = [sALDevice newComputePipelineStateWithFunction:[lib newFunctionWithName:@"blurV"] error:&err];
    sALCommandQueue = [sALDevice newCommandQueue];
    sALComputeDesc  = [MTLComputePassDescriptor computePassDescriptor];
    sALTextureCacheMap = [NSMapTable weakToStrongObjectsMapTable];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – LGALGlassView  (Metal-based glass card renderer)
// ─────────────────────────────────────────────────────────────────────────────
@interface LGALGlassView : UIView <MTKViewDelegate>
@property (nonatomic, strong) UIImage *wallpaperImage;
@property (nonatomic, assign) CGPoint  wallpaperOrigin;
@property (nonatomic, assign) CGFloat  cornerRadius;
@property (nonatomic, assign) CGFloat  bezelWidth;
@property (nonatomic, assign) CGFloat  glassThickness;
@property (nonatomic, assign) CGFloat  refractionScale;
@property (nonatomic, assign) CGFloat  refractiveIndex;
@property (nonatomic, assign) CGFloat  specularOpacity;
@property (nonatomic, assign) CGFloat  blur;
@property (nonatomic, assign) CGFloat  wallpaperScale;
@property (nonatomic, assign) BOOL     releasesWallpaperAfterUpload;
- (instancetype)initWithFrame:(CGRect)frame
                    wallpaper:(UIImage *)wallpaper
               wallpaperOrigin:(CGPoint)origin;
- (void)updateOrigin;
- (void)scheduleDraw;
@end

@implementation LGALGlassView {
    id<MTLTexture>  _bgTexture;
    id<MTLTexture>  _blurTmpTexture;
    id<MTLTexture>  _blurredTexture;
    LGALTextureCache *_cacheEntry;
    MTKView         *_mtkView;
    BOOL             _needsBlurBake;
    float            _lastBakedBlurRadius;
    CGPoint          _wallpaperOriginPt;
    CGSize           _sourceWallpaperPixelSize;
    CGRect           _cachedVisualRectPx;
    CGSize           _cachedDrawableSizePx;
    float            _cachedVisualScale;
    BOOL             _hasCachedVisualMetrics;
    BOOL             _drawScheduled;
    CGFloat          _effectiveTextureScale;
    CGSize           _lastLayoutBounds;
    CFTimeInterval   _lastDrawSubmissionTime;
}

- (instancetype)initWithFrame:(CGRect)frame wallpaper:(UIImage *)wallpaper wallpaperOrigin:(CGPoint)origin {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _cornerRadius        = 20.2;
    _bezelWidth          = 18.0;
    _glassThickness      = 150.0;
    _refractionScale     = 1.8;
    _refractiveIndex     = 1.2;
    _specularOpacity     = 0.8;
    _blur                = 25.0;
    _wallpaperScale      = 0.1;
    _wallpaperOriginPt   = origin;
    _needsBlurBake       = YES;
    _lastBakedBlurRadius = -1;
    _effectiveTextureScale = -1;
    _lastLayoutBounds    = CGSizeZero;
    _lastDrawSubmissionTime = 0;
    if (!sALDevice) return nil;
    _mtkView = [[MTKView alloc] initWithFrame:self.bounds device:sALDevice];
    _mtkView.colorPixelFormat   = MTLPixelFormatBGRA8Unorm;
    _mtkView.framebufferOnly    = NO;
    _mtkView.enableSetNeedsDisplay = NO;
    _mtkView.paused             = YES;
    _mtkView.delegate           = self;
    _mtkView.autoresizingMask   = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtkView.userInteractionEnabled = NO;
    _mtkView.backgroundColor    = [UIColor clearColor];
    _mtkView.opaque             = NO;
    [self addSubview:_mtkView];
    self.userInteractionEnabled = NO;
    self.backgroundColor        = [UIColor clearColor];
    self.opaque                 = NO;
    self.wallpaperImage         = wallpaper;
    return self;
}

- (void)setWallpaperImage:(UIImage *)image {
    if (_wallpaperImage == image) return;
    _wallpaperImage = image;
    if (!image) { _bgTexture = nil; _blurTmpTexture = nil; _blurredTexture = nil; return; }
    if (_bgTexture) {
        CGFloat prev = _effectiveTextureScale;
        NSUInteger w = (NSUInteger)(image.size.width  * image.scale);
        NSUInteger h = (NSUInteger)(image.size.height * image.scale);
        CGFloat next = [self _recommendedTextureScaleForSourceWidth:w height:h];
        if (fabs(prev - next) > 0.001f || !_bgTexture)
            [self _reloadTexture];
    } else {
        [self _reloadTexture];
    }
    [self scheduleDraw];
}

- (CGFloat)_recommendedTextureScaleForSourceWidth:(NSUInteger)srcW height:(NSUInteger)srcH {
    CGFloat userScale  = fmax(0.1, fmin(_wallpaperScale, 1.0));
    CGFloat screenScale = UIScreen.mainScreen.scale;
    CGFloat viewMaxPx   = MAX(self.bounds.size.width, self.bounds.size.height) * screenScale;
    CGFloat srcMaxPx    = MAX((CGFloat)srcW, (CGFloat)srcH);
    if (viewMaxPx <= 1.0 || srcMaxPx <= 1.0) return userScale;
    CGFloat adaptive = (viewMaxPx * 2.4) / srcMaxPx;
    adaptive = fmax(0.16, fmin(adaptive, 1.0));
    // cap for App Library pods
    CGFloat cap = 0.35;
    return fmin(userScale, fmin(adaptive, cap));
}

- (void)_reloadTexture {
    UIImage *image = _wallpaperImage;
    if (!image) return;
    NSUInteger srcW = (NSUInteger)(image.size.width  * image.scale);
    NSUInteger srcH = (NSUInteger)(image.size.height * image.scale);
    CGFloat textureScale = [self _recommendedTextureScaleForSourceWidth:srcW height:srcH];
    _effectiveTextureScale   = textureScale;
    _sourceWallpaperPixelSize = CGSizeMake(srcW, srcH);
    NSUInteger w = MAX((NSUInteger)1, (NSUInteger)lrint(srcW * textureScale));
    NSUInteger h = MAX((NSUInteger)1, (NSUInteger)lrint(srcH * textureScale));
    LGALTextureCache *cached = LGAL_getCachedTexture(image, textureScale);
    if (cached) {
        _cacheEntry     = cached;
        _bgTexture      = cached.bgTexture;
        _blurTmpTexture = cached.blurTmpTexture;
        _blurredTexture = cached.blurredTexture;
        if (cached.bakedBlurRadius == _blur) {
            _needsBlurBake       = NO;
            _lastBakedBlurRadius = cached.bakedBlurRadius;
        } else {
            _needsBlurBake       = YES;
            _lastBakedBlurRadius = -1;
        }
        if (_releasesWallpaperAfterUpload) _wallpaperImage = nil;
        return;
    }
    LGALZeroCopyBridge *bridge = [[LGALZeroCopyBridge alloc] initWithDevice:sALDevice];
    if (![bridge setupBufferWithWidth:w height:h]) return;
    _bgTexture = [bridge renderWithActions:^(CGContextRef ctx) {
        CGContextClearRect(ctx, CGRectMake(0, 0, w, h));
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image.CGImage);
    }];
    if (!_bgTexture) return;
    MTLTextureDescriptor *rd =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:w height:h mipmapped:NO];
    rd.usage        = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    _blurTmpTexture = [sALDevice newTextureWithDescriptor:rd];
    _blurredTexture = [sALDevice newTextureWithDescriptor:rd];
    LGALTextureCache *entry = [LGALTextureCache new];
    entry.bgTexture         = _bgTexture;
    entry.blurTmpTexture    = _blurTmpTexture;
    entry.blurredTexture    = _blurredTexture;
    entry.bridge            = bridge;
    entry.bakedBlurRadius   = -1;
    _cacheEntry             = entry;
    LGAL_setCachedTexture(image, textureScale, entry);
    _needsBlurBake       = YES;
    _lastBakedBlurRadius = -1;
    if (_releasesWallpaperAfterUpload) _wallpaperImage = nil;
}

- (BOOL)_refreshVisualMetrics {
    CGFloat scale = UIScreen.mainScreen.scale;
    CGRect visualRect;
    CALayer *pres = self.layer.presentationLayer ?: self.layer;
    CALayer *root = pres;
    while (root.superlayer) root = root.superlayer.presentationLayer ?: root.superlayer;
    if (root != pres) {
        CGRect vr = pres.bounds;
        CALayer *cur = pres;
        while (cur && cur != root) {
            CALayer *up = cur.superlayer;
            if (!up) break;
            CALayer *upPres = up.presentationLayer ?: up;
            vr = [cur convertRect:vr toLayer:upPres];
            cur = upPres;
        }
        visualRect = CGRectMake(vr.origin.x * scale, vr.origin.y * scale,
                                vr.size.width * scale, vr.size.height * scale);
    } else {
        CGRect screenRect = [self convertRect:self.bounds toView:nil];
        visualRect = CGRectMake(screenRect.origin.x * scale, screenRect.origin.y * scale,
                                screenRect.size.width * scale, screenRect.size.height * scale);
    }
    CGSize drawableSize = _mtkView.drawableSize;
    if (drawableSize.width < 1 || drawableSize.height < 1)
        drawableSize = CGSizeMake(MAX(1.0, floor(self.bounds.size.width * scale)),
                                  MAX(1.0, floor(self.bounds.size.height * scale)));
    CGFloat visualScale = (drawableSize.width > 0.5)
        ? (float)(CGRectGetWidth(visualRect) / drawableSize.width) : 1.0f;
    if (_hasCachedVisualMetrics
        && fabs(CGRectGetMinX(_cachedVisualRectPx) - CGRectGetMinX(visualRect)) < 0.5f
        && fabs(CGRectGetMinY(_cachedVisualRectPx) - CGRectGetMinY(visualRect)) < 0.5f
        && fabs(CGRectGetWidth(_cachedVisualRectPx) - CGRectGetWidth(visualRect)) < 0.5f
        && fabs(CGRectGetHeight(_cachedVisualRectPx) - CGRectGetHeight(visualRect)) < 0.5f
        && fabs(_cachedDrawableSizePx.width - drawableSize.width) < 0.5f
        && fabs(_cachedDrawableSizePx.height - drawableSize.height) < 0.5f
        && fabs(_cachedVisualScale - visualScale) < 0.001f)
        return NO;
    _cachedVisualRectPx    = visualRect;
    _cachedDrawableSizePx  = drawableSize;
    _cachedVisualScale     = visualScale;
    _hasCachedVisualMetrics = YES;
    return YES;
}

- (void)updateOrigin {
    if (!_mtkView.superview) return;
    if (!_bgTexture && self.wallpaperImage) [self _reloadTexture];
    if (self.hidden || self.alpha <= 0.01f || self.layer.opacity <= 0.01f) return;
    BOOL metricsChanged = [self _refreshVisualMetrics];
    if (!metricsChanged && !_needsBlurBake) return;
    [self scheduleDraw];
}

- (void)scheduleDraw {
    if (!_mtkView.superview) return;
    if (self.hidden || self.alpha <= 0.01f || self.layer.opacity <= 0.01f) return;
    [_mtkView draw];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat scale = UIScreen.mainScreen.scale;
    CGSize sz = self.bounds.size;
    CGSize drawable = CGSizeMake(MAX(1.0, floor(sz.width * scale)),
                                 MAX(1.0, floor(sz.height * scale)));
    if (!CGSizeEqualToSize(_mtkView.drawableSize, drawable)) {
        _mtkView.drawableSize = drawable;
        _hasCachedVisualMetrics = NO;
    }
    if (!CGSizeEqualToSize(_lastLayoutBounds, sz)) {
        _lastLayoutBounds = sz;
        [self scheduleDraw];
    }
}

- (void)_runBlurPasses:(float)radius commandBuffer:(id<MTLCommandBuffer>)cmdBuf {
    if (!_bgTexture || !_blurredTexture) return;
    if (radius < 0.5f) {
        id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
        if (!blit) return;
        [blit copyFromTexture:_bgTexture sourceSlice:0 sourceLevel:0
                 sourceOrigin:MTLOriginMake(0,0,0)
                   sourceSize:MTLSizeMake(_bgTexture.width, _bgTexture.height, 1)
                    toTexture:_blurredTexture destinationSlice:0 destinationLevel:0
            destinationOrigin:MTLOriginMake(0,0,0)];
        [blit endEncoding];
        return;
    }
    float sigma = MAX(radius * 0.5f, 0.1f);
    MPSImageGaussianBlur *blur = [[MPSImageGaussianBlur alloc] initWithDevice:sALDevice sigma:sigma];
    blur.edgeMode = MPSImageEdgeModeClamp;
    [blur encodeToCommandBuffer:cmdBuf sourceTexture:_bgTexture destinationTexture:_blurredTexture];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    _hasCachedVisualMetrics = NO;
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_bgTexture && self.wallpaperImage) [self _reloadTexture];
    if (!sALPipeline || !_bgTexture || !_blurredTexture) return;
    [self _refreshVisualMetrics];
    CGSize drawableSize = _cachedDrawableSizePx;
    if (drawableSize.width < 1 || drawableSize.height < 1) return;
    id<CAMetalDrawable>     drawable = view.currentDrawable;
    MTLRenderPassDescriptor *passDesc = view.currentRenderPassDescriptor;
    if (!drawable || !passDesc) return;
    id<MTLCommandBuffer> cmdBuf = [sALCommandQueue commandBuffer];
    if (!cmdBuf) return;
    CGFloat scale = UIScreen.mainScreen.scale;
    static CGFloat screenW = 0, screenH = 0;
    if (screenW <= 0) {
        screenW = UIScreen.mainScreen.bounds.size.width  * scale;
        screenH = UIScreen.mainScreen.bounds.size.height * scale;
    }
    float imgW      = (float)_bgTexture.width;
    float imgH      = (float)_bgTexture.height;
    float fillScale = fmaxf((float)screenW / imgW, (float)screenH / imgH);
    float blurPx    = (float)_blur * (float)scale / fillScale;
    if (_needsBlurBake || fabsf(_lastBakedBlurRadius - blurPx) > 0.01f) {
        [self _runBlurPasses:blurPx commandBuffer:cmdBuf];
        _needsBlurBake       = NO;
        _lastBakedBlurRadius = blurPx;
        if (_cacheEntry) _cacheEntry.bakedBlurRadius = (float)_blur;
    }
    float visW = (float)CGRectGetWidth(_cachedVisualRectPx);
    float visH = (float)CGRectGetHeight(_cachedVisualRectPx);
    LGALUniforms u;
    u.resolution          = (vector_float2){ visW, visH };
    u.screenResolution    = (vector_float2){ (float)screenW, (float)screenH };
    u.cardOrigin          = (vector_float2){ (float)CGRectGetMinX(_cachedVisualRectPx),
                                             (float)CGRectGetMinY(_cachedVisualRectPx) };
    u.wallpaperResolution = (vector_float2){ (float)_sourceWallpaperPixelSize.width,
                                             (float)_sourceWallpaperPixelSize.height };
    u.radius              = (float)(_cornerRadius * _cachedVisualScale * scale);
    u.bezelWidth          = (float)(_bezelWidth   * _cachedVisualScale * scale);
    u.glassThickness      = (float)_glassThickness;
    u.refractionScale     = (float)_refractionScale;
    u.refractiveIndex     = (float)_refractiveIndex;
    u.specularOpacity     = (float)_specularOpacity;
    u.specularAngle       = 2.2689280f;
    u.blur                = blurPx;
    u.wallpaperOrigin     = (vector_float2){ (float)(_wallpaperOriginPt.x * scale),
                                             (float)(_wallpaperOriginPt.y * scale) };
    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:passDesc];
    if (!enc) { [cmdBuf commit]; return; }
    [enc setRenderPipelineState:sALPipeline];
    [enc setVertexBytes:&u   length:sizeof(u) atIndex:0];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentTexture:_blurredTexture atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];
    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Registered glass views + display link
// ─────────────────────────────────────────────────────────────────────────────
static NSPointerArray   *sALGlassViews  = nil;  // weak references
static CADisplayLink    *sALDisplayLink = nil;
static NSObject         *sALTicker      = nil;

static void LGAL_stopDisplayLink(void);  // forward declaration

@interface LGALTicker : NSObject {
    NSUInteger _idleFrames;
}
- (void)tick:(CADisplayLink *)dl;
@end
@implementation LGALTicker
- (void)tick:(CADisplayLink *)dl {
    if (!sALGlassViews) { LGAL_stopDisplayLink(); return; }
    [sALGlassViews compact];
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    BOOL anyActive = NO;
    for (NSUInteger i = 0; i < sALGlassViews.count; i++) {
        LGALGlassView *g = (__bridge LGALGlassView *)[sALGlassViews pointerAtIndex:i];
        if (!g || !g.superview || !g.window) continue;
        if (g.hidden || g.alpha <= 0.01f) continue;
        CGRect approx = [g convertRect:g.bounds toView:nil];
        if (!CGRectIntersectsRect(CGRectInset(screenBounds, -64, -64), approx)) continue;
        [g updateOrigin];
        anyActive = YES;
    }
    // Stop display link after ~1 second of no visible glass views
    if (anyActive) {
        _idleFrames = 0;
    } else if (++_idleFrames > 20) {
        LGAL_stopDisplayLink();
    }
}
@end

static void LGAL_registerGlassView(LGALGlassView *view) {
    if (!view) return;
    if (!sALGlassViews) sALGlassViews = [NSPointerArray weakObjectsPointerArray];
    for (NSUInteger i = 0; i < sALGlassViews.count; i++)
        if ((__bridge void *)view == [sALGlassViews pointerAtIndex:i]) return;
    [sALGlassViews addPointer:(__bridge void *)view];
}

static void LGAL_startDisplayLink(void) {
    if (sALDisplayLink) return;
    sALTicker = [LGALTicker new];
    sALDisplayLink = [CADisplayLink displayLinkWithTarget:sALTicker selector:@selector(tick:)];
    // 20fps is sufficient for pod glass — reduces CPU/GPU overhead vs 60fps
    if (@available(iOS 15.0, *)) {
        sALDisplayLink.preferredFrameRateRange =
            CAFrameRateRangeMake(4, 20, 20);
    } else if ([sALDisplayLink respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        sALDisplayLink.preferredFramesPerSecond = 20;
    }
    [sALDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

static void LGAL_stopDisplayLink(void) {
    [sALDisplayLink invalidate];
    sALDisplayLink = nil;
    sALTicker = nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Push updated wallpaper to all registered glass views
// ─────────────────────────────────────────────────────────────────────────────
static void LGAL_pushSnapshotToAllGlassViews(void) {
    if (!sALCachedSnapshot || !sALGlassViews) return;
    [sALGlassViews compact];
    for (NSUInteger i = 0; i < sALGlassViews.count; i++) {
        LGALGlassView *g = (__bridge LGALGlassView *)[sALGlassViews pointerAtIndex:i];
        if (!g || !g.superview || !g.window) continue;
        g.wallpaperImage = sALCachedSnapshot;
        [g updateOrigin];
    }
}

static void LGAL_trySnapshotWithRetry(void);

static void LGAL_trySnapshotWithRetry(void) {
    if (!LGAL_enabled()) return;
    if (sALCachedSnapshot) return;
    LGAL_refreshSnapshot();
    if (sALCachedSnapshot) { LGAL_pushSnapshotToAllGlassViews(); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ LGAL_trySnapshotWithRetry(); });
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Pod injection helpers
// ─────────────────────────────────────────────────────────────────────────────
static void   *kALGlassKey      = &kALGlassKey;
static void   *kALTintKey       = &kALTintKey;
static void   *kALRetryKey      = &kALRetryKey;
static void   *kALOrigAlphaKey  = &kALOrigAlphaKey;
static void   *kALOrigRadiusKey = &kALOrigRadiusKey;
static void   *kALOrigClipsKey  = &kALOrigClipsKey;
static void   *kALAttachedKey   = &kALAttachedKey;
static NSInteger sALPodCount    = 0;

static void LGAL_rememberState(UIView *view) {
    if (!objc_getAssociatedObject(view, kALOrigAlphaKey))
        objc_setAssociatedObject(view, kALOrigAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kALOrigRadiusKey))
        objc_setAssociatedObject(view, kALOrigRadiusKey, @(view.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kALOrigClipsKey))
        objc_setAssociatedObject(view, kALOrigClipsKey, @(view.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGAL_restoreState(UIView *view) {
    NSNumber *a = objc_getAssociatedObject(view, kALOrigAlphaKey);
    if (a) view.alpha = a.doubleValue;
    NSNumber *r = objc_getAssociatedObject(view, kALOrigRadiusKey);
    if (r) view.layer.cornerRadius = r.doubleValue;
    NSNumber *c = objc_getAssociatedObject(view, kALOrigClipsKey);
    if (c) view.clipsToBounds = c.boolValue;
}

static void LGAL_removeGlass(UIView *view) {
    UIView *tint = objc_getAssociatedObject(view, kALTintKey);
    if (tint) [tint removeFromSuperview];
    objc_setAssociatedObject(view, kALTintKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGALGlassView *glass = objc_getAssociatedObject(view, kALGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(view, kALGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static UIView *LGAL_podHostView(UIView *view) {
    UIView *host = view.superview;
    if (!host) return view;
    if (CGRectGetWidth(host.bounds) >= CGRectGetWidth(view.bounds) &&
        CGRectGetHeight(host.bounds) >= CGRectGetHeight(view.bounds))
        return host;
    return view;
}

static void LGAL_preparePodChildren(UIView *host) {
    static Class bgCls;
    if (!bgCls) bgCls = NSClassFromString(@"SBHLibraryCategoryPodBackgroundView");
    for (UIView *sub in host.subviews) {
        if (bgCls && [sub isKindOfClass:bgCls]) {
            sub.backgroundColor = [UIColor clearColor];
            sub.layer.backgroundColor = nil;
            sub.alpha = 0.01;
            sub.hidden = NO;
        }
    }
}

static UIColor *LGAL_tintColorForView(UIView *view) {
    // Light + dark tint alpha – slightly frosted overlay
    CGFloat lightAlpha = 0.1, darkAlpha = 0.0;
    if (@available(iOS 12.0, *)) {
        UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
            return [UIColor colorWithWhite:0.0 alpha:darkAlpha];
    }
    return [UIColor colorWithWhite:1.0 alpha:lightAlpha];
}

static void LGAL_ensureTintOverlay(UIView *host, CGFloat radius, UIColor *tintColor) {
    if (!host) return;
    UIView *tint = objc_getAssociatedObject(host, kALTintKey);
    if (!tint) {
        tint = [[UIView alloc] initWithFrame:host.bounds];
        tint.userInteractionEnabled = NO;
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(host, kALTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:tint];
    }
    tint.frame = host.bounds;
    tint.backgroundColor = tintColor;
    tint.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) tint.layer.cornerCurve = host.layer.cornerCurve;
    tint.hidden = (tintColor == nil);
    [host bringSubviewToFront:tint];
}

static BOOL LGAL_isInsideLibraryPod(UIView *view) {
    static Class podCls;
    if (!podCls) podCls = NSClassFromString(@"SBHLibraryCategoryPodView");
    if (!podCls) return NO;
    UIView *p = view.superview;
    while (p) {
        if ([p isKindOfClass:podCls]) return YES;
        p = p.superview;
    }
    return NO;
}

static void LGAL_injectIntoPod(UIView *self_) {
    UIView *host = LGAL_podHostView(self_);
    if (!LGAL_libraryEnabled()) {
        LGAL_removeGlass(host);
        LGAL_restoreState(host);
        return;
    }
    LGAL_startDisplayLink();
    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *snapshot = LGAL_getSnapshot(&wallpaperOrigin);
    if (!snapshot) {
        LGAL_restoreState(host);
        if ([objc_getAssociatedObject(host, kALRetryKey) boolValue]) return;
        objc_setAssociatedObject(host, kALRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(host, kALRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
            LGAL_injectIntoPod(self_);
        });
        return;
    }
    LGAL_rememberState(host);
    host.backgroundColor        = [UIColor clearColor];
    host.layer.backgroundColor  = nil;
    host.layer.cornerRadius     = 20.2;
    host.layer.masksToBounds    = YES;
    if (@available(iOS 13.0, *)) host.layer.cornerCurve = kCACornerCurveContinuous;
    host.clipsToBounds = YES;
    LGALGlassView *glass = objc_getAssociatedObject(host, kALGlassKey);
    if (!glass) {
        glass = [[LGALGlassView alloc] initWithFrame:host.bounds
                                           wallpaper:snapshot
                                     wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, kALGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGAL_registerGlassView(glass);
    } else {
        glass.wallpaperImage = snapshot;
    }
    glass.wallpaperOrigin = wallpaperOrigin;
    LGAL_preparePodChildren(host);
    LGAL_ensureTintOverlay(host, 20.2, LGAL_tintColorForView(host));
    objc_setAssociatedObject(host, kALRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
    [glass updateOrigin];
}

static void LGAL_injectIntoFolderIcon(UIView *self_) {
    if (!LGAL_libraryEnabled()) {
        LGAL_removeGlass(self_);
        LGAL_restoreState(self_);
        return;
    }
    if (self_.bounds.size.width < 1) return;
    LGAL_startDisplayLink();
    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *snapshot = LGAL_getSnapshot(&wallpaperOrigin);
    if (!snapshot) {
        LGAL_restoreState(self_);
        if ([objc_getAssociatedObject(self_, kALRetryKey) boolValue]) return;
        objc_setAssociatedObject(self_, kALRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(self_, kALRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
            LGAL_injectIntoFolderIcon(self_);
        });
        return;
    }
    LGAL_rememberState(self_);
    self_.backgroundColor       = [UIColor clearColor];
    self_.layer.backgroundColor = nil;
    CGFloat r = self_.layer.cornerRadius > 0 ? self_.layer.cornerRadius
                                              : self_.bounds.size.width * 0.22;
    self_.layer.cornerRadius    = r;
    self_.layer.masksToBounds   = YES;
    if (@available(iOS 13.0, *)) self_.layer.cornerCurve = kCACornerCurveContinuous;
    self_.clipsToBounds = YES;
    LGALGlassView *glass = objc_getAssociatedObject(self_, kALGlassKey);
    if (!glass) {
        glass = [[LGALGlassView alloc] initWithFrame:self_.bounds
                                           wallpaper:snapshot
                                     wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        [self_ insertSubview:glass atIndex:0];
        objc_setAssociatedObject(self_, kALGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGAL_registerGlassView(glass);
    } else {
        glass.wallpaperImage = snapshot;
    }
    glass.wallpaperOrigin = wallpaperOrigin;
    // Hide background CALayers (grey fill) but keep icon-content layers
    for (CALayer *sub in self_.layer.sublayers) {
        if (sub == glass.layer) continue;
        if (sub.contents) continue;
        if (sub.backgroundColor && CGColorGetAlpha(sub.backgroundColor) > 0.01) {
            sub.hidden = YES;
            sub.backgroundColor = [UIColor clearColor].CGColor;
        }
    }
    // Hide background subviews
    for (UIView *sub in self_.subviews) {
        if (sub == glass) continue;
        if ([sub isKindOfClass:[UIImageView class]] || [sub isKindOfClass:[UILabel class]]) continue;
        NSString *n = NSStringFromClass([sub class]);
        if ([n containsString:@"Background"] || [n containsString:@"Backdrop"] ||
            [n containsString:@"Shadow"]     || [n containsString:@"Material"]) {
            sub.hidden = YES;
        }
    }
    objc_setAssociatedObject(self_, kALRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
    [glass updateOrigin];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – App Library Pod background hooks
// ─────────────────────────────────────────────────────────────────────────────
%group AppLibraryAL

%hook SBHLibraryCategoryPodBackgroundView

- (void)drawRect:(CGRect)rect {
    if (LGAL_libraryEnabled()) return;
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) {
        UIView *host = LGAL_podHostView(self_);
        LGAL_removeGlass(host);
        LGAL_restoreState(host);
        host.clipsToBounds = YES;
        if ([objc_getAssociatedObject(self_, kALAttachedKey) boolValue]) {
            objc_setAssociatedObject(self_, kALAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
            sALPodCount = MAX(0, sALPodCount - 1);
            if (sALPodCount == 0) LGAL_stopDisplayLink();
        }
        return;
    }
    if (!LGAL_libraryEnabled()) {
        LGAL_removeGlass(LGAL_podHostView(self_));
        LGAL_restoreState(LGAL_podHostView(self_));
        return;
    }
    if (![objc_getAssociatedObject(self_, kALAttachedKey) boolValue]) {
        objc_setAssociatedObject(self_, kALAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sALPodCount++;
    }
    LGAL_injectIntoPod(self_);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!LGAL_libraryEnabled()) {
        LGAL_removeGlass(LGAL_podHostView(self_));
        LGAL_restoreState(LGAL_podHostView(self_));
        return;
    }
    if (!self_.window) return;
    LGAL_injectIntoPod(self_);
}

%end

%end  // AppLibraryAL

// Update glass position on scroll
%group AppLibraryALScroll

%hook BSUIScrollView
- (void)setContentOffset:(CGPoint)offset {
    %orig;
    if (!sALGlassViews || sALGlassViews.count == 0) return;
    // Restart display link if it was idle-stopped, so pods track scroll position
    LGAL_startDisplayLink();
    if (!sALDisplayLink) LGAL_pushSnapshotToAllGlassViews();
}
%end

%end  // AppLibraryALScroll

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Wallpaper interception
// ─────────────────────────────────────────────────────────────────────────────
%group ALWallpaperInterception

%hook UIImageView
- (void)setImage:(UIImage *)image {
    %orig;
    if (!LGAL_enabled() || !image) return;
    if (sALInterceptedWallpaper) return;
    CGSize screen = UIScreen.mainScreen.bounds.size;
    if (image.size.width < screen.width * 0.5) return;
    static Class replicaCls;
    if (!replicaCls) replicaCls = NSClassFromString(@"PBUISnapshotReplicaView");
    UIView *v = self.superview;
    while (v) {
        if ([v isKindOfClass:replicaCls]) {
            sALInterceptedWallpaper = image;
            sALCachedSnapshot = nil;
            LGAL_refreshSnapshot();
            if (sALCachedSnapshot) LGAL_pushSnapshotToAllGlassViews();
            return;
        }
        v = v.superview;
    }
}
%end

%hook SBHomeScreenViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!LGAL_enabled()) return;
    LGAL_trySnapshotWithRetry();
    NSArray<NSNumber *> *delays = @[@0.12, @0.28, @0.55];
    for (NSNumber *n in delays) {
        NSTimeInterval d = n.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (LGAL_enabled() && !sALCachedSnapshot) LGAL_trySnapshotWithRetry();
        });
    }
}
%end

%end  // ALWallpaperInterception

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – App Library folder icon hooks (inside pods only)
// ─────────────────────────────────────────────────────────────────────────────
%group ALFolderIcon

%hook SBFolderIconImageView
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (!v.window) {
        LGAL_removeGlass(v);
        LGAL_restoreState(v);
        return;
    }
    if (!LGAL_isInsideLibraryPod(v)) return;
    LGAL_injectIntoFolderIcon(v);
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (!v.window || !LGAL_isInsideLibraryPod(v)) return;
    LGAL_injectIntoFolderIcon(v);
}
%end

%end  // ALFolderIcon

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Constructor
// ─────────────────────────────────────────────────────────────────────────────
%ctor {
    // Prewarm the Metal pipeline on a background thread
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LGAL_prewarmPipelines();
    });

    Class bgCls        = NSClassFromString(@"SBHLibraryCategoryPodBackgroundView");
    Class scrollCls    = NSClassFromString(@"BSUIScrollView");
    Class folderIconCls = NSClassFromString(@"SBFolderIconImageView");

    if (bgCls)         %init(AppLibraryAL,    SBHLibraryCategoryPodBackgroundView = bgCls);
    if (scrollCls)     %init(AppLibraryALScroll, BSUIScrollView = scrollCls);
    if (folderIconCls) %init(ALFolderIcon,    SBFolderIconImageView = folderIconCls);

    %init(ALWallpaperInterception);
}
