import Darwin
import Foundation
import Testing
import Bonsplit
import CmuxCore
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentHibernationTests {
}
