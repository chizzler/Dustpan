import SwiftUI

extension View {
    /// The window's title, shown only once the page's heading has scrolled out of sight: the name shouldn't show
    /// twice (spec/pagehead.md). Apply to the scroll view the heading is in.
    func pageTitle(_ title: String) -> some View {
        modifier(PageTitle(title: title))
    }
}

private struct PageTitle: ViewModifier {
    /// Scrolled this far, the heading is out of sight.
    static let headingHeight = 72.0
    let title: String
    @State private var scrolled = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > Self.headingHeight } action: {
                scrolled = $1
            }
            .navigationTitle(scrolled ? title : "")
    }
}
