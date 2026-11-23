import Testing
@testable import Crease

/// Address suggestions put Brooklyn first and drop other states once Brooklyn
/// has a match (owner, 2026-11-22). The case that prompted it: typing
/// "251 Dek" offered King of Prussia, PA and Bridgeport, CT next to the real
/// Brooklyn address.
struct AddressRankingTests {
    private func ranked(_ subtitles: [String]) -> [String] {
        AddressSearch.ranked(subtitles) { $0 }
    }

    @Test func brooklynComesFirstAndOtherStatesGo() {
        let result = ranked([
            "King Of Prussia, PA, United States",
            "Brooklyn, NY, United States",
            "Bridgeport, CT, United States",
        ])
        #expect(result == ["Brooklyn, NY, United States"])
    }

    @Test func restOfNewYorkFollowsBrooklynInMapKitOrder() {
        let result = ranked([
            "New York, NY, United States",
            "Brooklyn, NY 11205, United States",
            "Queens, NY, United States",
            "Brooklyn, NY 11217, United States",
            "Hoboken, NJ, United States",
        ])
        #expect(result == [
            "Brooklyn, NY 11205, United States",
            "Brooklyn, NY 11217, United States",
            "New York, NY, United States",
            "Queens, NY, United States",
        ])
    }

    @Test func withNoBrooklynMatchNothingIsDropped() {
        let input = ["Hoboken, NJ, United States", "Queens, NY, United States"]
        #expect(ranked(input) == ["Queens, NY, United States", "Hoboken, NJ, United States"])
    }

    @Test func threeRowsCountTheHomeAddress() {
        #expect(AddressEntryView.rowLimit == 3)
    }
}
