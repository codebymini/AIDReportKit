@file:UseSerializers(IsoInstantSerializer::class)

package io.github.codebymini.aidreport

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationStrategy
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlin.time.Clock
import kotlin.time.Instant

/**
 * The therapy settings in force when the report was made, as the app supplies them.
 *
 * Schedules repeat every day: each entry holds from its time of day until the next one, on the
 * looper's clock. Glucose values are mg/dL (the report prints them in its display unit); insulin
 * is in units. None of the apps keep a history of setting changes, so a report shows today's
 * settings next to statistics from the whole period.
 *
 * Creating one sorts the schedules by time and drops empty groups.
 */
@ConsistentCopyVisibility
@Serializable
public data class TherapySettingsSnapshot private constructor(
    /** U/h. A report fills it from [ReportOptions.basalSchedule] when it is not set here. */
    val basalSchedule: BasalSchedule? = null,
    /** Grams of carbohydrate one unit covers. */
    val carbRatios: List<Entry> = emptyList(),
    /** How far one unit lowers glucose, in mg/dL. */
    val insulinSensitivities: List<Entry> = emptyList(),
    /** Correction target ranges, in mg/dL. */
    val targets: List<TargetRange> = emptyList(),
    /** Everything else, for the Settings page. */
    val groups: List<Group> = emptyList(),
) {
    /** A value from a time of day until the next entry. */
    @Serializable
    public data class Entry(
        /** Seconds after local midnight. */
        val startOffset: Double,
        val value: Double,
    )

    /** A glucose target range from a time of day until the next entry, in mg/dL. */
    @Serializable
    public data class TargetRange(
        /** Seconds after local midnight. */
        val startOffset: Double,
        val low: Double,
        val high: Double,
    )

    /** A titled list of other settings ("Limits", "Insulin model", …), formatted by the app in its own words and units. */
    @Serializable
    public data class Group(val title: String, val items: List<ReportMetadata.Item>)

    val isEmpty: Boolean
        get() = basalSchedule == null && carbRatios.isEmpty() && insulinSensitivities.isEmpty() && targets.isEmpty() && groups.isEmpty()

    /** These settings with [schedule] as the basal schedule. */
    public fun withBasalSchedule(schedule: BasalSchedule?): TherapySettingsSnapshot = copy(basalSchedule = schedule)

    public companion object {
        public operator fun invoke(
            basalSchedule: BasalSchedule? = null,
            carbRatios: List<Entry> = emptyList(),
            insulinSensitivities: List<Entry> = emptyList(),
            targets: List<TargetRange> = emptyList(),
            groups: List<Group> = emptyList(),
        ): TherapySettingsSnapshot = TherapySettingsSnapshot(
            basalSchedule,
            carbRatios.sortedBy { it.startOffset },
            insulinSensitivities.sortedBy { it.startOffset },
            targets.sortedBy { it.startOffset },
            groups.filter { it.items.isNotEmpty() },
        )
    }
}

/** A fully computed report: what renderers (Markdown, JSON, CSV, PDF) consume. */
@Serializable
public data class TherapyReport(
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    val definition: ReportDefinition,
    val interval: DateInterval,
    val generatedAt: Instant,
    val source: DataSourceInfo,
    val metadata: ReportMetadata,
    val thresholds: GlucoseThresholds,
    val summary: TherapySummary,
    val daily: List<DailySummary>,
    val agp: AGPProfile,
    /** Time in ranges for night, morning, afternoon and evening, all days overlaid. */
    val dayPeriods: List<DayPeriodRanges>,
    /** Issues found in the raw data, before sanitizing. */
    val validation: ValidationReport,
    /** The first and last data point the statistics rest on; `null` when there is no data. */
    val dataSpan: DataSpan? = null,
    /**
     * Basal rates, carb ratios, ISF, targets and other settings in force when the report was made;
     * `null` when the app supplied none.
     */
    val settings: TherapySettingsSnapshot? = null,
) {
    val displayUnit: GlucoseUnit get() = source.displayUnit

    /**
     * The same for every report, whichever app made it and whatever preset it came from: the app
     * is named under Software in the header, and a preset's name is only for finding it again.
     */
    val title: String get() = "Glucose Report"

    /** The definition's sections in order, minus those that do not fit the interval. */
    val renderableSections: List<ReportSection>
        get() {
            val unsupported = definition.unsupportedSections(interval).toSet()
            return definition.sections.filter { it !in unsupported }
        }

    /** Whether the first calendar day of the report holds only part of a day of data. */
    val isFirstDayPartial: Boolean get() = dataSpan?.isFirstDayPartial(source.timeZone) ?: false

    /** Whether the last calendar day of the report holds only part of a day of data. */
    val isLastDayPartial: Boolean get() = dataSpan?.isLastDayPartial(source.timeZone) ?: false

    public companion object {
        /** 2: `dayPeriods` and `settings` added. */
        public const val CURRENT_SCHEMA_VERSION: Int = 2
    }
}

public data class ReportOptions(
    val thresholds: GlucoseThresholds = GlucoseThresholds.consensus,
    val validation: ValidationConfiguration = ValidationConfiguration(),
    /** Extra host-specific rules run after the standard ones. */
    val additionalRules: List<ValidationRule> = emptyList(),
    /**
     * Fills basal gaps (needed for apps and Nightscout that only record temp basals) and is the
     * programmed basal reports compare delivered basal with.
     */
    val basalSchedule: BasalSchedule? = null,
    /**
     * Carb ratios, ISF, targets and other settings printed on the Insulin and Settings pages. The
     * basal schedule above is shown with them.
     */
    val therapySettings: TherapySettingsSnapshot? = null,
    val agpBucketMinutes: Int = 60,
    val metadata: ReportMetadata = ReportMetadata(),
) {
    /** The settings a report prints: [therapySettings] with the basal schedule filled in. */
    internal val reportedSettings: TherapySettingsSnapshot?
        get() {
            var settings = therapySettings ?: TherapySettingsSnapshot()
            if (settings.basalSchedule == null) settings = settings.withBasalSchedule(basalSchedule)
            return if (settings.isEmpty) null else settings
        }
}

/** Validate (raw) → sanitize → aggregate. */
public class ReportBuilder(public val options: ReportOptions = ReportOptions()) {
    public fun build(definition: ReportDefinition, raw: TherapyDataset, now: Instant = Clock.System.now()): TherapyReport {
        val validator = DatasetValidator(DatasetValidator.standardRules + options.additionalRules, options.validation)
        var validation = validator.validate(raw, now)
        if (options.basalSchedule != null) {
            // Gaps are filled from the schedule, so low raw coverage no longer skews totals.
            validation = ValidationReport(validation.issues.filter { it.code != ValidationCode.insulinLowBasalCoverage })
        }

        var clean = DatasetSanitizer(options.validation, options.basalSchedule).sanitize(raw, now)
        // Time that has not happened yet is not missing data: statistics run up to `now`.
        if (raw.interval.end > now && now > raw.interval.start) {
            clean = clean.restricted(DateInterval(raw.interval.start, now))
        }
        val aggregator = StatsAggregator(options.thresholds, raw.source.timeZone, options.agpBucketMinutes, options.basalSchedule)

        return TherapyReport(
            schemaVersion = TherapyReport.CURRENT_SCHEMA_VERSION,
            definition = definition,
            interval = raw.interval,
            generatedAt = now,
            source = raw.source,
            metadata = options.metadata,
            thresholds = options.thresholds,
            summary = aggregator.summary(clean),
            daily = aggregator.daily(clean),
            agp = aggregator.agp(clean),
            dayPeriods = aggregator.dayPeriods(clean),
            validation = validation,
            dataSpan = clean.dataSpan,
            settings = options.reportedSettings,
        )
    }
}

/** Entry point for hosts. */
public object AIDReport {
    /** Fetches `definition.range` from [source] and builds the report. */
    public suspend fun generate(
        definition: ReportDefinition = ReportDefinition.standard,
        source: TherapyDataSource,
        options: ReportOptions = ReportOptions(),
        now: Instant = Clock.System.now(),
    ): TherapyReport {
        val raw = source.dataset(definition.range.resolve(now))
        return ReportBuilder(options).build(definition, raw, now)
    }
}

/**
 * The full report as JSON (ISO 8601 dates, sorted keys), in the same shape the Swift package
 * writes and reads — for sharing, archiving or feeding other tools. [TherapyReport.schemaVersion]
 * versions the format.
 */
public object JsonReportRenderer {
    public fun render(report: TherapyReport): String = ReportJson.encode(TherapyReport.serializer(), report)

    public fun decode(json: String): TherapyReport = ReportJson.format.decodeFromString(TherapyReport.serializer(), json)
}

/** The JSON settings shared with the Swift package: absent values left out, unknown keys ignored. */
public object ReportJson {
    public val format: Json = Json {
        encodeDefaults = true
        explicitNulls = false
        ignoreUnknownKeys = true
    }

    private val pretty = Json(format) {
        prettyPrint = true
        prettyPrintIndent = "  "
    }

    /** [value] pretty-printed with object keys in alphabetical order, as Swift's `.sortedKeys` writes them. */
    public fun <T> encode(serializer: SerializationStrategy<T>, value: T): String =
        pretty.encodeToString(JsonElement.serializer(), sortedKeys(format.encodeToJsonElement(serializer, value)))

    public fun <T> decode(serializer: KSerializer<T>, json: String): T = format.decodeFromString(serializer, json)

    private fun sortedKeys(element: JsonElement): JsonElement = when (element) {
        is JsonObject -> JsonObject(element.entries.sortedBy { it.key }.associate { it.key to sortedKeys(it.value) })
        is JsonArray -> JsonArray(element.map(::sortedKeys))
        else -> element
    }
}
