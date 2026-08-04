import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Hardlaw")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("On-Device AI Compliance Court")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding()
            .navigationTitle("Hardlaw")
        }
    }
}
