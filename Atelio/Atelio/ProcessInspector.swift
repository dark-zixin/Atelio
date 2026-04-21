import Foundation
import Darwin

/// 透過 sysctl KERN_PROCARGS2 拿 process 的啟動 argv。
/// 用於 foreground process 的動態白名單判斷（比 proc_name 更 robust）。
enum ProcessInspector {

    /// 讀取指定 pid 的 argv 陣列。失敗時回傳 nil。
    ///
    /// Buffer layout（KERN_PROCARGS2）：
    ///   [argc: Int32][exec_path\0][padding \0…][argv[0]\0][argv[1]\0]…[envp…]
    static func argv(for pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size: Int = 0

        // 先查 buffer 大小
        if sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size == 0 {
            return nil
        }

        // 讀內容
        var buf = [CChar](repeating: 0, count: size)
        if sysctl(&mib, 3, &buf, &size, nil, 0) != 0 {
            return nil
        }

        // Parse: 前 4 bytes 是 argc（Int32 host byte order）
        guard size >= MemoryLayout<Int32>.size else { return nil }
        let argc: Int = buf.withUnsafeBufferPointer { ptr -> Int in
            var value: Int32 = 0
            memcpy(&value, ptr.baseAddress, MemoryLayout<Int32>.size)
            return Int(value)
        }
        guard argc > 0, argc < 4096 else { return nil }

        var offset = MemoryLayout<Int32>.size

        // 跳過 exec_path（到第一個 \0）
        while offset < size, buf[offset] != 0 { offset += 1 }
        // 跳過 exec_path 的 terminator + 後續 padding \0
        while offset < size, buf[offset] == 0 { offset += 1 }

        // 讀 argc 個 argv
        var result: [String] = []
        result.reserveCapacity(argc)
        for _ in 0..<argc {
            guard offset < size else { break }
            let start = offset
            while offset < size, buf[offset] != 0 { offset += 1 }
            let length = offset - start
            if length > 0 {
                let bytes = buf[start..<offset].map { UInt8(bitPattern: $0) }
                result.append(String(decoding: bytes, as: UTF8.self))
            } else {
                result.append("")
            }
            offset += 1  // skip the null terminator
        }

        return result
    }
}
