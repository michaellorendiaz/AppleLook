import Foundation
import Testing
@testable import AppleLookCore

// Same cases as the server's TitleTemplateTests, UpgradeTests and AltTitleTests
// (server/tests/test_engine.py)

func options(_ tweak: (inout SyncOptions) -> Void) -> SyncOptions {
    var o = SyncOptions()
    tweak(&o)
    return o
}

/// Settings as an older version saved them, decoded the way the app loads them.
func saved(_ json: String) throws -> SyncOptions {
    try JSONDecoder().decode(SyncOptions.self, from: Data(json.utf8))
}

@Suite struct TitleTemplateTests {
    @Test func customTemplates() {
        let cases = [
            "Work: {event}": "Work: Budget review",
            "{event} (Work)": "Budget review (Work)",
            "[Work] {event}": "[Work] Budget review",
            "{event}": "Budget review",
            "Out of office": "Out of office",
            "": "Busy",
        ]
        for (template, title) in cases {
            #expect(Feed.summary(title: "Budget review", options: options { $0.titleFormat = template }) == title,
                    "\(template)")
        }
    }

    @Test func anEmptyTitleLeavesNoStrayPunctuation() {
        #expect(Feed.renderTitle("Work ({event})", event: "") == "Work")
        #expect(Feed.renderTitle("Work: {event}", event: " ") == "Work")
        #expect(Feed.renderTitle("({event})", event: "") == "Busy")
    }

    @Test func theMeetingTitleIsNeverTrimmed() {
        #expect(Feed.renderTitle("{event}", event: "Sync w/ J.R.") == "Sync w/ J.R.")
    }

    @Test func noEventVariableMeansNoTitles() {
        #expect(Set(titles(desired { $0.titleFormat = "Work" })) == ["Work"])
    }

    @Test func theToggleAddsAndRemovesEvent() {
        #expect(Feed.addingVariable("{event}", to: "") == "{event}")
        #expect(Feed.addingVariable("{event}", to: "Work") == "Work ({event})")
        #expect(Feed.addingVariable("{event}", to: "Michael: Work ") == "Michael: Work ({event})")
        // unticking: take it out and tidy
        #expect(Feed.tidyTemplate("Work ()") == "Work")
        #expect(Feed.tidyTemplate("Work: ") == "Work")
    }

    @Test func includeTitlesFollowsTheTemplate() {
        var o = SyncOptions()
        o.titleFormat = "Work: {event}"
        #expect(o.includeTitles)
        o.titleFormat = "Work"
        #expect(!o.includeTitles)
    }
}

@Suite struct UpgradeTests {
    // Settings from before 0.3.2 had a label and an alternative label; their titles must
    // come out exactly as before

    @Test func settingsFromBeforeTemplates() throws {
        for (label, titles) in [("Work", true), ("", true), ("Work", false), ("", false)] {
            let o = try saved(#"{"label":"\#(label)","includeTitles":\#(titles)}"#)
            let old = !label.isEmpty && titles ? "\(label) (Budget review)"
                : !label.isEmpty ? label : titles ? "Budget review" : "Busy"
            #expect(Feed.summary(title: "Budget review", options: o) == old)
        }
    }

    @Test func labelsAreWrittenIntoTheTemplates() throws {
        let o = try saved(#"{"label":"Work","titleFormat":"Michael: {label} ({event})","altLabelKeywords":["ART"],"altLabel":"Teaching","altTitleFormat":""}"#)
        #expect(o.titleFormat == "Michael: Work ({event})")
        #expect(o.altTitleFormat == "Michael: Teaching ({event})", "the alternative label stood in for the label")
        #expect(Feed.summary(title: "ART 120", options: o) == "Michael: Teaching (ART 120)")
    }

    @Test func alternativeTemplateWithBothLabels() throws {
        let o = try saved(#"{"label":"Work","titleFormat":"{label}","altLabel":"","altTitleFormat":"{altlabel}: {event} · {label}"}"#)
        #expect(o.altTitleFormat == "{event} · Work", "an empty label is taken out")
    }

    @Test func anEmptyLabel() throws {
        let o = try saved(#"{"label":"","titleFormat":"{label} ({event})"}"#)
        #expect(o.titleFormat == "{event}")
        #expect(o.altTitleFormat == "")
    }

    @Test func newSettingsAreLeftAlone() throws {
        let o = try saved(#"{"titleFormat":"{event} ({label})"}"#)
        #expect(o.titleFormat == "{event} ({label})")
    }

    @Test func theLabelsAreNotSavedAgain() throws {
        let o = try saved(#"{"label":"Work","altLabel":"Teaching","includeTitles":true}"#)
        let json = String(decoding: try JSONEncoder().encode(o), as: UTF8.self)
        #expect(!json.contains("\"label\"") && !json.contains("\"altLabel\""))
        #expect(try saved(json) == o, "saving and loading again changes nothing")
    }
}

@Suite struct AltTitleTests {
    let base = options { $0.titleFormat = "Work ({event})"; $0.altLabelKeywords = ["ART"]; $0.altTitleFormat = "Teaching ({event})" }

    func with(_ tweak: (inout SyncOptions) -> Void) -> SyncOptions {
        var o = base
        tweak(&o)
        return o
    }

    @Test func keywordSwitchesTheTitle() {
        #expect(Feed.summary(title: "ART 120 Drawing I", options: base) == "Teaching (ART 120 Drawing I)")
        #expect(Feed.summary(title: "Studio: ART209", options: base) == "Teaching (Studio: ART209)",
                "a course number may follow")
        #expect(Feed.summary(title: "Budget review", options: base) == "Work (Budget review)")
    }

    @Test func caseSensitiveWholeWord() {
        for title in ["Art show", "art 120", "PARTY planning", "DEPARTMENT meeting", "ARTS council", "ARTshow"] {
            #expect(!Feed.altRuleApplies(title: title, options: base), "\(title)")
        }
        #expect(Feed.altRuleApplies(title: "Critique (ART 209)", options: base))
        #expect(Feed.altRuleApplies(title: "ART123", options: base))
    }

    @Test func severalKeywordsAndNoTitles() {
        let o = with { $0.altLabelKeywords = ["ART", "DES"]; $0.titleFormat = "Work"; $0.altTitleFormat = "Teaching" }
        #expect(Feed.summary(title: "DES 101", options: o) == "Teaching")
        #expect(Feed.summary(title: "Faculty meeting", options: o) == "Work")
    }

    @Test func theRuleCanShowTitlesWhenOthersDont() {
        let o = with { $0.titleFormat = "Work"; $0.altTitleFormat = "Class: {event}" }
        #expect(Feed.summary(title: "ART 209", options: o) == "Class: ART 209")
        #expect(Feed.summary(title: "Budget review", options: o) == "Work")
    }

    @Test func emptyAlternativeTitleUsesTheUsualOne() {
        #expect(Feed.summary(title: "ART 120", options: with { $0.altTitleFormat = "" }) == "Work (ART 120)")
    }

    @Test func noKeywordsChangesNothing() {
        #expect(Feed.summary(title: "ART 120", options: with { $0.altLabelKeywords = [] }) == "Work (ART 120)")
    }

    @Test func keywordWithRegexCharacters() {
        #expect(Feed.altRuleApplies(title: "C++ lab", options: with { $0.altLabelKeywords = ["C++"] }))
    }
}
