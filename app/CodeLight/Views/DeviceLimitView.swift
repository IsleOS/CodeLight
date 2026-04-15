import SwiftUI

/// Shown when the server sends `device-limit-reached` — the user's lifetime
/// license is already active on another device. Simple informational sheet.
struct DeviceLimitView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()

                VStack(spacing: 24) {
                    Spacer()

                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.warning)

                    VStack(spacing: 10) {
                        Text(String(localized: "device_limit_title"))
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.textPrimary)

                        Text(String(localized: "device_limit_body"))
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }

                    Button {
                        dismiss()
                    } label: {
                        Text(String(localized: "dismiss"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(Theme.textPrimary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Theme.border, lineWidth: 0.5)
                            )
                    }
                    .padding(.horizontal, 40)

                    Spacer()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
