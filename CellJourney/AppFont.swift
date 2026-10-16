import SwiftUI
import UIKit

extension Font {
    /// Family name of the font used for all text. Its file is listed under `UIAppFonts` in Info.plist.
    static let appFamily = "Comfortaa"

    /// The app font at the system size of `style`, scaling with Dynamic Type like the system font does.
    static func app(_ style: Font.TextStyle) -> Font {
        .custom(appFamily, size: UIFont.preferredFont(forTextStyle: style.uiKit).pointSize, relativeTo: style)
    }
}

extension Font.TextStyle {
    fileprivate var uiKit: UIFont.TextStyle {
        switch self {
        case .extraLargeTitle: .extraLargeTitle
        case .extraLargeTitle2: .extraLargeTitle2
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
