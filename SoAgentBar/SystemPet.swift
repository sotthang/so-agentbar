import Foundation

// MARK: - SystemPetKind

enum SystemPetKind: Hashable {
    case cpu
    case memory
}

// MARK: - SystemPetZone

enum SystemPetZone: Hashable {
    case rest
    case work
    case meeting
}

// MARK: - SystemPet

struct SystemPet: Equatable {
    let kind: SystemPetKind
    var metricValue: Double
    let spriteIndex: Int

    // D5: CPU pet spriteIndex = 0, Memory pet = 1 (SPEC Parameters / D5)
    static let cpuSpriteIndex: Int = 0
    static let memorySpriteIndex: Int = 1

    /// 배지 라벨 (R11)
    var badgeLabel: String {
        switch kind {
        case .cpu:    return "CPU"
        case .memory: return "MEM"
        }
    }
}
