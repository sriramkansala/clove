import SwiftUI

/// One quiet line in place of content: "Nothing playing", "No more events".
struct MessageView: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12))
        }
        .foregroundColor(.white.opacity(0.55))
        .frame(maxWidth: .infinity)
        .frame(height: IslandLayout.messageHeight)
    }
}
