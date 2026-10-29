import Foundation
import CoreGraphics

/// One-Euro filter (Casiez, Roussel, Vogel 2012) for a single scalar signal.
///
/// Units here: position in view points, time in seconds (NSEvent.timestamp),
/// so derivative is in points/second. Cutoff frequencies are in Hz.
///   cutoff = minCutoff + beta * |smoothed speed|
/// - minCutoff: lower = more smoothing (more lag) when moving slowly.
/// - beta: higher = less lag when moving fast.
public struct OneEuroFilter1D {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double

    private var prevX: Double?
    private var prevDX: Double = 0
    private var prevT: Double?

    public init(minCutoff: Double, beta: Double, dCutoff: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    public mutating func reset() {
        prevX = nil
        prevDX = 0
        prevT = nil
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    public mutating func filter(_ x: Double, t: Double) -> Double {
        guard let px = prevX, let pt = prevT else {
            prevX = x
            prevT = t
            prevDX = 0
            return x
        }
        var dt = t - pt
        // Guard against duplicate / out-of-order timestamps (assume ~120 Hz).
        if !(dt > 1e-6) { dt = 1.0 / 120.0 }

        let dx = (x - px) / dt
        let aD = Self.alpha(cutoff: dCutoff, dt: dt)
        let edx = aD * dx + (1 - aD) * prevDX

        let cutoff = minCutoff + beta * abs(edx)
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        let result = a * x + (1 - a) * px

        prevX = result
        prevDX = edx
        prevT = t
        return result
    }
}

/// Two independent One-Euro filters for x and y.
public struct OneEuroFilter2D {
    private var fx: OneEuroFilter1D
    private var fy: OneEuroFilter1D

    public init(minCutoff: Double, beta: Double, dCutoff: Double) {
        fx = OneEuroFilter1D(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
        fy = OneEuroFilter1D(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
    }

    public mutating func setParams(minCutoff: Double, beta: Double, dCutoff: Double) {
        fx.minCutoff = minCutoff; fx.beta = beta; fx.dCutoff = dCutoff
        fy.minCutoff = minCutoff; fy.beta = beta; fy.dCutoff = dCutoff
    }

    public mutating func reset() {
        fx.reset()
        fy.reset()
    }

    public mutating func filter(_ p: CGPoint, t: TimeInterval) -> CGPoint {
        CGPoint(x: fx.filter(Double(p.x), t: t), y: fy.filter(Double(p.y), t: t))
    }
}
