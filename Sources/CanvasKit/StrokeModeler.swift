import Foundation
import CoreGraphics

// MARK: - Params

/// Tunables for `StrokeModeler`. Distances are in input units (on-screen points),
/// times in seconds. Spring and drag constants are ink-stroke-modeler's defaults;
/// they are unit-independent, so they carry over unchanged.
public struct StrokeModelerParams {
    /// Wobble-smoother averaging window.
    public var wobbleWindow: TimeInterval = 0.04
    /// Below this speed (pt/s) the wobble average is used fully.
    public var wobbleSpeedFloor: Double = 40
    /// Above this speed (pt/s) the raw input is used unsmoothed.
    public var wobbleSpeedCeiling: Double = 120
    /// Spring: acceleration = (anchor - pos) / springMass - drag * velocity.
    public var springMass: Double = 11.0 / 32400.0
    public var drag: Double = 72
    /// Fixed integration rate (Hz); inputs are upsampled to at least this rate.
    public var samplingRate: Double = 180
    /// Cap on integration steps for one input (guards against long input gaps).
    public var maxStepsPerInput = 20
    /// End-of-stroke iterations stop once this close to the last input...
    public var stopDistance: Double = 0.3
    /// ...or after this many steps.
    public var maxEndIterations = 40
    /// How far ahead `predict()` looks.
    public var predictionDuration: TimeInterval = 0.024

    public static let `default` = StrokeModelerParams()
    public init() {}
}

public struct ModeledPoint: Equatable {
    public var position: CGPoint
    /// Points per second.
    public var velocity: CGVector
    public var time: TimeInterval
}

// MARK: - Modeler

/// Smooths a noisy pointer path into a pen-like one: a wobble smoother removes
/// sensor jitter at low speed, then the pen tip follows the smoothed path as a
/// damped spring, which rounds corners and gives natural lag. Port of the core
/// ideas in Google's ink-stroke-modeler.
public struct StrokeModeler {
    public let params: StrokeModelerParams

    private var position = CGPoint.zero
    private var velocity = CGVector.zero
    private var time: TimeInterval = 0
    private var anchor = CGPoint.zero
    private var latestRaw = CGPoint.zero
    private var started = false

    private var window: [(p: CGPoint, t: TimeInterval)] = []
    private var lastRaw: (p: CGPoint, t: TimeInterval)?
    private var speed: Double = 0

    public init(params: StrokeModelerParams = .default) {
        self.params = params
    }

    // MARK: Stroke lifecycle

    public mutating func begin(_ p: CGPoint, t: TimeInterval) -> [ModeledPoint] {
        window = [(p, t)]
        lastRaw = (p, t)
        speed = 0
        position = p; anchor = p; latestRaw = p
        velocity = .zero
        time = t
        started = true
        return [ModeledPoint(position: p, velocity: .zero, time: t)]
    }

    public mutating func update(_ p: CGPoint, t: TimeInterval) -> [ModeledPoint] {
        guard started else { return begin(p, t: t) }
        let target = smooth(p, t: t)
        latestRaw = p
        return advance(to: t, anchor: target)
    }

    /// Flushes the spring until the pen tip reaches the last input.
    public mutating func end(_ p: CGPoint, t: TimeInterval) -> [ModeledPoint] {
        guard started else { return begin(p, t: t) }
        latestRaw = p
        var out = advance(to: max(t, time), anchor: p)
        let dt = 1 / params.samplingRate
        var i = 0
        while i < params.maxEndIterations, hypot(position.x - p.x, position.y - p.y) > params.stopDistance {
            time += dt
            step(toward: p, dt: dt)
            out.append(current)
            i += 1
        }
        started = false
        return out
    }

    /// Short look-ahead from the current state toward the latest raw input.
    /// For live rendering only; the modeler's state is untouched.
    public func predict() -> [ModeledPoint] {
        guard started else { return [] }
        var copy = self
        let dt = 1 / params.samplingRate
        var out: [ModeledPoint] = []
        var elapsed = 0.0
        while elapsed + dt <= params.predictionDuration + 1e-9 {
            copy.time += dt
            copy.step(toward: latestRaw, dt: dt)
            out.append(copy.current)
            elapsed += dt
        }
        return out
    }

    // MARK: Wobble smoother

    private mutating func smooth(_ p: CGPoint, t: TimeInterval) -> CGPoint {
        if let last = lastRaw {
            let dt = max(t - last.t, 1e-3)
            let inst = hypot(p.x - last.p.x, p.y - last.p.y) / dt
            speed += (inst - speed) * min(1, dt / params.wobbleWindow)
        }
        lastRaw = (p, t)
        window.append((p, t))
        while window.count > 1, t - window[0].t > params.wobbleWindow { window.removeFirst() }

        var sx = 0.0, sy = 0.0
        for w in window { sx += Double(w.p.x); sy += Double(w.p.y) }
        let n = Double(window.count)
        let avg = CGPoint(x: sx / n, y: sy / n)

        let span = params.wobbleSpeedCeiling - params.wobbleSpeedFloor
        let raw = span > 0 ? min(1, max(0, (speed - params.wobbleSpeedFloor) / span)) : 1
        return CGPoint(x: avg.x + (p.x - avg.x) * raw, y: avg.y + (p.y - avg.y) * raw)
    }

    // MARK: Position model

    private var current: ModeledPoint {
        ModeledPoint(position: position, velocity: velocity, time: time)
    }

    /// Integrates to `t`, moving the anchor linearly from its old to its new position.
    private mutating func advance(to t: TimeInterval, anchor target: CGPoint) -> [ModeledPoint] {
        guard t - time > 1e-6 else {
            anchor = target
            return []
        }
        // After a long input gap, skip ahead so the step size stays stable.
        time = max(time, t - Double(params.maxStepsPerInput) / params.samplingRate)
        let span = t - time
        let n = min(params.maxStepsPerInput, max(1, Int((span * params.samplingRate).rounded(.up))))
        let dt = span / Double(n)
        let from = anchor
        var out: [ModeledPoint] = []
        out.reserveCapacity(n)
        for i in 1...n {
            let f = CGFloat(i) / CGFloat(n)
            let a = CGPoint(x: from.x + (target.x - from.x) * f, y: from.y + (target.y - from.y) * f)
            time += dt
            step(toward: a, dt: dt)
            out.append(current)
        }
        time = t
        anchor = target
        return out
    }

    private mutating func step(toward a: CGPoint, dt: Double) {
        let fx = Double(a.x - position.x) / params.springMass - params.drag * Double(velocity.dx)
        let fy = Double(a.y - position.y) / params.springMass - params.drag * Double(velocity.dy)
        velocity.dx += CGFloat(fx * dt)
        velocity.dy += CGFloat(fy * dt)
        position.x += velocity.dx * CGFloat(dt)
        position.y += velocity.dy * CGFloat(dt)
    }
}
