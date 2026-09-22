import Foundation

public struct TelemetrySample: Sendable, Equatable {
    public let capturedAt: Date
    public let cpuLoad: Observed<Double>
    public let memoryUsedBytes: Observed<Double>
    public let temperatureCelsius: Observed<Double>
    public let wanRxBytesPerSecond: Observed<Double>
    public let wanTxBytesPerSecond: Observed<Double>

    public init(capturedAt: Date, cpuLoad: Observed<Double> = .unknown,
                memoryUsedBytes: Observed<Double> = .unknown,
                temperatureCelsius: Observed<Double> = .unknown,
                wanRxBytesPerSecond: Observed<Double> = .unknown,
                wanTxBytesPerSecond: Observed<Double> = .unknown) {
        self.capturedAt = capturedAt
        self.cpuLoad = cpuLoad
        self.memoryUsedBytes = memoryUsedBytes
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
    public let memoryUsedBytes: [MetricPoint]
    public let temperatureCelsius: [MetricPoint]
    public let wanRxBytesPerSecond: [MetricPoint]
    public let wanTxBytesPerSecond: [MetricPoint]
}

public actor TelemetrySampler {
    private let overviewLimit: Int
    private let throughputLimit: Int
    private var cpu: [MetricPoint] = []
    private var memory: [MetricPoint] = []
    private var temperature: [MetricPoint] = []
    private var rx: [MetricPoint] = []
    private var tx: [MetricPoint] = []

    public init(overviewLimit: Int = 120, throughputLimit: Int = 300) {
        self.overviewLimit = max(1, overviewLimit)
        self.throughputLimit = max(1, throughputLimit)
    }

    public func append(_ sample: TelemetrySample) -> TelemetryHistory {
        Self.push(sample.cpuLoad, at: sample.capturedAt, into: &cpu, limit: overviewLimit)
        Self.push(sample.memoryUsedBytes, at: sample.capturedAt, into: &memory, limit: overviewLimit)
        Self.push(sample.temperatureCelsius, at: sample.capturedAt, into: &temperature, limit: overviewLimit)
        Self.push(sample.wanRxBytesPerSecond, at: sample.capturedAt, into: &rx, limit: throughputLimit)
        Self.push(sample.wanTxBytesPerSecond, at: sample.capturedAt, into: &tx, limit: throughputLimit)
        return history()
    }

    public func history() -> TelemetryHistory {
        TelemetryHistory(cpuLoad: cpu, memoryUsedBytes: memory, temperatureCelsius: temperature,
                         wanRxBytesPerSecond: rx, wanTxBytesPerSecond: tx)
    }

    public func clear() {
        cpu.removeAll(); memory.removeAll(); temperature.removeAll(); rx.removeAll(); tx.removeAll()
    }

    private static func push(_ observed: Observed<Double>, at: Date, into ring: inout [MetricPoint], limit: Int) {
        guard case .value(let value) = observed, value.isFinite else { return }
        ring.append(MetricPoint(at: at, value: value))
        if ring.count > limit { ring.removeFirst(ring.count - limit) }
    }
}
