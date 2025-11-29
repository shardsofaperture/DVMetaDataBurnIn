import SwiftUI

struct SplashView: View {
    @State private var opacity: Double = 1.0
    @State private var showMain: Bool = false

    var body: some View {
        ZStack {
            if !showMain {
                // App background
                Color(NSColor.windowBackgroundColor)
                    .ignoresSafeArea()

                // CARD with all contents
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(NSColor.windowBackgroundColor))
                        .shadow(radius: 24)

                    VStack(spacing: 24) {
                        Image("SplashImage")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 300)
                            .shadow(radius: 5)
                        Text("DV Metadata Burn-In Tool")
                            .font(.system(size: 26, weight: .bold))
                        Text("© 2025 The Polish")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    // Version label in card's bottom-right
                    Text("Version 0.1A")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 18)
                        .padding(.bottom, 16)
                }
                .frame(width: 480, height: 360)
                .clipped() // Ensures no overflow
                .opacity(opacity)

            } else {
                ContentView()
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                withAnimation(.easeOut(duration: 0.7)) {
                    opacity = 0
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.8) {
                showMain = true
            }
        }
    }
}
