import SwiftUI

struct ContentView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "waveform")
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("Aloud")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)

                Text("Understand your surroundings.")
                    .font(.title2.weight(.semibold))

                Text("A voice companion for the world around you.")
                    .font(.body)

                Text("Voice and camera assistance is coming soon.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(32)
        }
    }
}

#Preview {
    ContentView()
}
