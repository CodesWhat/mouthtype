import AppKit
import QuartzCore

/// Layer animation helpers for the skins drawn with Core Animation: set a model value and, when asked, animate to it
/// from wherever the layer is on screen.
@MainActor
enum PillMotion {
    enum Timing {
        case none, spring
        case ease(TimeInterval, delay: TimeInterval = 0)
        case easeIn(TimeInterval)
    }

    static let easeOutCubic = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
    static let easeInCubic = CAMediaTimingFunction(controlPoints: 0.55, 0.055, 0.675, 0.19)

    static func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    static func set(_ layer: CALayer, _ keyPath: String, _ value: Any, _ timing: Timing) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        withoutActions { layer.setValue(value, forKeyPath: keyPath) }
        let animation: CABasicAnimation
        switch timing {
        case .none:
            layer.removeAnimation(forKey: keyPath)
            return
        case .spring:
            // Critically damped with a 55 ms time constant: about 95 percent there at 165 ms and no overshoot.
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.mass = 1
            spring.stiffness = 331
            spring.damping = 36.4
            spring.duration = spring.settlingDuration
            animation = spring
        case .ease(let duration, let delay):
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = duration
            animation.beginTime = delay > 0 ? layer.convertTime(CACurrentMediaTime(), from: nil) + delay : 0
            animation.fillMode = .backwards
            animation.timingFunction = easeOutCubic
        case .easeIn(let duration):
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = duration
            animation.timingFunction = easeInCubic
        }
        animation.fromValue = from
        animation.toValue = value
        layer.add(animation, forKey: keyPath)
    }
}
