import AppKit
import Metal
import MetalKit
import SwiftUI

// MARK: - Aura (agent-audio-visualizer-aura) — the real shader
//
// LiveKit Agents-UI's Aura is a WebGL fragment shader written for Unicorn
// Studio, driven by `use-agent-audio-visualizer-aura.ts`. This file is that
// shader ported line for line to Metal Shading Language, compiled at runtime
// (`MTLDevice.makeLibrary(source:)` needs no Xcode Metal compiler), hosted in
// an `MTKView`, with the hook's per-state animation reproduced on top.
//
// The shader source carries its original license:
//
//   Originally developed for Unicorn Studio — https://unicorn.studio
//   Licensed under the Polyform Non-Resale License 1.0.0
//   https://polyformproject.org/licenses/non-resale/1.0.0/
//   © 2026 UNCRN LLC
//
// Source: livekit/components-js → packages/shadcn/components/agents-ui/
// agent-audio-visualizer-aura.tsx (shader) and packages/shadcn/hooks/agents-ui/
// use-agent-audio-visualizer-aura.ts (state → parameters).

/// Uniform block. Plain floats only, in this order, so the Swift and MSL
/// layouts agree without alignment surprises.
struct AuraUniforms {
    var resolutionX: Float = 1
    var resolutionY: Float = 1
    var time: Float = 0
    var speed: Float = 10
    var blur: Float = 0.2
    var scale: Float = 0.2
    var shape: Float = 1          // 1 = circle, 2 = line
    var frequency: Float = 0.5
    var amplitude: Float = 2
    var bloom: Float = 0          // the component passes 0
    var brightness: Float = 1.5   // uMix
    var spacing: Float = 0.5
    var colorShift: Float = 0.05  // the component's default
    var variance: Float = 0.1
    var smoothing: Float = 1
    var mode: Float = 0           // 0 = dark background, 1 = light
    var colorR: Float = 0x1F / 255.0
    var colorG: Float = 0xD5 / 255.0
    var colorB: Float = 0xF9 / 255.0
}

enum AuraShaderSource {
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct AuraUniforms {
        float resolutionX; float resolutionY; float time; float speed; float blur; float scale;
        float shape; float frequency; float amplitude; float bloom; float brightness; float spacing;
        float colorShift; float variance; float smoothing; float mode;
        float colorR; float colorG; float colorB;
    };

    struct AuraVertexOut { float4 position [[position]]; };

    vertex AuraVertexOut aura_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        AuraVertexOut out;
        out.position = float4(p[vid], 0.0, 1.0);
        return out;
    }

    // Noise for dithering
    static float2 randFibo(float2 p) {
        p = fract(p * float2(443.897, 441.423));
        p += dot(p, p.yx + 19.19);
        return fract((p.xx + p.yx) * p.xy);
    }

    // Tonemap
    static float3 tonemap(float3 x) {
        x *= 4.0;
        return x / (1.0 + x);
    }

    // Luma for alpha
    static float luma(float3 color) {
        return dot(color, float3(0.299, 0.587, 0.114));
    }

    // RGB to HSV
    static float3 rgb2hsv(float3 c) {
        float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
        float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
        float d = q.x - min(q.w, q.y);
        float e = 1.0e-10;
        return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
    }

    // HSV to RGB
    static float3 hsv2rgb(float3 c) {
        float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
    }

    // SDF shapes
    static float sdCircle(float2 st, float r) {
        return length(st) - r;
    }

    static float sdLine(float2 p, float r) {
        float halfLen = r * 2.0;
        float2 a = float2(-halfLen, 0.0);
        float2 b = float2(halfLen, 0.0);
        float2 pa = p - a;
        float2 ba = b - a;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        return length(pa - ba * h);
    }

    static float getSdf(float2 st, constant AuraUniforms& u) {
        if (u.shape == 1.0) return sdCircle(st, u.scale);
        else if (u.shape == 2.0) return sdLine(st, u.scale);
        return sdCircle(st, u.scale);
    }

    static float2 turb(float2 pos, float t, float it, constant AuraUniforms& u) {
        // Initial rotation matrix for swirl direction
        float2x2 rotation = float2x2(float2(0.6, -0.25), float2(0.25, 0.9));
        // Secondary rotation applied each iteration (approx 53 degree rotation)
        float2x2 layerRotation = float2x2(float2(0.6, -0.8), float2(0.8, 0.6));

        float frequency = mix(2.0, 15.0, u.frequency);
        float amplitude = u.amplitude;
        float frequencyGrowth = 1.4;
        float animTime = t * 0.1 * u.speed;

        for (int i = 0; i < 4; i++) {
            // Calculate wave displacement for this layer
            float2 rotatedPos = pos * rotation;
            float2 wave = sin(frequency * rotatedPos + float(i) * animTime + it);

            // Apply displacement along rotation direction
            pos += (amplitude / frequency) * rotation[0] * wave;

            // Evolve parameters for next layer
            rotation = rotation * layerRotation;
            amplitude *= mix(1.0, max(wave.x, wave.y), u.variance);
            frequency *= frequencyGrowth;
        }

        return pos;
    }

    fragment float4 aura_fragment(AuraVertexOut in [[stage_in]],
                                  constant AuraUniforms& u [[buffer(0)]]) {
        const float TAU = 6.283185;
        const float ITERATIONS = 36.0;

        float2 resolution = float2(u.resolutionX, u.resolutionY);
        // GL's fragCoord has its origin at the bottom-left; Metal's at the top.
        float2 fragCoord = float2(in.position.x, resolution.y - in.position.y);
        float2 uv = fragCoord / resolution;

        float3 pp = float3(0.0);
        float3 bloom = float3(0.0);
        float t = u.time * 0.5;
        float2 pos = uv - 0.5;

        float2 prevPos = turb(pos, t, 0.0 - 1.0 / ITERATIONS, u);
        float spacing = mix(1.0, TAU, u.spacing);
        float3 baseColor = float3(u.colorR, u.colorG, u.colorB);

        for (float i = 1.0; i < ITERATIONS + 1.0; i += 1.0) {
            float iter = i / ITERATIONS;
            float2 st = turb(pos, t, iter * spacing, u);
            float d = abs(getSdf(st, u));
            float pd = distance(st, prevPos);
            prevPos = st;
            float dynamicBlur = exp2(pd * 2.0 * 1.4426950408889634) - 1.0;
            float ds = smoothstep(0.0, u.blur * 0.05 + max(dynamicBlur * u.smoothing, 0.001), d);

            // Shift color based on iteration using uColorScale
            float3 color = baseColor;
            if (u.colorShift > 0.01) {
                float3 hsv = rgb2hsv(color);
                // Shift hue by iteration
                hsv.x = fract(hsv.x + (1.0 - iter) * u.colorShift * 0.3);
                color = hsv2rgb(hsv);
            }

            float invd = 1.0 / max(d + dynamicBlur, 0.001);
            pp += (ds - 1.0) * color;
            bloom += clamp(invd, 0.0, 250.0) * color;
        }

        pp *= 1.0 / ITERATIONS;

        float3 color;

        // Dark mode (default)
        if (u.mode < 0.5) {
            // use bloom effect
            bloom = bloom / (bloom + 2e4);
            color = (-pp + bloom * 3.0 * u.bloom) * 1.2;
            color += (randFibo(fragCoord).x - 0.5) / 255.0;
            color = tonemap(color);
            float alpha = luma(color) * u.brightness;
            return float4(color * u.brightness, alpha);
        }

        // Light mode
        // no bloom effect
        color = -pp;
        color += (randFibo(fragCoord).x - 0.5) / 255.0;

        // Preserve hue by tone mapping brightness only
        float brightness = length(color);
        float3 direction = brightness > 0.0 ? color / brightness : color;

        // Reinhard on brightness
        float factor = 2.0;
        float mappedBrightness = (brightness * factor) / (1.0 + brightness * factor);
        color = direction * mappedBrightness;

        // Boost saturation to compensate for white background bleed-through
        float gray = dot(color, float3(0.2, 0.5, 0.1));
        float saturationBoost = 3.0;
        color = mix(float3(gray), color, saturationBoost);

        // Clamp between 0-1
        color = clamp(color, 0.0, 1.0);

        float alpha = mappedBrightness * clamp(u.brightness, 1.0, 2.0);
        return float4(color, alpha);
    }
    """
}

// MARK: - Hook: state → animated parameters

/// One animated scalar with the transitions the hook uses: a 0.5 s ease-out,
/// a duration spring, an endless mirrored pulse between two values, or a
/// plain snap.
struct AuraTrack {
    enum Kind { case snap, easeOut, spring, pulse }

    private(set) var from: Double
    private(set) var to: Double
    private(set) var startTime: TimeInterval = 0
    private(set) var duration: Double = 0
    private(set) var kind: Kind = .snap

    init(_ value: Double) {
        from = value
        to = value
    }

    /// Framer Motion's `ease: 'easeOut'` (CSS ease-out), close enough.
    private static func easeOut(_ p: Double) -> Double { 1 - (1 - p) * (1 - p) }

    func value(at now: TimeInterval) -> Double {
        let elapsed = max(0, now - startTime)
        switch kind {
        case .snap:
            return to
        case .easeOut:
            guard duration > 0, elapsed < duration else { return to }
            return from + (to - from) * Self.easeOut(elapsed / duration)
        case .spring:
            // `{ type: 'spring', duration: 1.0, bounce: 0.35 }`: damping ratio
            // 0.65, settling inside the perceptual duration.
            guard elapsed < duration else { return to }
            let zeta = 0.65
            let omega = 8.0
            let damped = omega * (1 - zeta * zeta).squareRoot()
            let envelope = exp(-zeta * omega * elapsed)
            let shape = cos(damped * elapsed) + (zeta / (1 - zeta * zeta).squareRoot()) * sin(damped * elapsed)
            return to + (from - to) * envelope * shape
        case .pulse:
            // `repeat: Infinity, repeatType: 'mirror'` — the keyframes and the
            // easing both run backwards on the way back.
            guard duration > 0 else { return to }
            let leg = Int(elapsed / duration)
            let p = Self.easeOut((elapsed - Double(leg) * duration) / duration)
            return leg % 2 == 0 ? from + (to - from) * p : to + (from - to) * p
        }
    }

    func isAnimating(at now: TimeInterval) -> Bool {
        switch kind {
        case .snap:   return false
        case .pulse:  return true
        case .easeOut, .spring: return now < startTime + duration
        }
    }

    mutating func animate(to target: Double, kind: Kind, duration: Double, at now: TimeInterval) {
        from = value(at: now)
        to = target
        self.kind = kind
        self.duration = duration
        startTime = now
    }

    mutating func pulse(_ a: Double, _ b: Double, legDuration: Double, at now: TimeInterval) {
        from = a
        to = b
        kind = .pulse
        duration = legDuration
        startTime = now
    }

    mutating func snap(_ target: Double) {
        from = target
        to = target
        kind = .snap
    }
}

/// `useAgentAudioVisualizerAura`, minus React: the same defaults, the same
/// per-state targets and transitions, the same volume → scale rule.
struct AuraAnimator {
    private(set) var speed: Double = 10
    private(set) var scale = AuraTrack(0.2)
    private(set) var amplitude = AuraTrack(2)
    private(set) var frequency = AuraTrack(0.5)
    private(set) var brightness = AuraTrack(1.5)
    private(set) var state: VisualizerAgentState?

    private static let transition = 0.5
    private static let pulseLeg = 0.35

    mutating func apply(state newState: VisualizerAgentState, at now: TimeInterval) {
        guard newState != state else { return }
        state = newState
        switch newState {
        case .listening:
            speed = 20
            scale.animate(to: 0.3, kind: .spring, duration: 1.0, at: now)
            amplitude.animate(to: 1.0, kind: .easeOut, duration: Self.transition, at: now)
            frequency.animate(to: 0.7, kind: .easeOut, duration: Self.transition, at: now)
            brightness.pulse(1.5, 2.0, legDuration: Self.pulseLeg, at: now)
        case .thinking, .connecting:
            speed = 30
            scale.animate(to: 0.3, kind: .easeOut, duration: Self.transition, at: now)
            amplitude.animate(to: 0.5, kind: .easeOut, duration: Self.transition, at: now)
            frequency.animate(to: 1.0, kind: .easeOut, duration: Self.transition, at: now)
            brightness.pulse(0.5, 2.5, legDuration: Self.pulseLeg, at: now)
        case .speaking:
            speed = 70
            scale.animate(to: 0.3, kind: .easeOut, duration: Self.transition, at: now)
            amplitude.animate(to: 0.75, kind: .easeOut, duration: Self.transition, at: now)
            frequency.animate(to: 1.25, kind: .easeOut, duration: Self.transition, at: now)
            brightness.animate(to: 1.5, kind: .easeOut, duration: Self.transition, at: now)
        }
    }

    /// While speaking, once the entry transition has settled, the scale
    /// follows the volume directly (`animateScale(0.2 + 0.2 * volume, { duration: 0 })`).
    mutating func apply(volume: Double, at now: TimeInterval) {
        guard state == .speaking, volume > 0, !scale.isAnimating(at: now) else { return }
        scale.snap(0.2 + 0.2 * volume)
    }

    func uniforms(at now: TimeInterval, time: TimeInterval, resolution: CGSize,
                  color: (r: Double, g: Double, b: Double)) -> AuraUniforms {
        var u = AuraUniforms()
        u.resolutionX = Float(resolution.width)
        u.resolutionY = Float(resolution.height)
        u.time = Float(time)
        u.speed = Float(speed)
        u.scale = Float(scale.value(at: now))
        u.amplitude = Float(amplitude.value(at: now))
        u.frequency = Float(frequency.value(at: now))
        u.brightness = Float(brightness.value(at: now))
        u.colorR = Float(color.r)
        u.colorG = Float(color.g)
        u.colorB = Float(color.b)
        return u
    }
}

// MARK: - Renderer

/// Compiles the shader once per process and draws a full-screen triangle
/// with it. Also renders offscreen for `--aura-selftest`.
final class AuraRenderer: NSObject, MTKViewDelegate {
    struct Backend {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
    }

    /// nil when there is no Metal device or the shader failed to compile —
    /// the Canvas approximation takes over in that case.
    static let backend: Backend? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: AuraShaderSource.metal, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "aura_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "aura_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            return Backend(device: device, queue: queue, pipeline: pipeline)
        } catch {
            fputs("NotchWhisper: Aura shader failed to compile: \(error)\n", stderr)
            return nil
        }
    }()

    static var isAvailable: Bool { backend != nil }

    /// Compile off the main thread before the notch first needs it.
    static func warmUp() {
        Task.detached(priority: .utility) { _ = backend }
    }

    private(set) var animator = AuraAnimator()
    private var color: (r: Double, g: Double, b: Double) = (0x1F / 255.0, 0xD5 / 255.0, 0xF9 / 255.0)
    private let epoch = CACurrentMediaTime()
    /// A fixed clock for the paused (Reduce Motion) frame.
    var frozenTime: TimeInterval?

    func update(state: VisualizerAgentState, volume: Double, color: (r: Double, g: Double, b: Double)) {
        let now = CACurrentMediaTime()
        animator.apply(state: state, at: now)
        animator.apply(volume: volume, at: now)
        self.color = color
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let backend = Self.backend,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commands = backend.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let now = CACurrentMediaTime()
        var uniforms = animator.uniforms(
            at: now, time: frozenTime ?? (now - epoch), resolution: view.drawableSize, color: color
        )
        encoder.setRenderPipelineState(backend.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AuraUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    // MARK: Offscreen

    /// One frame into a bitmap — the self-test's proof that the port draws.
    static func renderImage(size: CGSize, uniforms base: AuraUniforms) -> CGImage? {
        guard let backend else { return nil }
        let width = Int(size.width), height = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = backend.device.makeTexture(descriptor: descriptor),
              let commands = backend.queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniforms = base
        uniforms.resolutionX = Float(width)
        uniforms.resolutionY = Float(height)
        encoder.setRenderPipelineState(backend.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AuraUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info: CGBitmapInfo = [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)]
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - SwiftUI host

/// The Aura in a SwiftUI frame: a transparent `MTKView` redrawn at 60 fps
/// (or one frozen frame under Reduce Motion), fed the agent state, the voice
/// level and the color every SwiftUI update.
struct AuraMetalView: NSViewRepresentable {
    let state: VisualizerAgentState
    let volume: Double
    let color: (r: Double, g: Double, b: Double)
    let paused: Bool

    func makeCoordinator() -> AuraRenderer { AuraRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: AuraRenderer.backend?.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = nil
        (view.layer as? CAMetalLayer)?.isOpaque = false
        configure(view, context: context)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        configure(view, context: context)
    }

    private func configure(_ view: MTKView, context: Context) {
        context.coordinator.update(state: state, volume: volume, color: color)
        if paused {
            context.coordinator.frozenTime = 1.2
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.needsDisplay = true
        } else {
            context.coordinator.frozenTime = nil
            view.isPaused = false
            view.enableSetNeedsDisplay = false
        }
    }
}

// MARK: - Self-test

/// `--aura-selftest [png-path]`: compiles the shader, renders the speaking and
/// thinking states offscreen, checks the frames are neither blank nor
/// saturated, and optionally writes a PNG of the speaking frame to look at.
enum AuraSelfTest {
    static func run(pngPath: String?) -> Int32 {
        guard AuraRenderer.isAvailable else {
            print("FAIL  Aura shader did not compile (see stderr)")
            return 1
        }
        print("PASS  shader compiled at runtime")
        var failures = 0
        var animator = AuraAnimator()
        let now = CACurrentMediaTime()
        for (state, label) in [(VisualizerAgentState.speaking, "speaking"), (.thinking, "thinking"), (.listening, "listening")] {
            animator.apply(state: state, at: now)
            animator.apply(volume: 0.6, at: now + 1)
            let uniforms = animator.uniforms(at: now + 1, time: 3.0, resolution: CGSize(width: 224, height: 224),
                                             color: (0x1F / 255.0, 0xD5 / 255.0, 0xF9 / 255.0))
            guard let image = AuraRenderer.renderImage(size: CGSize(width: 224, height: 224), uniforms: uniforms),
                  let data = image.dataProvider?.data as Data? else {
                print("FAIL  \(label): no frame"); failures += 1; continue
            }
            var lit = 0, edgeLit = 0
            let width = image.width
            for y in 0..<image.height {
                for x in 0..<width {
                    let alpha = data[(y * width + x) * 4 + 3]
                    if alpha > 24 {
                        lit += 1
                        if x < 4 || y < 4 || x >= width - 4 || y >= image.height - 4 { edgeLit += 1 }
                    }
                }
            }
            let coverage = Double(lit) / Double(width * image.height)
            let ok = coverage > 0.05 && coverage < 0.9
            print("\(ok ? "PASS" : "FAIL")  \(label): \(Int(coverage * 100))% of pixels lit, \(edgeLit) at the edges, scale=\(String(format: "%.2f", uniforms.scale)) brightness=\(String(format: "%.2f", uniforms.brightness))")
            if !ok { failures += 1 }
            if state == .speaking, let pngPath {
                // Composited over black, the way the notch shows it.
                let url = URL(fileURLWithPath: pngPath)
                let space = CGColorSpaceCreateDeviceRGB()
                if let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                           bytesPerRow: 0, space: space,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    context.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    if let composed = context.makeImage(),
                       let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, composed, nil)
                        if CGImageDestinationFinalize(destination) { print("PASS  wrote \(pngPath)") }
                    }
                }
            }
        }
        print(failures == 0 ? "aura-selftest: all checks passed" : "aura-selftest: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
