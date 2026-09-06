import Darwin
import Foundation

/// Reads return addresses from a suspended Mach thread's frame-pointer chain.
struct MachThreadStackAddressSampler {
    private static let maximumStackWalkBytes: UInt = 8 * 1024 * 1024

    static func captureAddresses(for thread: thread_act_t, maxFrames: Int) -> [UInt] {
        guard maxFrames > 0 else { return [] }

        let suspendResult = thread_suspend(thread)
        guard suspendResult == KERN_SUCCESS else { return [] }
        defer { thread_resume(thread) }

        guard let registers = initialRegisters(for: thread) else { return [] }
        var addresses: [UInt] = []
        addresses.reserveCapacity(maxFrames)
        addresses.append(normalizedInstructionPointer(registers.instructionPointer))

        var framePointer = registers.framePointer
        var visited = Set<UInt>()
        while addresses.count < maxFrames,
              isPlausibleFramePointer(framePointer),
              visited.insert(framePointer).inserted,
              let record = readFrameRecord(at: framePointer) {
            let returnAddress = normalizedInstructionPointer(record.returnAddress)
            if returnAddress != 0 {
                addresses.append(returnAddress)
            }

            let nextFramePointer = record.previousFramePointer
            guard nextFramePointer > framePointer,
                  nextFramePointer - framePointer <= maximumStackWalkBytes else {
                break
            }
            framePointer = nextFramePointer
        }

        return addresses
    }

    private static func initialRegisters(for thread: thread_act_t) -> (instructionPointer: UInt, framePointer: UInt)? {
        #if arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &state) { statePointer in
            statePointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
                thread_get_state(
                    thread,
                    thread_state_flavor_t(x86_THREAD_STATE64),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (UInt(state.__rip), UInt(state.__rbp))
        #elseif arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &state) { statePointer in
            statePointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
                thread_get_state(
                    thread,
                    thread_state_flavor_t(ARM_THREAD_STATE64),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (UInt(state.__pc), UInt(state.__fp))
        #else
        return nil
        #endif
    }

    private static func readFrameRecord(at framePointer: UInt) -> StackFrameRecord? {
        var record = StackFrameRecord()
        var bytesRead = mach_vm_size_t(0)
        let size = mach_vm_size_t(MemoryLayout<StackFrameRecord>.stride)
        let result = withUnsafeMutableBytes(of: &record) { buffer -> kern_return_t in
            guard let baseAddress = buffer.baseAddress else { return KERN_FAILURE }
            return mach_vm_read_overwrite(
                mach_task_self_,
                mach_vm_address_t(framePointer),
                size,
                mach_vm_address_t(UInt(bitPattern: baseAddress)),
                &bytesRead
            )
        }
        guard result == KERN_SUCCESS, bytesRead == size else { return nil }
        return record
    }

    private static func isPlausibleFramePointer(_ framePointer: UInt) -> Bool {
        framePointer >= 4096 && framePointer % UInt(MemoryLayout<UInt>.alignment) == 0
    }

    private static func normalizedInstructionPointer(_ address: UInt) -> UInt {
        #if arch(arm64)
        return address & 0x0000_000F_FFFF_FFFF
        #else
        return address
        #endif
    }

    private struct StackFrameRecord {
        var previousFramePointer: UInt = 0
        var returnAddress: UInt = 0
    }
}
