import AppKit
import SwiftUI
import Testing
@testable import Routewell

/// Writes one PNG per onboarding state, light and dark, to the test host's
/// temporary folder (`onboarding-snapshots`, inside the app's sandbox
/// container) when `ROUTEWELL_SNAPSHOTS=1` (`TEST_RUNNER_ROUTEWELL_SNAPSHOTS=1`
/// with xcodebuild). For reviewing the layout; it checks nothing else.
@MainActor @Test func writeOnboardingSnapshotsWhenAsked() throws {
    guard ProcessInfo.processInfo.environment["ROUTEWELL_SNAPSHOTS"] == "1" else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        for state in OnboardingState.allCases {
            let model = OnboardingModel(services: MockOnboardingServices(scenario: .found, delay: .zero))
            model.preview(state)
            let view = NSHostingView(rootView: OnboardingView(model: model))
            view.appearance = NSAppearance(named: appearance)
            view.frame = CGRect(origin: .zero, size: OnboardingView.size)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let name = "\(state.rawValue)-\(appearance == .aqua ? "light" : "dark").png"
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        }
    }
    // The same tiles through ImageRenderer, to compare with the window capture.
    let tiles = HStack(spacing: 12) {
        ForEach([ArtMotif.router, .search, .done, .tag], id: \.self) { OnboardingArt(motif: $0, tint: .teal, size: 84) }
    }.padding(12).background(Color.white)
    let renderer = ImageRenderer(content: tiles)
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("tiles-renderer.png"))
    }
}
