@file:UseSerializers(IsoInstantSerializer::class)

package io.github.codebymini.aidreport

import kotlinx.datetime.TimeZone
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlin.math.max
import kotlin.time.Instant

/**
 * Display unit for glucose. Every value inside the library is mg/dL; conversion happens only at
 * the edges (adapters and renderers).
 */
@Serializable
public enum class GlucoseUnit(public val rawValue: String) {
    @SerialName("mg/dL") MGDL("mg/dL"),
    @SerialName("mmol/L") MMOLL("mmol/L");

    public fun fromMgdL(value: Double): Double = if (this == MGDL) value else value / MGDL_PER_MMOLL

    public fun toMgdL(value: Double): Double = if (this == MGDL) value else value * MGDL_PER_MMOLL

    /** Formats an mg/dL value in this unit: whole numbers for mg/dL, one decimal for mmol/L. */
    public fun format(mgdL: Double, includeUnit: Boolean = false): String {
        val converted = fromMgdL(mgdL)
        val number = if (this == MGDL) fixed(converted, 0) else fixed(converted, 1)
        return if (includeUnit) "$number $rawValue" else number
    }

    public companion object {
        /**
         * mg/dL per mmol/L, from the molar mass of glucose HealthKit uses (180.15588 g/mol), so
         * values convert exactly as in Loop. Trio (× 0.0555) and LoopFollow agree to the printed decimal.
         */
        public const val MGDL_PER_MMOLL: Double = 18.015588
    }
}

/** A single glucose value, normalized to mg/dL. */
@Serializable
public data class GlucoseReading(
    val date: Instant,
    val mgdL: Double,
    val kind: Kind = Kind.SENSOR,
    /**
     * Stable identifier from the host (sync identifier, database id, Nightscout `_id`). Used for
     * de-duplication; `null` falls back to timestamp + value matching.
     */
    @SerialName("sourceID") val sourceId: String? = null,
) {
    public constructor(date: Instant, value: Double, unit: GlucoseUnit, kind: Kind = Kind.SENSOR, sourceId: String? = null) :
        this(date, unit.toMgdL(value), kind, sourceId)

    @Serializable
    public enum class Kind {
        /** CGM reading. The only kind that counts toward glucose statistics. */
        @SerialName("sensor") SENSOR,

        /** Meter or manually entered value. */
        @SerialName("fingerstick") FINGERSTICK,

        /** Calibration or display-only value. */
        @SerialName("calibration") CALIBRATION,
    }
}

/**
 * Insulin delivered over `[start, end]`. Boluses usually have `start == end`.
 *
 * [units] is always the absolute amount delivered (never "net of scheduled basal"), so summing
 * [units] over an interval gives total insulin.
 */
@Serializable
public data class InsulinDose(
    val kind: Kind,
    val start: Instant,
    val end: Instant,
    val units: Double,
    /** Issued by the algorithm (SMB, automatic bolus, loop-set temp basal) rather than the user. */
    val isAutomatic: Boolean = false,
    /** Logged but not delivered by the pump (pen, inhaled insulin, "External Insulin"). */
    val isExternal: Boolean = false,
    @SerialName("sourceID") val sourceId: String? = null,
) {
    @Serializable
    public enum class Kind {
        @SerialName("bolus") BOLUS,

        /** Scheduled basal from the profile. */
        @SerialName("basal") BASAL,

        /** Temporary basal set by the loop or the user. */
        @SerialName("tempBasal") TEMP_BASAL,

        /** Delivery suspended. `units` is 0. */
        @SerialName("suspend") SUSPEND,
    }

    /** Seconds. */
    val duration: Double get() = end.secondsSince(start)

    val isBasalLike: Boolean get() = kind != Kind.BOLUS

    /** Units per hour, or `null` for zero-length doses. */
    val ratePerHour: Double? get() = if (duration > 0) units / (duration / 3600) else null

    /**
     * The part of this dose inside [interval] (half-open), with units prorated linearly. Boluses
     * and zero-length doses are kept whole if they start inside the interval.
     */
    public fun clamped(interval: DateInterval): InsulinDose? {
        if (kind == Kind.BOLUS || duration <= 0) {
            return if (interval.containsHalfOpen(start)) this else null
        }
        val newStart = maxOf(start, interval.start)
        val newEnd = minOf(end, interval.end)
        if (newEnd <= newStart) return null
        return copy(units = units * newEnd.secondsSince(newStart) / duration, start = newStart, end = newEnd)
    }

    /** This dose cut short at [date], units prorated. No-op for boluses or if [date] is past the end. */
    public fun ending(date: Instant): InsulinDose {
        if (!isBasalLike || date >= end) return this
        val newEnd = maxOf(start, date)
        return copy(units = if (duration > 0) units * newEnd.secondsSince(start) / duration else 0.0, end = newEnd)
    }

    public companion object {
        public fun bolus(
            date: Instant,
            units: Double,
            isAutomatic: Boolean = false,
            isExternal: Boolean = false,
            sourceId: String? = null,
        ): InsulinDose = InsulinDose(Kind.BOLUS, date, date, units, isAutomatic, isExternal, sourceId)

        /** A basal-like dose from a rate; `units` = rate × hours. */
        public fun basal(
            kind: Kind = Kind.TEMP_BASAL,
            start: Instant,
            end: Instant,
            ratePerHour: Double,
            isAutomatic: Boolean = true,
            sourceId: String? = null,
        ): InsulinDose {
            val hours = max(0.0, end.secondsSince(start)) / 3600
            return InsulinDose(kind, start, end, ratePerHour * hours, isAutomatic, sourceId = sourceId)
        }
    }
}

@Serializable
public data class CarbIntake(
    val date: Instant,
    val grams: Double,
    /** Seconds. */
    val absorptionTime: Double? = null,
    val fatGrams: Double? = null,
    val proteinGrams: Double? = null,
    /**
     * Carb equivalents generated from fat/protein (Trio "FPU" entries). Reported separately and
     * excluded from carb totals so they are not counted twice.
     */
    val isFatProteinEquivalent: Boolean = false,
    @SerialName("sourceID") val sourceId: String? = null,
)

@Serializable
public enum class HostApp(public val defaultName: String) {
    @SerialName("loop") LOOP("Loop"),
    @SerialName("trio") TRIO("Trio"),
    @SerialName("loopFollow") LOOP_FOLLOW("LoopFollow"),
    @SerialName("androidAPS") ANDROID_APS("AndroidAPS"),
    @SerialName("nightscout") NIGHTSCOUT("Nightscout"),
    @SerialName("appleHealth") APPLE_HEALTH("Apple Health"),
    @SerialName("merged") MERGED("Merged sources"),
    @SerialName("synthetic") SYNTHETIC("Synthetic data"),
    @SerialName("other") OTHER("Other"),
}

@Serializable
public data class DataSourceInfo(
    val app: HostApp,
    /** Human-readable label shown in reports, e.g. "Trio" or "Nightscout + Apple Health". */
    val name: String = app.defaultName,
    val appVersion: String? = null,
    /** Unit the user sees in the host app; used by renderers only. */
    val displayUnit: GlucoseUnit = GlucoseUnit.MGDL,
    /** Time zone for daily buckets and time-of-day (AGP) statistics. */
    val timeZoneIdentifier: String = TimeZone.currentSystemDefault().id,
) {
    public constructor(
        app: HostApp,
        name: String? = null,
        appVersion: String? = null,
        displayUnit: GlucoseUnit = GlucoseUnit.MGDL,
        timeZone: TimeZone,
    ) : this(app, name ?: app.defaultName, appVersion, displayUnit, timeZone.id)

    val timeZone: TimeZone get() = zoneNamed(timeZoneIdentifier)
}

/**
 * Everything a report is built from: one interval of glucose, insulin and carbs.
 *
 * Creating one sorts each list by time. A dataset decoded from JSON keeps the order it was
 * written in, as in Swift; the steps that need time order sort for themselves.
 */
@ConsistentCopyVisibility
@Serializable
public data class TherapyDataset private constructor(
    val interval: DateInterval,
    val source: DataSourceInfo,
    val glucose: List<GlucoseReading>,
    val insulin: List<InsulinDose>,
    val carbs: List<CarbIntake>,
) {
    /** Keeps only data inside [interval] (half-open). Basal doses crossing the edges are prorated. */
    public fun restricted(interval: DateInterval): TherapyDataset = Companion(
        interval = interval,
        source = source,
        glucose = glucose.filter { interval.containsHalfOpen(it.date) },
        insulin = insulin.mapNotNull { it.clamped(interval) },
        carbs = carbs.filter { interval.containsHalfOpen(it.date) },
    )

    val isEmpty: Boolean get() = glucose.isEmpty() && insulin.isEmpty() && carbs.isEmpty()

    public companion object {
        public operator fun invoke(
            interval: DateInterval,
            source: DataSourceInfo,
            glucose: List<GlucoseReading> = emptyList(),
            insulin: List<InsulinDose> = emptyList(),
            carbs: List<CarbIntake> = emptyList(),
        ): TherapyDataset = TherapyDataset(
            interval,
            source,
            glucose.sortedBy { it.date },
            insulin.sortedBy { it.start },
            carbs.sortedBy { it.date },
        )
    }
}
