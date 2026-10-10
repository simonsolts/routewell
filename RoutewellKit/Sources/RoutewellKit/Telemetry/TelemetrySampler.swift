import Foundation

public struct TelemetrySample: Sendable, Equatable {
    public let capturedAt: Date
    /// The 1-minute load average, never a CPU percentage.
    public let cpuLoad: Observed<Double>
    /// Measured CPU utilization, 0–100. No RPC reports it.
    public let cpuUtilizationPercent: Observed<Double>
    public let memoryUsedBytes: Observed<Double>
    public let memoryTotalBytes: Observed<Double>
    public let temperatureCelsius: Observed<Double>
    public let wanRxBytesPerSecond: Observed<Double>
    public let wanTxBytesPerSecond: Observed<Double>

    public init(capturedAt: Date, cpuLoad: Observed<Double> = .unknown,
                cpuUtilizationPercent: Observed<Double> = .unknown,
                memoryUsedBytes: Observed<Double> = .unknown,
                memoryTotalBytes: Observed<Double> = .unknown,
                temperatureCelsius: Observed<Double> = .unknown,
                wanRxBytesPerSecond: Observed<Double> = .unknown,
                wanTxBytesPerSecond: Observed<Double> = .unknown) {
        self.capturedAt = capturedAt
        self.cpuLoad = cpuLoad
        self.cpuUtilizationPercent = cpuUtilizationPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.temperatureCelsius = temperatureCelsius
        self.wanRxBytesPerSecond = wanRxBytesPerSecond
        self.wanTxBytesPerSecond = wanTxBytesPerSecond
    }
}

public struct MetricPoint: Sendable, Equatable {
    public let at: Date
    public let value: Double
}

public struct TelemetryHistory: Sendable, Equatable {
    public let cpuLoad: [MetricPoint]
    public let cpuUtilizationPercent: [MetricPoint]
    public let memoryUsedBytes: [MetricPoint]
    public let temperatureCelsius: [MetricPoint]
    public let wanRxBytesPerSecond: [MetricPoint]
    public let wanTxBytesPerSecond: [MetricPoint]

    public static let empty = TelemetryHistory(cpuLoad: [], cpuUtilizationPercent: [], memoryUsedBytes: [],
                                               temperatureCelsius: [], wanRxBytesPerSecond: [], wanTxBytesPerSecond: [])
}

/// Routewell's own observations since launch or the last Reset Session:
/// not continuous monitoring. A peak exists only once a reading does.
public struct TelemetrySessionSummary: Sendable, Equatable {
    public var since: Date?
    /// Successful telemetry reads.
    public var observations = 0
    public var peakCPUPercent: Double?
    public var peakMemoryFraction: Double?
    public var peakTemperatureCelsius: Double?

    public init(since: Date? = nil) { self.since = since }

    mutating func record(_ sample: TelemetrySample) {
        if since == nil { since = sample.capturedAt }
        observations += 1
        if case .value(let cpu) = sample.cpuUtilizationPercent, cpu.isFinite { peakCPUPercent = max(peakCPUPercent ?? cpu, cpu) }
        if case .value(let used) = sample.memoryUsedBytes, case .value(let total) = sample.memoryTotalBytes, total > 0, used.isFinite {
            let fraction = used / total
            peakMemoryFraction = max(peakMemoryFraction ?? fraction, fraction)
        }
        if case .value(let degrees) = sample.temperatureCelsius, degrees.isFinite {
            peakTemperatureCelsius = max(peakTemperatureCelsius ?? degrees, degrees)
        }
    }
}

public actor TelemetrySampler {
    private let overviewLimit: Int
    private let throughputLimit: Int
    private var cpu: [MetricPoint] = []
    private var cpuPercent: [MetricPoint] = []
    private var memory: [MetricPoint] = []
    private var temperature: [MetricPoint] = []
    private var rx: [MetricPoint] = []
    private var tx: [MetricPoint] = []
    private var summary = TelemetrySessionSummary()

    public init(overviewLimit: Int = 120, throughputLimit: Int = 300) {
        self.overviewLimit = max(1, overviewLimit)
        self.throughputLimit = max(1, throughputLimit)
    }

    public func append(_ sample: TelemetrySample) -> TelemetryHistory {
        Self.push(sample.cpuLoad, at: sample.capturedAt, into: &cpu, limit: overviewLimit)
        Self.push(sample.cpuUtilizationPercent, at: sample.capturedAt, into: &cpuPercent, limit: overviewLimit)
        Self.push(sample.memoryUsedBytes, at: sample.capturedAt, into: &memory, limit: overviewLimit)
        Self.push(sample.temperatureCelsius, at: sample.capturedAt, into: &temperature, limit: overviewLimit)
        Self.push(sample.wanRxBytesPerSecond, at: sample.capturedAt, into: &rx, limit: throughputLimit)
        Self.push(sample.wanTxBytesPerSecond, at: sample.capturedAt, into: &tx, limit: throughputLimit)
        summary.record(sample)
        return history()
    }

    public func history() -> TelemetryHistory {
        TelemetryHistory(cpuLoad: cpu, cpuUtilizationPercent: cpuPercent, memoryUsedBytes: memory, temperatureCelsius: temperature,
                         wanRxBytesPerSecond: rx, wanTxBytesPerSecond: tx)
    }

    public func session() -> TelemetrySessionSummary { summary }

    /// Reset Session…: peaks and the observation count start again. The
    /// rings keep their history.
    public func resetSession(at date: Date) -> TelemetrySessionSummary {
        summary = TelemetrySessionSummary(since: date)
        return summary
    }

    public func clear() {
        cpu.removeAll(); cpuPercent.removeAll(); memory.removeAll(); temperature.removeAll(); rx.removeAll(); tx.removeAll()
        summary = TelemetrySessionSummary()
    }

    private static func push(_ observed: Observed<Double>, at: Date, into ring: inout [MetricPoint], limit: Int) {
        guard case .value(let value) = observed, value.isFinite else { return }
        ring.append(MetricPoint(at: at, value: value))
        if ring.count > limit { ring.removeFirst(ring.count - limit) }
    }
}
