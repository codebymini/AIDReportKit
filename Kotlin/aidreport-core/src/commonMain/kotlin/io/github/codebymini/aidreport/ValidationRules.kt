package io.github.codebymini.aidreport

import io.github.codebymini.aidreport.ValidationIssue.Severity
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.time.Instant

// MARK: - Glucose

public object GlucoseValueRule : ValidationRule {
    override fun validate(dataset: TherapyDataset, configuration: ValidationConfiguration, now: Instant): List<ValidationIssue> {
        val c = configuration
        val issues = dataset.glucose
            .filter { it.mgdL < c.minimumPlausibleGlucose || it.mgdL > c.maximumPlausibleGlucose }
            .map { ValidationIssue(ValidationCode.glucoseImplausibleValue, Severity.ERROR, Text.implausibleGlucose(it.mgdL), it.date, it.sourceId) }
            .toMutableList()
        val sensor = dataset.glucose.filter { it.kind == GlucoseReading.Kind.SENSOR }.map { it.mgdL }.sorted()
        if (sensor.size >= 3 && Quantile.value(0.5, sensor) < 30) {
            issues += ValidationIssue(ValidationCode.glucoseLikelyMmolL, Severity.ERROR, Text.likelyMmolL)
        }
        return issues
    }
}

public object GlucoseDuplicateRule : ValidationRule {
    override fun validate(dataset: TherapyDataset, configuration: ValidationConfiguration, now: Instant): List<ValidationIssue> =
        Dedupe.glucose(dataset.glucose, configuration.duplicateWindow).duplicates.map {
            ValidationIssue(ValidationCode.glucoseDuplicate, Severity.WARNING, Text.duplicateGlucose, it.date, it.sourceId)
        }
}

public object GlucoseContinuityRule : ValidationRule {
    override fun validate(dataset: TherapyDataset, configuration: ValidationConfiguration, now: Instant): List<ValidationIssue> {
        val c = configuration
        // In time order: a dataset that was decoded or edited after it was made may not be.
        val sensor = dataset.glucose
            .filter { it.kind == GlucoseReading.Kind.SENSOR && dataset.interval.containsHalfOpen(it.date) }
            .sortedBy { it.date }
        val first = sensor.firstOrNull()
        val last = sensor.lastOrNull()
        if (first == null || last == null) {
            return listOf(ValidationIssue(ValidationCode.glucoseNoData, Severity.WARNING, Text.noSensorGlucose))
        }

        val issues = mutableListOf<ValidationIssue>()
        for ((previous, current) in sensor.zipWithNext()) {
            val gap = current.date.secondsSince(previous.date)
            if (gap > c.maximumGlucoseGap) {
                issues += ValidationIssue(ValidationCode.glucoseGap, Severity.INFO, Text.sensorGap(gap), previous.date)
            } else if (gap >= 60) {
                val rate = abs(current.mgdL - previous.mgdL) / (gap / 60)
                if (rate > c.maximumGlucoseRateOfChange) {
                    issues += ValidationIssue(ValidationCode.glucoseRateOfChange, Severity.WARNING, Text.rateOfChange(rate), current.date, current.sourceId)
                }
            }
        }

        val leading = first.date.secondsSince(dataset.interval.start)
        if (leading > c.maximumGlucoseGap) {
            issues += ValidationIssue(ValidationCode.glucoseGap, Severity.INFO, Text.noSensorDataFirst(leading), dataset.interval.start)
        }
        val trailing = minOf(dataset.interval.end, now).secondsSince(last.date)
        if (trailing > c.maximumGlucoseGap) {
            issues += ValidationIssue(ValidationCode.glucoseGap, Severity.INFO, Text.noSensorDataLast(trailing), last.date)
        }

        val effective = DateInterval(dataset.interval.start, maxOf(dataset.interval.start, minOf(dataset.interval.end, now)))
        val coverage = GlucoseStatistics.coverage(sensor.map { it.date }, effective)
        if (coverage < c.minimumGlucoseCoverage) {
            issues += ValidationIssue(ValidationCode.glucoseLowCoverage, Severity.WARNING, Text.lowCoverage(coverage, c.minimumGlucoseCoverage))
        }
        return issues
    }
}

// MARK: - Insulin

public object InsulinValueRule : ValidationRule {
    override fun validate(dataset: TherapyDataset, configuration: ValidationConfiguration, now: Instant): List<ValidationIssue> {
        val c = configuration
        return dataset.insulin.mapNotNull { dose ->
            val rate = dose.ratePerHour
            when {
                dose.units < 0 ->
                    ValidationIssue(ValidationCode.insulinNegative, Severity.ERROR, Text.negativeInsulin(dose.units), dose.start, dose.sourceId)
                dose.end < dose.start ->
                    ValidationIssue(ValidationCode.insulinEndBeforeStart, Severity.ERROR, Text.endBeforeStart, dose.start, dose.sourceId)
                dose.kind == InsulinDose.Kind.BOLUS && dose.units > c.maximumBolus ->
                    ValidationIssue(ValidationCode.insulinBolusAboveMax, Severity.WARNING, Text.bolusAboveMax(dose.units, c.maximumBolus), dose.start, dose.sourceId)
                dose.isBasalLike && dose.duration >= 60 && rate != null && rate > c.maximumBasalRate ->
                    ValidationIssue(ValidationCode.insulinBasalRateAboveMax, Severity.WARNING, Text.basalAboveMax(rate, c.maximumBasalRate), dose.start, dose.sourceId)
                else -> null
            }
        }
    }
}

public object InsulinConsistencyRule : ValidationRule {
    override fun validate(dataset: TherapyDataset, configuration: ValidationConfiguration, now: Instant): List<ValidationIssue> {
        val c = configuration
        if (dataset.insulin.isEmpty()) {
            return listOf(ValidationIssue(ValidationCode.insulinNoData, Severity.WARNING, Text.noInsulin))
        }

        val issues = Dedupe.boluses(dataset.insulin.filter { it.kind == InsulinDose.Kind.BOLUS }, c.duplicateWindow).duplicates.map {
            ValidationIssue(ValidationCode.insulinDuplicateBolus, Severity.WARNING, Text.duplicateBolus(it.units), it.start, it.sourceId)
        }.toMutableList()

        val basal = dataset.insulin.filter { it.isBasalLike }.sortedBy { it.start }
        for ((current, next) in basal.zipWithNext()) {
            if (next.start.secondsSince(current.end) < -1) {
                issues += ValidationIssue(
                    ValidationCode.insulinBasalOverlap, Severity.WARNING,
                    Text.basalOverlap(current.end.secondsSince(next.start)), next.start, next.sourceId,
                )
            }
        }

        val effective = DateInterval(dataset.interval.start, maxOf(dataset.interval.start, minOf(dataset.interval.end, now)))
        val coverage = BasalTimeline.coverage(dataset.insulin, effective)
        if (coverage < c.minimumBasalCoverage) {
            issues += ValidationIssue(ValidationCode.insulinLowBasalCoverage, Severity.WARNING, Text.lowBasalCoverage(coverage))
        }
        return issues
    }
}

// MARK: - Carbs

public object CarbRule : ValidationRule {
    override fun validate(dataset: TherapyDataset, configuration: ValidationConfiguration, now: Instant): List<ValidationIssue> {
        val c = configuration
        val issues = dataset.carbs.mapNotNull { entry ->
            when {
                entry.grams < 0 ->
                    ValidationIssue(ValidationCode.carbsNegative, Severity.ERROR, Text.negativeCarbs(entry.grams), entry.date, entry.sourceId)
                entry.grams > c.maximumCarbEntry ->
                    ValidationIssue(ValidationCode.carbsAboveMax, Severity.WARNING, Text.carbsAboveMax(entry.grams, c.maximumCarbEntry), entry.date, entry.sourceId)
                else -> null
            }
        }
        return issues + Dedupe.carbs(dataset.carbs, c.duplicateWindow).duplicates.map {
            ValidationIssue(ValidationCode.carbsDuplicate, Severity.WARNING, Text.duplicateCarbs(it.grams), it.date, it.sourceId)
        }
    }
}

// MARK: - Dataset

public object DatasetTimingRule : ValidationRule {
    override fun validate(dataset: TherapyDataset, configuration: ValidationConfiguration, now: Instant): List<ValidationIssue> {
        val c = configuration
        val latest = now.plusSeconds(c.futureTolerance)
        val future = dataset.glucose.filter { it.date > latest }.map { it.date to it.sourceId } +
            dataset.insulin.filter { it.start > latest }.map { it.start to it.sourceId } +
            dataset.carbs.filter { it.date > latest }.map { it.date to it.sourceId }
        val issues = future.map { (date, sourceId) ->
            ValidationIssue(ValidationCode.datasetFutureTimestamp, Severity.ERROR, Text.futureRecord, date, sourceId)
        }.toMutableList()
        if (dataset.interval.duration < c.recommendedSpan) {
            issues += ValidationIssue(ValidationCode.datasetShortSpan, Severity.INFO, Text.shortSpan(dataset.interval.duration, c.recommendedSpan))
        }
        return issues
    }
}

/**
 * The validation messages, in English. Swift reads the same sentences from its String Catalog;
 * numbers are formatted before they go in, so a translation only has to reorder them.
 */
internal object Text {
    private fun minutes(seconds: Double): String = "${(seconds / 60).roundToInt()} min"

    private fun percent(fraction: Double): String = "${fixed(fraction * 100, 0)}%"

    fun moreIssues(count: Int, code: ValidationCode): String = "$count more ${code.rawValue} issues not listed"

    fun implausibleGlucose(mgdL: Double): String = "Glucose ${fixed(mgdL, 1)} mg/dL is outside the plausible range"

    const val likelyMmolL: String = "Median sensor glucose is below 30; values look like mmol/L delivered as mg/dL"
    const val duplicateGlucose: String = "Duplicate glucose reading"
    const val noSensorGlucose: String = "No sensor glucose in the interval"

    fun sensorGap(seconds: Double): String = "Sensor gap of ${minutes(seconds)}"

    fun rateOfChange(rate: Double): String = "Glucose changed ${fixed(rate, 1)} mg/dL/min"

    fun noSensorDataFirst(seconds: Double): String = "No sensor data for the first ${minutes(seconds)}"

    fun noSensorDataLast(seconds: Double): String = "No sensor data for the last ${minutes(seconds)}"

    fun lowCoverage(coverage: Double, minimum: Double): String = "CGM coverage is ${percent(coverage)} (minimum ${percent(minimum)})"

    fun negativeInsulin(units: Double): String = "Negative insulin amount ${fixed(units, 2)} U"

    const val endBeforeStart: String = "Dose ends before it starts"

    fun bolusAboveMax(units: Double, maximum: Double): String = "Bolus of ${fixed(units, 2)} U exceeds ${fixed(maximum, 0)} U"

    fun basalAboveMax(rate: Double, maximum: Double): String = "Basal rate ${fixed(rate, 2)} U/h exceeds ${fixed(maximum, 1)} U/h"

    const val noInsulin: String = "No insulin records in the interval"

    fun duplicateBolus(units: Double): String = "Duplicate bolus of ${fixed(units, 2)} U"

    fun basalOverlap(seconds: Double): String = "Basal records overlap by ${minutes(seconds)}"

    fun lowBasalCoverage(coverage: Double): String =
        "Basal records cover ${percent(coverage)} of the interval; basal totals undercount unless a basal schedule is provided"

    fun negativeCarbs(grams: Double): String = "Negative carb entry ${fixed(grams, 0)} g"

    fun carbsAboveMax(grams: Double, maximum: Double): String = "Carb entry of ${fixed(grams, 0)} g exceeds ${fixed(maximum, 0)} g"

    fun duplicateCarbs(grams: Double): String = "Duplicate carb entry of ${fixed(grams, 0)} g"

    const val futureRecord: String = "Record is dated in the future (clock or time-zone problem)"

    fun shortSpan(duration: Double, recommended: Double): String =
        "Report covers ${fixed(duration / 86400, 1)} days; GMI and time-in-range targets assume at least ${fixed(recommended / 86400, 0)} days"
}
