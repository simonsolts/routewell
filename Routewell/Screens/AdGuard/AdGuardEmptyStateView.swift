import SwiftUI
import RoutewellKit

/// AdGuard Home is off on the router and Routewell has no saved copy: what
/// it does, how it should run, and Turn On.
struct AdGuardEmptyStateView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL
    /// "Filter the whole network" (Recommended) sends `dns_enabled` true.
    @State private var handlesDNS = true

    static let learnMoreURL = URL(string: "https://github.com/AdguardTeam/AdGuardHome")!

    struct Feature: Identifiable {
        let title: String
        let body: String
        let symbol: String
        let colors: [Color]
        var id: String { title }
    }

    static let features: [Feature] = [
        Feature(title: "Every device", body: "Blocks ads and trackers on anything that joins your network.",
                symbol: "laptopcomputer.and.iphone", colors: [Color(red: 0.27, green: 0.67, blue: 1), Color(red: 0, green: 0.47, blue: 0.94)]),
        Feature(title: "See every request", body: "A searchable log of what each device looks up, and why.",
                symbol: "list.bullet", colors: [Color(red: 1, green: 0.67, blue: 0.31), Color(red: 0.96, green: 0.5, blue: 0.12)]),
        Feature(title: "Lists you choose", body: "Start with a curated blocklist, or add your own.",
                symbol: "line.3.horizontal.decrease", colors: [Color(red: 0.51, green: 0.47, blue: 1), Color(red: 0.36, green: 0.31, blue: 0.9)]),
        Feature(title: "Private DNS", body: "Send lookups encrypted to the resolver you trust.",
                symbol: "lock.fill", colors: [Color(red: 0.88, green: 0.39, blue: 0.94), Color(red: 0.72, green: 0.17, blue: 0.79)]),
        Feature(title: "Safer browsing", body: "Stops known malware and phishing sites before they load.",
                symbol: "exclamationmark.shield.fill", colors: [Color(red: 1, green: 0.43, blue: 0.43), Color(red: 0.96, green: 0.18, blue: 0.2)]),
        Feature(title: "Pause any time", body: "Site broken? Turn filtering off for a few minutes.",
                symbol: "pause.fill", colors: [Color(red: 0.24, green: 0.84, blue: 0.78), Color(red: 0, green: 0.7, blue: 0.75)]),
    ]

    private var starting: Bool {
        if case .turnOn? = environment.adGuard.inFlight { return true }
        return false
    }

    /// "your Flint 4": the model when Routewell knows it.
    private var routerName: String {
        model.snapshot?.router.model.map { "your \($0)" } ?? "your router"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ShieldTile(size: 88, colors: [Color(red: 0.42, green: 0.86, blue: 0.51), Color(red: 0.15, green: 0.69, blue: 0.3)], checkmark: true)
                    Text("Block ads and trackers on every device")
                        .font(.system(size: 28, weight: .bold))
                        .multilineTextAlignment(.center)
                        .padding(.top, 22)
                    Text("AdGuard Home runs on \(routerName) and filters what your devices look up — phones, TVs and smart speakers included. Nothing to install on each device.")
                        .font(.title3).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                        .padding(.top, 8)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(200), spacing: 36), count: 3), spacing: 26) {
                        ForEach(Self.features) { feature in
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(LinearGradient(colors: feature.colors, startPoint: .top, endPoint: .bottom))
                                    .frame(width: 46, height: 46)
                                    .overlay { Image(systemName: feature.symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white) }
                                    .accessibilityHidden(true)
                                Text(feature.title).font(.headline).padding(.top, 4)
                                Text(feature.body).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, 32)
                    runChoice.padding(.top, 34)
                    Text("You can change this, or turn AdGuard Home off, any time in AdGuard Home › Instance.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 18)
                }
                .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
    }

    private var runChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How should it run?").font(.headline)
            HStack(alignment: .top, spacing: 10) {
                RunChoiceCard(title: "Filter the whole network", recommended: true,
                              detail: "The router sends every device’s DNS requests through AdGuard Home.",
                              selected: handlesDNS) { handlesDNS = true }
                RunChoiceCard(title: "Run it, don’t take over DNS", recommended: false,
                              detail: "Devices keep their current DNS unless you point them at the router yourself.",
                              selected: !handlesDNS) { handlesDNS = false }
            }
            .disabled(starting)
        }
        .frame(maxWidth: 640)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if starting {
                ProgressView().controlSize(.small)
                Text("Starting AdGuard Home on the router…").font(.callout).foregroundStyle(.secondary)
            } else if let report = environment.adGuard.lastReport, let intent = environment.adGuard.lastIntent,
                      let text = AdGuardPresentation.outcomeText(intent, report.outcome) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Learn More…") { openURL(Self.learnMoreURL) }
                .controlSize(.large)
            Button("Turn On AdGuard Home") { environment.adGuard.run(.turnOn(handlesDNS: handlesDNS)) }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(environment.adGuard.inFlight != nil || !model.session.isReady)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

/// One radio card under "How should it run?".
private struct RunChoiceCard: View {
    let title: String
    let recommended: Bool
    let detail: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(title).fontWeight(.semibold)
                    if recommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.leading, 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(selected ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The green (or grey) AdGuard Home tile with a white shield.
struct ShieldTile: View {
    let size: CGFloat
    let colors: [Color]
    var checkmark = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: checkmark ? "checkmark.shield.fill" : "shield.fill")
                    .font(.system(size: size * 0.52, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: colors.last?.opacity(0.3) ?? .clear, radius: size * 0.12, y: size * 0.1)
            .accessibilityHidden(true)
    }
}
