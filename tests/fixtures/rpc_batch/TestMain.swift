import Darwin
import Testing

@main struct RPCBatchTestMain {
    static func main() async {
        let status: CInt = await Testing.__swiftPMEntryPoint()
        exit(status)
    }
}
