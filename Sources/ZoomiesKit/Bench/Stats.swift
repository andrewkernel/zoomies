import Foundation

/// Descriptive statistics with a 95% confidence interval for the mean.
public struct Summary: Codable, Sendable, Equatable {
    public var n: Int
    public var mean: Double
    public var stddev: Double
    public var median: Double
    public var min: Double
    public var max: Double
    public var ciLow: Double
    public var ciHigh: Double

    /// Coefficient of variation in percent.
    public var cvPercent: Double { mean != 0 ? 100 * stddev / mean : 0 }
    /// Half-width of the CI relative to the mean, in percent.
    public var ciHalfWidthPercent: Double { mean != 0 ? 100 * (ciHigh - ciLow) / 2 / mean : 0 }
}

public enum Stats {
    public static func mean(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count) }

    /// Sample standard deviation (n - 1).
    public static func stddev(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = mean(x)
        return (x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count - 1)).squareRoot()
    }

    public static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Median absolute deviation (unscaled).
    public static func mad(_ x: [Double]) -> Double {
        let m = median(x)
        return median(x.map { abs($0 - m) })
    }

    /// Indices of outliers by modified z-score (Iglewicz & Hoaglin): |0.6745 (x - median) / MAD| > 3.5.
    /// Outliers are reported, never silently dropped.
    public static func outlierIndices(_ x: [Double], threshold: Double = 3.5) -> [Int] {
        guard x.count >= 3 else { return [] }
        let m = median(x)
        let d = mad(x)
        guard d > 0 else { return [] }
        return x.indices.filter { abs(0.6745 * (x[$0] - m) / d) > threshold }
    }

    /// Two-sided 95% Student-t critical value. Non-integer df are rounded down
    /// (conservative); between tabulated rows the smaller df's value is used.
    public static func t95(df: Double) -> Double {
        let table: [Double] = [12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
                               2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
                               2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042]
        let k = Int(df.rounded(.down))
        if k < 1 { return .infinity }
        if k <= 30 { return table[k - 1] }
        if k < 40 { return 2.042 }
        if k < 60 { return 2.021 }
        if k < 120 { return 2.000 }
        return 1.980
    }

    public static func summarize(_ x: [Double]) -> Summary {
        let n = x.count
        let m = mean(x)
        let s = stddev(x)
        let half = n > 1 ? t95(df: Double(n - 1)) * s / Double(n).squareRoot() : .infinity
        return Summary(n: n, mean: m, stddev: s, median: median(x), min: x.min() ?? 0, max: x.max() ?? 0,
                       ciLow: n > 1 ? m - half : -.infinity, ciHigh: n > 1 ? m + half : .infinity)
    }
}

/// Difference between a candidate and a baseline, B - A, with a Welch 95% CI.
public struct Comparison: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable {
        case faster, slower, noDetectableDifference = "no_detectable_difference", insufficientData = "insufficient_data"
    }

    public var baselineMean: Double
    public var candidateMean: Double
    public var difference: Double
    public var ciLow: Double
    public var ciHigh: Double
    public var degreesOfFreedom: Double
    public var verdict: Verdict

    public var relativePercent: Double { baselineMean != 0 ? 100 * difference / baselineMean : 0 }
    public var relativeCILowPercent: Double { baselineMean != 0 ? 100 * ciLow / baselineMean : 0 }
    public var relativeCIHighPercent: Double { baselineMean != 0 ? 100 * ciHigh / baselineMean : 0 }

    /// A candidate is "faster" only if the whole CI is above zero AND the
    /// gain is at least `minRelevant` (relative). A real but tiny gain is not
    /// worth changing settings for, so it also counts as no difference.
    public static func welch(baseline a: [Double], candidate b: [Double], minRelevant: Double = 0.02) -> Comparison {
        let ma = Stats.mean(a), mb = Stats.mean(b)
        guard a.count >= 2, b.count >= 2 else {
            return Comparison(baselineMean: ma, candidateMean: mb, difference: mb - ma, ciLow: -.infinity,
                              ciHigh: .infinity, degreesOfFreedom: 0, verdict: .insufficientData)
        }
        let va = pow(Stats.stddev(a), 2) / Double(a.count)
        let vb = pow(Stats.stddev(b), 2) / Double(b.count)
        let se = (va + vb).squareRoot()
        let df: Double
        if se == 0 {
            df = Double(a.count + b.count - 2)
        } else {
            df = pow(va + vb, 2) / (pow(va, 2) / Double(a.count - 1) + pow(vb, 2) / Double(b.count - 1))
        }
        let half = Stats.t95(df: df) * se
        let d = mb - ma
        let lo = d - half, hi = d + half
        let threshold = minRelevant * abs(ma)
        let verdict: Verdict = if lo > 0 && d >= threshold { .faster }
            else if hi < 0 && -d >= threshold { .slower }
            else { .noDetectableDifference }
        return Comparison(baselineMean: ma, candidateMean: mb, difference: d, ciLow: lo, ciHigh: hi,
                          degreesOfFreedom: df, verdict: verdict)
    }

    /// Paired comparison from per-round ratios candidate/baseline (> 1 means the
    /// candidate is better), measured in the same rounds. Pairing cancels drift
    /// that hits both configs in a round, so it is more sensitive than Welch.
    /// Computed on log-ratios; reported as relative change against a baseline of 1.
    public static func pairedRatio(_ ratios: [Double], minRelevant: Double = 0.02) -> Comparison {
        let logs = ratios.filter { $0 > 0 && $0.isFinite }.map { Foundation.log($0) }
        let m = Stats.mean(logs)
        guard logs.count >= 2 else {
            return Comparison(baselineMean: 1, candidateMean: exp(m), difference: exp(m) - 1, ciLow: -.infinity,
                              ciHigh: .infinity, degreesOfFreedom: 0, verdict: .insufficientData)
        }
        let df = Double(logs.count - 1)
        let half = Stats.t95(df: df) * Stats.stddev(logs) / Double(logs.count).squareRoot()
        let d = exp(m) - 1, lo = exp(m - half) - 1, hi = exp(m + half) - 1
        let verdict: Verdict = if lo > 0 && d >= minRelevant { .faster }
            else if hi < 0 && -d >= minRelevant { .slower }
            else { .noDetectableDifference }
        return Comparison(baselineMean: 1, candidateMean: exp(m), difference: d, ciLow: lo, ciHigh: hi,
                          degreesOfFreedom: df, verdict: verdict)
    }
}
