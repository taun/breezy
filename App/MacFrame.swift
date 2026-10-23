import SwiftUI

extension View {
    /// A minimum size for sheets on macOS, where they would otherwise be tiny. On iPhone and iPad sheets size themselves;
    /// a minimum wider than the screen would push content off it.
    func macSheetFrame(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self
        #endif
    }
}
