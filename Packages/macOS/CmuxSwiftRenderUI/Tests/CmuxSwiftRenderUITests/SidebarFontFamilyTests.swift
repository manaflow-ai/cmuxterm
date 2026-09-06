import Foundation
import Testing
@testable import CmuxSwiftRenderUI

@Suite("Custom sidebar font family")
struct SidebarFontFamilyTests {
    @Test("JSON nodes retain an explicit family")
    func jsonNodeRetainsFamily() throws {
        let data = Data(
            #"{"type":"text","text":"row","family":"MonoLisaText","size":13}"#.utf8
        )
        let node = try JSONDecoder().decode(DSLNode.self, from: data)

        #expect(node.family == "MonoLisaText")
        #expect(node.size == 13)
    }

    @Test("Swift custom font tokens retain the family")
    func swiftCustomFontTokenRetainsFamily() {
        let spec = dslFontSpec(
            named: nil,
            size: 13,
            family: " MonoLisaText ")

        #expect(spec?.family == "MonoLisaText")
        #expect(spec?.baseSize == 13)
    }
}
