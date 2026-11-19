import SwiftUI

/// Title shown at the top of a sheet: sheets on macOS have no title bar.
struct SheetHeader: View {
    let title: Text

    var body: some View {
        title
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .accessibilityAddTraits(.isHeader)
    }
}
