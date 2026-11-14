import Foundation

/// Spring parameters in SwiftUI's terms: `response` is the period of the undamped spring in seconds,
/// `damping` is the damping fraction (1 = critically damped, no overshoot).
public struct SpringParams: Sendable, Equatable {
    public var response: Double
    public var damping: Double

    public init(response: Double, damping: Double) {
        self.response = response
        self.damping = damping
    }

    var omega: Double { 2 * .pi / response }
}

/// A damped spring stepped with the exact closed-form solution, so any frame length is stable and the
/// result is the same at 60, 120 or 240 Hz. Retargeting keeps position and velocity, which is what
/// makes every pill animation interruptible.
public struct Spring: Sendable, Equatable {
    public var value: Double
    public var velocity: Double = 0
    public var target: Double
    public var params: SpringParams

    public init(_ value: Double, params: SpringParams) {
        self.value = value
        self.target = value
        self.params = params
    }

    /// Jumps to `value` with no motion.
    public mutating func snap(to value: Double) {
        self.value = value
        target = value
        velocity = 0
    }

    public var isSettled: Bool { abs(value - target) < 1e-3 && abs(velocity) < 1e-2 }

    public mutating func step(_ dt: Double) {
        guard dt > 0 else { return }
        if isSettled { value = target; velocity = 0; return }
        let w = params.omega, z = params.damping
        let x0 = value - target, v0 = velocity
        let x: Double, v: Double
        if z < 1 {
            let wd = w * (1 - z * z).squareRoot()
            let e = exp(-z * w * dt), c = cos(wd * dt), s = sin(wd * dt)
            x = e * (x0 * c + (v0 + z * w * x0) / wd * s)
            v = e * (v0 * c - (z * w * v0 + w * w * x0) / wd * s)
        } else if z == 1 {
            let e = exp(-w * dt)
            x = (x0 + (v0 + w * x0) * dt) * e
            v = (v0 - w * (v0 + w * x0) * dt) * e
        } else {
            let s = (z * z - 1).squareRoot()
            let r1 = -w * (z - s), r2 = -w * (z + s)
            let c1 = (v0 - r2 * x0) / (r1 - r2), c2 = x0 - c1
            let e1 = exp(r1 * dt), e2 = exp(r2 * dt)
            x = c1 * e1 + c2 * e2
            v = c1 * r1 * e1 + c2 * r2 * e2
        }
        value = target + x
        velocity = v
    }
}
