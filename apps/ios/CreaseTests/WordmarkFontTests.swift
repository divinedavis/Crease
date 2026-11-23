import CoreText
import Testing
import UIKit
@testable import Crease

/// The "crease" wordmark is Playfair Display Italic Bold (owner, 2026-11-23).
/// A missing UIAppFonts entry or a wrong PostScript name does not crash: UIKit
/// quietly draws the system font instead, so these pin the face and weight.
struct WordmarkFontTests {
    @Test func theWordmarkFaceIsRegistered() {
        #expect(UIFont(name: WordmarkFont.postScriptName, size: 20) != nil)
    }

    @Test func theWordmarkIsPlayfairItalic() {
        let font = WordmarkFont.uiFont(size: 40)
        // At 700 on the axis iOS resolves the font's named Bold Italic
        // instance, so the family is what stays fixed, not the name.
        #expect(font.familyName == "Playfair Display")
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
        #expect(font.pointSize == 40)
    }

    @Test func theWordmarkIsDrawnAtBoldOnTheWeightAxis() {
        let font = WordmarkFont.uiFont(size: 40) as CTFont
        let variation = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
        let weight = variation?[NSNumber(value: WordmarkFont.weightAxis)]?.doubleValue
        #expect(weight == 700)
    }
}
