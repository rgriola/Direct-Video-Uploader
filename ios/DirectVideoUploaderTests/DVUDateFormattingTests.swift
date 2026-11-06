import Foundation
import Testing

// Compile the production source into the test target to isolate formatter state from the hosted app.
@Suite(.serialized)
@MainActor
struct DVUDateFormattingTests {
    @Test
    func parsesISOWithAndWithoutFractionalSeconds() {
        #expect(DVUDateFormatting.parseISO("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
        #expect(
            DVUDateFormatting.parseISO("1970-01-01T00:00:00.125Z")
                == Date(timeIntervalSince1970: 0.125)
        )
        #expect(
            DVUDateFormatting.parseISO("1970-01-01T02:00:00+02:00")
                == Date(timeIntervalSince1970: 0)
        )
        #expect(DVUDateFormatting.parseISO("not a date") == nil)
    }

    @Test
    func formatsISOAndPreservesInvalidDisplayInputs() {
        #expect(DVUDateFormatting.isoString(from: Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
        #expect(DVUDateFormatting.longDate("not a date") == "not a date")
        #expect(DVUDateFormatting.shortDate("not a date") == "not a date")
        #expect(DVUDateFormatting.timeOnly("not a date") == nil)
    }

    @Test
    func formatsDurationsAtMinuteBoundaries() {
        #expect(DVUDateFormatting.duration(0) == "0:00")
        #expect(DVUDateFormatting.duration(59) == "0:59")
        #expect(DVUDateFormatting.duration(60) == "1:00")
        #expect(DVUDateFormatting.duration(125) == "2:05")
        #expect(DVUDateFormatting.duration(3_600) == "60:00")
    }

    @Test
    func formatsFileSizesAtExistingThresholds() {
        #expect(DVUDateFormatting.fileSize("0") == "0 B")
        #expect(DVUDateFormatting.fileSize("1000") == "1000 B")
        #expect(DVUDateFormatting.fileSize("1001") == "1 KB")
        #expect(DVUDateFormatting.fileSize("1000000") == "1000 KB")
        #expect(DVUDateFormatting.fileSize("1000001") == "1.0 MB")
        #expect(DVUDateFormatting.fileSize("1000000000") == "1000.0 MB")
        #expect(DVUDateFormatting.fileSize("1000000001") == "1.0 GB")
        #expect(DVUDateFormatting.fileSize("unknown") == "unknown")
    }
}
