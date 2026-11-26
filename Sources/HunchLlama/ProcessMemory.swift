// Process memory figures for measurements (eval harness, tests). Read-only Mach query.
import Darwin

public enum ProcessMemory {
    public struct Snapshot: Sendable, Equatable {
        /// `phys_footprint`: what Activity Monitor's Memory column shows.
        public var physFootprint: UInt64
        /// `resident_size`: pages currently resident, including clean file-backed (mmap) pages.
        public var residentSize: UInt64
    }

    public static func snapshot() -> Snapshot? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Snapshot(physFootprint: info.phys_footprint, residentSize: info.resident_size)
    }
}
