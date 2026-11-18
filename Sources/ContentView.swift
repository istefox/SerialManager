import SwiftUI

struct ContentView: View {
    var body: some View {
        ContentUnavailableView(
            AppInfo.displayName,
            systemImage: "key.horizontal",
            description: Text(AppInfo.tagline)
        )
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
