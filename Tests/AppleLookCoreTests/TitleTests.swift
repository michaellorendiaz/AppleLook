import Foundation
import Testing
@testable import AppleLookCore

// Same cases as the server's TitleTemplateTests and AltLabelTests (server/tests/test_engine.py)

func options(_ tweak: (inout SyncOptions) -> Void) -> SyncOptions {
    var o = SyncOptions()
    o.label = "Work"
    tweak(&o)
    return o
}

@Suite struct TitleTemplateTests {
    @Test func oldSettingsKeepTheirTitles() {
        // settings saved before templates existed must produce exactly the same titles
        for (label, titles) in [("Work", true), ("", true), ("Work", false), ("", false)] {
            let o = options { $0.label = label; $0.includeTitles = titles }
            let old = !label.isEmpty && titles ? "\(label) (Budget review)"
                : !label.isEmpty ? label : titles ? "Budget review" : "Busy"
            #expect(Feed.summary(title: "Budget review", options: o) == old)
        }
    }

    @Test func savedBefore030Decodes() throws {
        let old = #"{"label":"Work","includeTitles":true}"#
        let o = try JSONDecoder().decode(SyncOptions.self, from: Data(old.utf8))
        #expect(o.titleFormat == nil && o.titleTemplate == "{label} ({event})")
        #expect(o.altLabelKeywords.isEmpty && o.altLabel.isEmpty && o.altTitleFormat.isEmpty)
    }

    @Test func customTemplates() {
        let cases = [
            "{label}: {event}": "Work: Budget review",
            "{event} ({label})": "Budget review (Work)",
            "[{label}] {event}": "[Work] Budget review",
            "{event}": "Budget review",
            "Out of office": "Out of office",
            "": "Busy",
        ]
        for (template, title) in cases {
            #expect(Feed.summary(title: "Budget review", options: options { $0.titleFormat = template }) == title,
                    "\(template)")
        }
    }

    @Test func anEmptyVariableLeavesNoStrayPunctuation() {
        #expect(Feed.renderTitle("{label} ({event})", label: "Work", event: "") == "Work")
        #expect(Feed.renderTitle("{label}: {event}", label: "", event: "Budget review") == "Budget review")
        #expect(Feed.renderTitle("{event} [{label}]", label: "", event: "Budget review") == "Budget review")
        #expect(Feed.renderTitle("({label})", label: "", event: "") == "Busy")
    }

    @Test func theMeetingTitleIsNeverTrimmed() {
        #expect(Feed.renderTitle("{label}: {event}", label: "", event: "Sync w/ J.R.") == "Sync w/ J.R.")
    }

    @Test func noEventVariableMeansNoTitles() {
        #expect(Set(titles(desired { $0.label = "Work"; $0.titleFormat = "{label}" })) == ["Work"])
    }

    @Test func togglesAddAndRemoveVariables() {
        #expect(Feed.addingVariable("{event}", to: "") == "{event}")
        #expect(Feed.addingVariable("{event}", to: "{label}") == "{label} ({event})")
        #expect(Feed.addingVariable("{label}", to: "{event}") == "{label} ({event})")
        #expect(Feed.addingVariable("{event}", to: "Class:") == "Class: {event}")
        #expect(Feed.addingVariable("{altlabel}", to: "{event} today") == "{altlabel} {event} today")
        // turning one off: take it out and tidy
        #expect(Feed.tidyTemplate("{label} ()") == "{label}")
        #expect(Feed.tidyTemplate(" ({event})") == "{event}")
        #expect(Feed.tidyTemplate(": {event}") == "{event}")
    }

    @Test func includeTitlesFollowsTheTemplate() {
        var o = SyncOptions()
        o.titleFormat = "{label}: {event}"
        #expect(o.includeTitles)
        o.titleFormat = "{label}"
        #expect(!o.includeTitles)
    }
}

@Suite struct AltLabelTests {
    let base = options { $0.includeTitles = true; $0.altLabelKeywords = ["ART"]; $0.altLabel = "Teaching" }

    func with(_ tweak: (inout SyncOptions) -> Void) -> SyncOptions {
        var o = base
        tweak(&o)
        return o
    }

    @Test func keywordSwitchesTheLabel() {
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
        let o = with { $0.altLabelKeywords = ["ART", "DES"]; $0.titleFormat = "{label}" }
        #expect(Feed.summary(title: "DES 101", options: o) == "Teaching")
        #expect(Feed.summary(title: "Faculty meeting", options: o) == "Work")
    }

    @Test func itsOwnEventTitle() {
        var o = with { $0.altTitleFormat = "{event} ({altlabel})" }
        #expect(Feed.summary(title: "ART 120", options: o) == "ART 120 (Teaching)")
        #expect(Feed.summary(title: "Budget review", options: o) == "Work (Budget review)",
                "other meetings keep the usual title")
        o = with { $0.titleFormat = "{label}"; $0.altTitleFormat = "Class: {event}" }
        #expect(Feed.summary(title: "ART 209", options: o) == "Class: ART 209",
                "the rule can show titles even when others don't")
        #expect(Feed.summary(title: "Budget review", options: o) == "Work")
    }

    @Test func bothLabels() {
        var o = with { $0.altTitleFormat = "{altlabel} · {label}" }
        #expect(Feed.summary(title: "ART 120", options: o) == "Teaching · Work",
                "{label} stays the usual label in the rule's own title")
        o = with { $0.altLabel = ""; $0.altTitleFormat = "{altlabel}: {event}" }
        #expect(Feed.summary(title: "ART 120", options: o) == "ART 120", "an empty one is taken out")
    }

    @Test func noKeywordsChangesNothing() {
        #expect(Feed.summary(title: "ART 120", options: with { $0.altLabelKeywords = [] }) == "Work (ART 120)")
    }

    @Test func keywordWithRegexCharacters() {
        #expect(Feed.altRuleApplies(title: "C++ lab", options: with { $0.altLabelKeywords = ["C++"] }))
    }
}
