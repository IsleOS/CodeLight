//
//  ChatAnimations.swift
//  CodeLight
//
//  Reusable animated view components used by MessageRow and friends. Kept in
//  their own file so ChatView stays focused on the high-level chat layout.
//

import SwiftUI

/// A small dot that pulses between two sizes/opacities continuously. Used by the
/// running-tool indicator and wherever we need to say "something is in flight".
struct PulseDot: View {
    let color: Color
    let size: CGFloat
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(on ? 1.15 : 0.75)
            .opacity(on ? 1.0 : 0.45)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Conditionally applies `shimmering()` only when the tool is running.
/// Needed because SwiftUI can't swap modifiers mid-hierarchy without this
/// @ViewBuilder trick — re-creating the modifier on every frame would stutter.
struct ToolRunningShimmer: ViewModifier {
    let isRunning: Bool
    func body(content: Content) -> some View {
        if isRunning {
            content.shimmering()
        } else {
            content
        }
    }
}

/// A modifier that sweeps a soft highlight across the content horizontally,
/// creating a "scanning" feel for in-flight states. Used by running tool cards.
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -0.4

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    let gradient = LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white.opacity(0), location: 0.0),
                            .init(color: .white.opacity(0.22), location: 0.5),
                            .init(color: .white.opacity(0), location: 1.0),
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    Rectangle()
                        .fill(gradient)
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: phase * geo.size.width * 2)
                        .blendMode(.plusLighter)
                }
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 0.8
                }
            }
    }
}

extension View {
    /// Applies the shimmer sweep effect (see `ShimmerModifier`).
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}

/// A row of three dots that cascade up and down, giving "thinking…" a heartbeat
/// so empty thinking events feel alive instead of static.
struct ThinkingDots: View {
    let color: Color
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color.opacity(0.9))
                    .frame(width: 4, height: 4)
                    .scaleEffect(phase == i ? 1.4 : 0.8)
                    .opacity(phase == i ? 1.0 : 0.4)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}
