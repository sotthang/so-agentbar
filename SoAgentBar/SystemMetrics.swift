import Foundation
import Darwin

// MARK: - 모델

/// 5초마다 샘플링되는 시스템 지표.
struct SystemMetrics: Equatable {
    /// 0...100
    let cpuPercent: Double
    /// 0...100
    let memoryPercent: Double
    /// 0...100 (홈 볼륨)
    let diskPercent: Double
    /// 홈 볼륨의 여유 공간 (GB, 표시용)
    let diskFreeGB: Double
}

// MARK: - Provider 프로토콜

/// 테스트에서 fake 주입이 가능하도록 추상화.
protocol SystemMetricsProvider: AnyObject {
    /// 현재 샘플. 첫 호출에서 CPU 값은 0일 수 있다 (tick diff 미존재).
    func sample() -> SystemMetrics
}

// MARK: - HostSystemMetricsProvider

/// host_statistics64 + URLResourceKey 기반 실제 macOS 구현.
final class HostSystemMetricsProvider: SystemMetricsProvider {

    /// 0~100 범위로 클램프.
    private static func clampPercent(_ value: Double) -> Double {
        min(100.0, max(0.0, value))
    }

    private var previousCPUTicks: host_cpu_load_info_data_t?

    init() {}

    func sample() -> SystemMetrics {
        let cpu = sampleCPU()
        let memory = sampleMemory()
        let (diskPercent, diskFreeGB) = sampleDisk()
        return SystemMetrics(
            cpuPercent: cpu,
            memoryPercent: memory,
            diskPercent: diskPercent,
            diskFreeGB: diskFreeGB
        )
    }

    // MARK: - CPU

    private func sampleCPU() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var cpuLoadInfo = host_cpu_load_info_data_t()

        let result = withUnsafeMutablePointer(to: &cpuLoadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            previousCPUTicks = nil
            return 0.0
        }

        defer { previousCPUTicks = cpuLoadInfo }

        guard let prev = previousCPUTicks else {
            // 첫 샘플: 기준 tick 저장, CPU=0 반환
            return 0.0
        }

        let userDiff   = Double(cpuLoadInfo.cpu_ticks.0) - Double(prev.cpu_ticks.0)
        let systemDiff = Double(cpuLoadInfo.cpu_ticks.1) - Double(prev.cpu_ticks.1)
        let idleDiff   = Double(cpuLoadInfo.cpu_ticks.2) - Double(prev.cpu_ticks.2)
        let niceDiff   = Double(cpuLoadInfo.cpu_ticks.3) - Double(prev.cpu_ticks.3)

        let total = userDiff + systemDiff + idleDiff + niceDiff
        guard total > 0 else { return 0.0 }

        let used = userDiff + systemDiff + niceDiff
        return Self.clampPercent((used / total) * 100.0)
    }

    // MARK: - Memory

    private func sampleMemory() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64_data_t()

        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0.0 }

        // 물리적 메모리 총량 (hw.memsize)
        var physicalRAM: UInt64 = 0
        var ramSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &physicalRAM, &ramSize, nil, 0)
        guard physicalRAM > 0 else { return 0.0 }

        // 활성상태보기 "사용된 메모리" = App Memory + Wired + Compressed
        // App Memory = internal_page_count (앱이 사용하는 익명 메모리, file-backed 제외)
        // external_page_count = Cached Files → 사용된 메모리에 미포함
        let pageSize   = Double(vm_page_size)
        let appMemory  = Double(vmStats.internal_page_count)   * pageSize
        let wired      = Double(vmStats.wire_count)            * pageSize
        let compressed = Double(vmStats.compressor_page_count) * pageSize

        let used  = appMemory + wired + compressed
        let total = Double(physicalRAM)
        guard total > 0 else { return 0.0 }

        return Self.clampPercent((used / total) * 100.0)
    }

    // MARK: - Disk

    private func sampleDisk() -> (percent: Double, freeGB: Double) {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]

        guard let values = try? homeURL.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage,
              total > 0
        else {
            return (0.0, 0.0)
        }

        let totalD     = Double(total)
        let availableD = Double(available)
        let usedD      = totalD - availableD
        let percent    = Self.clampPercent((usedD / totalD) * 100.0)
        let bytesPerGB: Double = 1_073_741_824
        let freeGB     = availableD / bytesPerGB

        return (percent, freeGB)
    }
}
