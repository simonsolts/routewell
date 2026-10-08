import Foundation
import SwiftUI
import Testing
@testable import Routewell

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

@Test func pulseStartsSmallAndInvisible() {
    let a = OnboardingArtAnimation.pulse(time: 0, delay: 0, reduceMotion: false)
    #expect(near(a.scale, 0.45))
    #expect(near(a.opacity, 0))
}

@Test func pulseReachesPeakOpacityAtQuarterCycle() {
    let a = OnboardingArtAnimation.pulse(time: 0.6, delay: 0, reduceMotion: false)
    #expect(near(a.opacity, 0.9))
    // ease-out runs ahead of a linear ramp from .45 to 1.2.
    #expect(a.scale > 0.45 + 0.75 * 0.25)
    #expect(a.scale < 1.2)
}

@Test func pulseEndsLargeAndInvisibleThenRestarts() {
    let end = OnboardingArtAnimation.pulse(time: 2.4 - 1e-9, delay: 0, reduceMotion: false)
    #expect(near(end.scale, 1.2, 1e-4))
    #expect(near(end.opacity, 0, 1e-4))
    let wrapped = OnboardingArtAnimation.pulse(time: 2.4, delay: 0, reduceMotion: false)
    #expect(near(wrapped.scale, 0.45))
    #expect(near(wrapped.opacity, 0))
}

@Test func pulseDelayShiftsPhaseAndWrapsBeforeTheDelay() {
    let shifted = OnboardingArtAnimation.pulse(time: 1.3, delay: 0.8, reduceMotion: false)
    let base = OnboardingArtAnimation.pulse(time: 0.5, delay: 0, reduceMotion: false)
    #expect(near(shifted.scale, base.scale))
    #expect(near(shifted.opacity, base.opacity))
    // At time 0 the ring with delay 1.6 is already part-way through its cycle (phase 0.8 s), not static.
    let early = OnboardingArtAnimation.pulse(time: 0, delay: 1.6, reduceMotion: false)
    let steady = OnboardingArtAnimation.pulse(time: 0.8, delay: 0, reduceMotion: false)
    #expect(near(early.scale, steady.scale))
    #expect(near(early.opacity, steady.opacity))
    #expect(early.opacity > 0 && early.opacity < 0.9)
}

@Test func blinkIsFullForFirstHalfAndDimForSecondHalf() {
    #expect(OnboardingArtAnimation.blinkOpacity(time: 0, reduceMotion: false) == 1)
    #expect(OnboardingArtAnimation.blinkOpacity(time: 0.59, reduceMotion: false) == 1)
    #expect(OnboardingArtAnimation.blinkOpacity(time: 0.6, reduceMotion: false) == 0.35)
    #expect(OnboardingArtAnimation.blinkOpacity(time: 1.19, reduceMotion: false) == 0.35)
    #expect(OnboardingArtAnimation.blinkOpacity(time: 1.2, reduceMotion: false) == 1)
    #expect(OnboardingArtAnimation.blinkOpacity(time: 1.9, reduceMotion: false) == 0.35)
    #expect(OnboardingArtAnimation.blinkOpacity(time: -0.1, reduceMotion: false) == 0.35)
}

@Test func reduceMotionShowsTheUnanimatedState() {
    for time in [0.0, 0.6, 1.3, 2.39] {
        for delay in [0.0, 0.8, 1.6] {
            let a = OnboardingArtAnimation.pulse(time: time, delay: delay, reduceMotion: true)
            #expect(a.scale == 1)
            #expect(a.opacity == 1)
        }
        #expect(OnboardingArtAnimation.blinkOpacity(time: time, reduceMotion: true) == 1)
    }
}

@Test func svgPathParsesRelativeCommandsAndClose() {
    let path = SVGPathParser.parse("M22 58 h16 v14 h-4 v3 h-8 v-3 h-4 z")
    #expect(path.boundingRect == CGRect(x: 22, y: 58, width: 16, height: 17))
}

@Test func svgPathArcBecomesTightHalfCircle() {
    // Half circle of radius 18 over the top of (42,44)-(78,44).
    let box = SVGPathParser.parse("M42 44 A18 18 0 0 1 78 44").cgPath.boundingBoxOfPath
    #expect(near(box.minX, 42, 1e-6) && near(box.maxX, 78, 1e-6))
    #expect(near(box.minY, 26, 1e-3) && near(box.maxY, 44, 1e-6))
}

@Test func svgShapeScalesFixedSpaceToFrame() {
    let box = SVGShape(x: 12, y: 30, width: 60, height: 30).path(in: CGRect(x: 0, y: 0, width: 240, height: 240)).boundingRect
    #expect(box == CGRect(x: 24, y: 60, width: 120, height: 60))
}

@MainActor @Test func everyMotifAndBadgeLaysOutAtItsSize() {
    for motif in ArtMotif.allCases {
        for badge in [nil] + ArtBadge.allCases.map(Optional.some) {
            let view = NSHostingView(rootView: OnboardingArt(motif: motif, tint: .teal, badge: badge, size: 64))
            #expect(view.fittingSize == CGSize(width: 64, height: 64))
        }
    }
}
