// BlackHoleDelete — «Clear History» as a black hole growing out of the Dynamic Island.
// Geometry and timing. Pure Swift + CoreGraphics: no UIKit, no Metal.

import CoreGraphics
import Foundation

// MARK: - Configuration

/// All tunable parameters. Defaults are the values tuned in the prototype.
public struct BlackHoleConfig {
    // Hole
    /// Radius of the black disk when fully open (pt).
    public var holeRadius: CGFloat = 90
    /// Opening: soft start, fast growth, long ease-out (s).
    public var emergeDuration: Double = 0.8
    /// Closing back into the island (s).
    public var collapseDuration: Double = 0.3
    /// Island "bulge" after landing, like an app flying into the Dynamic Island (fraction of island size).
    public var collapseBounce: Double = 0.35
    /// Duration of the bulge spring after landing (s).
    public var settleDuration: Double = 0.34

    // Light ring (texture "BlackHoleDisk.png")
    public var ringBrightness: Double = 1.03
    /// Ring spin speed multiplier; fibers near the horizon spin faster (`innerBoost`).
    public var ringSpeed: Double = 2.0
    public var innerBoost: Double = 4.5
    public var innerWidth: Double = 0.08
    /// Ring width relative to the arc in the texture: < 1 — wider.
    public var ringSqueeze: Double = 0.7
    /// Radial remap exponent: < 1 pulls the brightest part of the texture towards the horizon.
    public var ringGamma: Double = 0.75
    /// Mip level for fibers: higher — softer.
    public var ringSoftness: Double = 1.2

    // Backdrop (wallpaper under the chat)
    /// Bloom around the ring (0 — off).
    public var glow: Double = 0.82
    /// Wallpaper pulled towards the hole.
    public var lensStrength: Double = 1.5
    /// Darkening of the wallpaper around the hole: strength and size (in hole radii).
    public var spaceDarkness: Double = 0.55
    public var spaceSize: Double = 2.0
    /// Wallpaper twist near the horizon (rad) and its spin while the hole is open (rad/s).
    public var backgroundSwirl: Double = 0.9
    public var backgroundSpin: Double = 0.8

    // Swallowing (messages mesh)
    /// When swallowing starts — fraction of `emergeDuration`.
    public var swallowLead: Double = 0.1
    /// How long the swallowing lasts (s): flow speed is fitted automatically.
    public var swallowDuration: Double = 1.15
    /// Bend shape: 1 — straight edges, > 1 — edges overtake the middle and wrap the arc.
    public var arcShape: Double = 1.0
    /// Acceleration near the horizon ("spaghettification") and its reach (in hole radii).
    public var pullStrength: Double = 3
    public var pullReach: Double = 0.8
    /// Smooth start of the flow (s) and overall acceleration over time (1/s).
    public var flowRamp: Double = 0.35
    public var flowAccel: Double = 8
    /// How deep points go under the horizon (pt).
    public var sinkDepth: Double = 30
    /// Where content starts fading/blurring and where it is gone (in hole radii; 1 — horizon).
    public var fadeOuter: Double = 1.6
    public var fadeInner: Double = 1.03
    /// Blur near the horizon along the ray (pt).
    public var fadeBlur: Double = 14
    /// How strongly the hole already pulls messages while it opens.
    public var emergePull: Double = 1.0

    public init() {}
    public static let `default` = BlackHoleConfig()
}

// MARK: - Screen geometry

public enum BlackHoleLayout {
    /// Dynamic Island frame in screen points. Values were measured on simulator screenshots;
    /// pass the real frame from your device metrics when available.
    ///  • iPhone 18 Pro / Pro Max (narrow island): 94.67 × 36.67 pt, 14 pt from the top;
    ///  • iPhone 14 Pro … 17 Pro: 125.33 × 36.67 pt, 14 pt (11 pt when safe area top < 61).
    /// Devices without an island: a capsule just above the screen.
    public static func islandRect(screenWidth: CGFloat, safeAreaTop: CGFloat, narrowIsland: Bool) -> CGRect {
        guard safeAreaTop >= 51 else {
            return CGRect(x: screenWidth / 2 - 40, y: -34, width: 80, height: 30)
        }
        let top: CGFloat = safeAreaTop >= 61 ? 14 : 11
        let width: CGFloat = narrowIsland ? 94.67 : 125.33
        return CGRect(x: screenWidth / 2 - width / 2, y: top, width: width, height: 36.67)
    }

    /// Narrow island (iPhone 18 Pro and newer): by model identifier on a device,
    /// by SIMULATOR_MODEL_IDENTIFIER in the simulator.
    public static let isNarrowIsland: Bool = {
        var identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if identifier.isEmpty {
            var info = utsname()
            uname(&info)
            identifier = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        }
        guard identifier.hasPrefix("iPhone"),
              let major = Int(identifier.dropFirst(6).split(separator: ",").first ?? "") else { return false }
        return major >= 19
    }()
}

// MARK: - Run

/// One swallowed item: its frame in screen points.
public struct BlackHoleItem {
    public let id: Int
    public let frame: CGRect
    public init(id: Int, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// Timing of one "clear history" run. Built once at start.
public struct BlackHoleRun {
    public let config: BlackHoleConfig
    public let island: CGRect
    public let items: [BlackHoleItem]
    /// Flow speed fitted so that the farthest item fades exactly at `swallowEnd` (pt/s).
    public let flowSpeed: Double
    public let swallowStart: Double
    public let swallowEnd: Double

    public var hole: CGPoint { CGPoint(x: island.midX, y: island.midY) }
    /// The hole starts closing slightly before the last message fades — in sync.
    public var closeStart: Double { max(swallowEnd - min(0.12, config.collapseDuration * 0.3), swallowStart) }
    public var total: Double { closeStart + config.collapseDuration + config.settleDuration + 0.03 }

    public init(items: [BlackHoleItem], island: CGRect, config: BlackHoleConfig = .default) {
        self.config = config
        self.island = island
        self.items = items
        let target = CGPoint(x: island.midX, y: island.midY)
        let radius = Double(config.holeRadius)
        swallowStart = config.emergeDuration * config.swallowLead

        // Flow speed: travel distance is inversely proportional to speed.
        let unit = TidalFlow(config: config, speed: 1)
        let farthest = items.flatMap { Self.corners(of: $0.frame) }
            .map { unit.height(of: $0, hole: target, horizon: radius) }.max() ?? 0
        let path = unit.travelTime(farthest) - unit.travelTime(max(unit.fadeHeight, -unit.sink))
        let eased = unit.eased(config.swallowDuration)
        flowSpeed = (path > 0 && eased > 0) ? path / eased : 70

        let flow = TidalFlow(config: config, speed: flowSpeed)
        var end = swallowStart
        for item in items {
            let far = Self.corners(of: item.frame).map { flow.height(of: $0, hole: target, horizon: radius) }.max() ?? 0
            end = max(end, swallowStart + flow.timeToSink(from: far))
        }
        swallowEnd = end
    }

    static func corners(of frame: CGRect) -> [CGPoint] {
        [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
         CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)]
    }
}

/// Flow towards the hole — the same formula as the mesh vertex shader (`blackHoleMeshVertex`).
struct TidalFlow {
    let speed, strength, reach, ramp, sink, shape, accel, fadeHeight: Double

    init(config c: BlackHoleConfig, speed: Double) {
        self.speed = max(speed, 1)
        strength = c.pullStrength
        reach = max(c.pullReach * Double(c.holeRadius), 1)
        ramp = c.flowRamp
        sink = c.sinkDepth
        shape = c.arcShape
        accel = c.flowAccel
        fadeHeight = (min(c.fadeInner, c.fadeOuter) - 1) * Double(c.holeRadius)
    }

    /// "Height" of a point above the hole: D = ρ·k(φ) − r.
    func height(of point: CGPoint, hole: CGPoint, horizon: Double) -> Double {
        let dx = Double(point.x - hole.x), dy = Double(point.y - hole.y)
        let rho = max(hypot(dx, dy), 0.001)
        let cosPhi = min(max(dy / rho, 0.65), 1)
        let t = min(max((rho - horizon) / (horizon * 3), 0), 1)
        let w = t * t * (3 - 2 * t)
        return rho * pow(cosPhi, shape * w) - horizon
    }

    func travelTime(_ x: Double) -> Double { (x + reach * log(1 + strength * exp(-x / reach))) / speed }

    func eased(_ tau: Double) -> Double {
        let ramped = ramp > 0.001 ? tau - ramp * (1 - exp(-tau / ramp)) : tau
        return accel > 0.001 ? (exp(accel * ramped) - 1) / accel : ramped
    }

    func timeToSink(from x: Double) -> Double {
        let need = travelTime(x) - travelTime(max(fadeHeight, -sink))
        var lo = 0.0, hi = need + ramp + 1
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if eased(mid) < need { lo = mid } else { hi = mid }
        }
        return hi
    }
}

// MARK: - State at time t

/// Shape of the hole at a moment of the run.
public struct BlackHoleState {
    public var center: CGPoint
    /// Half size of the shape: island capsule → circle.
    public var halfSize: CGSize
    public var radius: CGFloat
    /// 0…1: how far the island has turned into the hole. Hide the navigation bar while > 0.12.
    public var presence: Double
    public var time: Double

    public static func at(_ t: Double, run: BlackHoleRun) -> BlackHoleState {
        let c = run.config
        let island = run.island
        let grow = BlackHoleEase.soft(clamp01(t / c.emergeDuration))
        // Closing: fast start, arrives exactly at the island shape with speed — the bulge absorbs it.
        let back = BlackHoleEase.outCubic(clamp01((t - run.closeStart) / c.collapseDuration))
        let morph = clamp01(grow * (1 - min(back, 1)))

        // After touching the island: bulges only outward (smaller would hide under the system
        // island and look like a jump), damped spring, exactly 0 at the end. The top stays put.
        let u = (t - run.closeStart - c.collapseDuration) / max(c.settleDuration, 0.01)
        var bulge: CGFloat = 0
        if u > 0 && u < 1 {
            bulge = CGFloat(c.collapseBounce) * CGFloat(sin(.pi * u) * exp(-2.2 * u))
        }
        // At rest the capsule is 1.5 pt smaller than the system island and fully under it.
        let halfWidth = lerp(island.width / 2 - 1.5, c.holeRadius, morph) + island.width / 2 * bulge * 0.5
        let halfHeight = lerp(island.height / 2 - 1.5, c.holeRadius, morph) + island.height / 2 * bulge * 0.5
        let bulgeShift = island.height / 2 * bulge * 0.5
        return BlackHoleState(center: CGPoint(x: island.midX, y: island.midY + bulgeShift),
                              halfSize: CGSize(width: max(halfWidth, 1), height: max(halfHeight, 1)),
                              radius: max(min(halfWidth, halfHeight), 1),
                              presence: morph, time: t)
    }
}

enum BlackHoleEase {
    static func outCubic(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func outQuint(_ x: Double) -> Double { 1 - pow(1 - x, 5) }
    static func inOut(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    /// S-shaped start without a jerk and a long tail.
    static func soft(_ x: Double) -> Double { outQuint(inOut(x)) * 0.6 + inOut(inOut(x)) * 0.4 }
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        inOut(clamp01((x - a) / max(b - a, 0.0001)))
    }
}

func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
