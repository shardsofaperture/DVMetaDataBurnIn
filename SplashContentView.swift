import SwiftUI

struct SplashContentView: View {
    var body: some View {
        ZStack {
            // Fullscreen dark/gray background
            Color(NSColor.windowBackgroundColor)
                .opacity(0.97)
                .ignoresSafeArea()

            // Centered card
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(radius: 12)

                VStack(spacing: 18) {
                    Image("SplashImage")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 320)
                        .cornerRadius(8)

                    Text("DV Metadata Burn-In Tool")
                        .font(.system(size: 26, weight: .bold))

                    HStack(spacing: 16) {
                        Text("© 2025 The Polish")
                        Text("Version 0.1A")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(32)
            }
            .frame(width: 540, height: 380)
        }
    }
}
