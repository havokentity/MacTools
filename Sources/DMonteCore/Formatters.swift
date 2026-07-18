import Foundation

public enum TemperatureUnitPreference: String, CaseIterable, Identifiable {
    case celsius
    case fahrenheit

    public var id: String { rawValue }

    var symbol: String {
        switch self {
        case .celsius: "C"
        case .fahrenheit: "F"
        }
    }

    var label: String {
        switch self {
        case .celsius: "Celsius"
        case .fahrenheit: "Fahrenheit"
        }
    }
}

extension Double {
    var percentString: String {
        let value = (self * 100).rounded()
        return "\(Int(value))%"
    }

    func temperatureString(unit: TemperatureUnitPreference) -> String {
        let value = switch unit {
        case .celsius:
            self
        case .fahrenheit:
            self * 9 / 5 + 32
        }

        return "\(String(format: "%.1f", value))°\(unit.symbol)"
    }
}

extension UInt64 {
    var bytesString: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .binary)
    }

    var diskBytesString: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .decimal)
    }

    var rateString: String {
        "\(bytesString)/s"
    }

    var compactBytesString: String {
        bytesString.replacingOccurrences(of: " ", with: "")
    }

    var compactRateString: String {
        "\(compactBytesString)/s"
    }

    var statusBytesString: String {
        let value = Double(self)
        let kib = 1_024.0
        let mib = kib * 1_024
        let gib = mib * 1_024
        let tib = gib * 1_024

        if value >= tib {
            return "\(Int(value / tib))TB"
        }

        if value >= gib {
            return "\(Int(value / gib))GB"
        }

        if value >= mib {
            return "\(Int(value / mib))MB"
        }

        if value >= kib {
            return "\(Int(value / kib))KB"
        }

        return "\(self)B"
    }

    var diskStatusBytesString: String {
        let value = Double(self)
        let kb = 1_000.0
        let mb = kb * 1_000
        let gb = mb * 1_000
        let tb = gb * 1_000

        if value >= tb {
            return "\(Int(value / tb))TB"
        }

        if value >= gb {
            return "\(Int(value / gb))GB"
        }

        if value >= mb {
            return "\(Int(value / mb))MB"
        }

        if value >= kb {
            return "\(Int(value / kb))KB"
        }

        return "\(self)B"
    }

    var statusRateString: String {
        "\(statusBytesString)/s"
    }
}

extension TimeInterval {
    var compactDurationString: String {
        let totalMinutes = Int(self / 60)
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }
}
