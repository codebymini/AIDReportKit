@file:UseSerializers(IsoInstantSerializer::class)

package io.github.codebymini.aidreport

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.CompositeDecoder
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.encoding.decodeStructure
import kotlinx.serialization.encoding.encodeStructure
import kotlin.time.Clock
import kotlin.time.Instant

/** The period a report covers. In JSON as Swift writes its enum: `{"lastDays": {"_0": 30}}`. */
@Serializable(with = ReportRangeSerializer::class)
public sealed interface ReportRange {
    /**
     * Rolling window ending when the report is generated (same fixed offsets as Trio's stats
     * ranges). Its first and last calendar days are partial; reports say so (see [DataSpan]).
     */
    public data class LastDays(val days: Int) : ReportRange

    public data class Custom(val interval: DateInterval) : ReportRange

    public fun resolve(now: Instant = Clock.System.now()): DateInterval = when (this) {
        is LastDays -> DateInterval(now.plusSeconds(-maxOf(days, 1) * 86400.0), now)
        is Custom -> interval
    }

    public val displayName: String
        get() = when (this) {
            LastDays(1) -> "Last 24 hours"
            is LastDays -> "Last $days days"
            is Custom -> "Custom range"
        }

    /** Compact name for a segmented range picker ("D", "W", "M", "3 M"). */
    public val shortName: String
        get() = when (this) {
            LastDays(1) -> "D"
            LastDays(7) -> "W"
            LastDays(14) -> "2 W"
            LastDays(30) -> "M"
            LastDays(90) -> "3 M"
            is LastDays -> "$days D"
            is Custom -> "Custom"
        }

    public companion object {
        public val day: ReportRange = LastDays(1)
        public val week: ReportRange = LastDays(7)
        public val twoWeeks: ReportRange = LastDays(14)
        public val month: ReportRange = LastDays(30)
        public val threeMonths: ReportRange = LastDays(90)

        /**
         * The ranges offered in the export sheet: the same D / W / M / 3 M as Trio's statistics.
         * Other ranges remain valid in definitions and presets.
         */
        public val presets: List<ReportRange> = listOf(day, week, month, threeMonths)

        /**
         * The presets a host that keeps only [history] seconds of data can honour. A longer range
         * would average that data over days the host knows nothing about.
         */
        public fun presets(history: Double): List<ReportRange> = presets.filter { it.resolve().duration <= history }
    }
}

internal object ReportRangeSerializer : KSerializer<ReportRange> {
    @Serializable
    private class LastDaysPayload(@SerialName("_0") val days: Int)

    @Serializable
    private class CustomPayload(@SerialName("_0") val interval: DateInterval)

    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("io.github.codebymini.aidreport.ReportRange") {
        element("lastDays", LastDaysPayload.serializer().descriptor, isOptional = true)
        element("custom", CustomPayload.serializer().descriptor, isOptional = true)
    }

    override fun serialize(encoder: Encoder, value: ReportRange) {
        encoder.encodeStructure(descriptor) {
            when (value) {
                is ReportRange.LastDays -> encodeSerializableElement(descriptor, 0, LastDaysPayload.serializer(), LastDaysPayload(value.days))
                is ReportRange.Custom -> encodeSerializableElement(descriptor, 1, CustomPayload.serializer(), CustomPayload(value.interval))
            }
        }
    }

    override fun deserialize(decoder: Decoder): ReportRange = decoder.decodeStructure(descriptor) {
        var range: ReportRange? = null
        while (true) {
            when (val index = decodeElementIndex(descriptor)) {
                0 -> range = ReportRange.LastDays(decodeSerializableElement(descriptor, 0, LastDaysPayload.serializer()).days)
                1 -> range = ReportRange.Custom(decodeSerializableElement(descriptor, 1, CustomPayload.serializer()).interval)
                CompositeDecoder.DECODE_DONE -> break
                else -> throw SerializationException("Unexpected ReportRange element $index")
            }
        }
        range ?: throw SerializationException("A ReportRange needs lastDays or custom")
    }
}

/**
 * Everything a report can contain, across all categories, as one flat list. A report is an
 * ordered list of these; renderers produce one page/section per entry.
 *
 * Entry order is the PDF page order: the overview, then the charts in the order the export menu
 * lists them (glucose, carbs, insulin — the same order as Trio's statistics export), then data
 * quality as the closing page.
 */
@Serializable
public enum class ReportSection(public val rawValue: String) {
    @SerialName("overview") OVERVIEW("overview"),
    @SerialName("glucoseDistribution") GLUCOSE_DISTRIBUTION("glucoseDistribution"),
    @SerialName("glycemiaRiskIndex") GLYCEMIA_RISK_INDEX("glycemiaRiskIndex"),
    @SerialName("glucosePercentileByDay") GLUCOSE_PERCENTILE_BY_DAY("glucosePercentileByDay"),
    @SerialName("glucoseDistributionByDay") GLUCOSE_DISTRIBUTION_BY_DAY("glucoseDistributionByDay"),
    @SerialName("glucoseHeatmapByDay") GLUCOSE_HEATMAP_BY_DAY("glucoseHeatmapByDay"),
    @SerialName("carbsTotals") CARBS_TOTALS("carbsTotals"),
    @SerialName("insulinTotalDailyDose") INSULIN_TOTAL_DAILY_DOSE("insulinTotalDailyDose"),
    @SerialName("therapySettings") THERAPY_SETTINGS("therapySettings"),
    @SerialName("insulinBolusDistribution") INSULIN_BOLUS_DISTRIBUTION("insulinBolusDistribution"),
    @SerialName("dataQuality") DATA_QUALITY("dataQuality");

    /** The rows of the export menu, in the order they are listed. */
    @Serializable
    public enum class Category(public val title: String) {
        /** Overview and data quality: the pages that are not a single chart. */
        @SerialName("summary") SUMMARY("Summary"),
        @SerialName("glucose") GLUCOSE("Glucose"),
        @SerialName("carbs") CARBS("Carbs"),
        @SerialName("insulin") INSULIN("Insulin");

        /** This category's sections, in menu order. */
        public val sections: List<ReportSection> get() = ReportSection.entries.filter { it.category == this }
    }

    public val category: Category
        get() = when (this) {
            OVERVIEW, DATA_QUALITY -> Category.SUMMARY
            GLUCOSE_DISTRIBUTION, GLUCOSE_DISTRIBUTION_BY_DAY, GLUCOSE_PERCENTILE_BY_DAY, GLUCOSE_HEATMAP_BY_DAY, GLYCEMIA_RISK_INDEX -> Category.GLUCOSE
            INSULIN_TOTAL_DAILY_DOSE, THERAPY_SETTINGS, INSULIN_BOLUS_DISTRIBUTION -> Category.INSULIN
            CARBS_TOTALS -> Category.CARBS
        }

    /**
     * Short name for the export menu, where the category row above already says "Glucose", "Carbs"
     * or "Insulin". Matches the chart names in Trio's statistics.
     */
    public val menuTitle: String
        get() = when (this) {
            OVERVIEW -> "Overview"
            GLUCOSE_DISTRIBUTION -> "Distribution"
            GLYCEMIA_RISK_INDEX -> "Glycemia Risk Index"
            GLUCOSE_PERCENTILE_BY_DAY -> "Percentile (by day)"
            GLUCOSE_DISTRIBUTION_BY_DAY -> "Distribution (by day)"
            GLUCOSE_HEATMAP_BY_DAY -> "Heatmap (by day)"
            CARBS_TOTALS -> "Total Meals"
            INSULIN_TOTAL_DAILY_DOSE -> "Insulin"
            THERAPY_SETTINGS -> "Settings"
            INSULIN_BOLUS_DISTRIBUTION -> "Bolus Distribution"
            DATA_QUALITY -> "Data Quality"
        }

    public val title: String
        get() = when (this) {
            OVERVIEW -> "Overview"
            GLUCOSE_DISTRIBUTION -> "Glucose Distribution"
            GLUCOSE_DISTRIBUTION_BY_DAY -> "Glucose Distribution by Day"
            GLUCOSE_PERCENTILE_BY_DAY -> "Glucose Percentiles by Day"
            GLUCOSE_HEATMAP_BY_DAY -> "Average Glucose by Day"
            GLYCEMIA_RISK_INDEX -> "Glycemia Risk Index"
            INSULIN_TOTAL_DAILY_DOSE -> "Insulin"
            THERAPY_SETTINGS -> "Settings"
            INSULIN_BOLUS_DISTRIBUTION -> "Bolus Distribution"
            CARBS_TOTALS -> "Carbohydrates"
            DATA_QUALITY -> "Data Quality"
        }

    /** By-day sections need at least two days to show anything useful. */
    public val minimumDays: Int
        get() = when (this) {
            GLUCOSE_DISTRIBUTION_BY_DAY, GLUCOSE_PERCENTILE_BY_DAY, GLUCOSE_HEATMAP_BY_DAY -> 2
            else -> 1
        }

    /** One entry per day: has nothing meaningful to show for a single-day range. */
    public val isPerDay: Boolean get() = minimumDays > 1

    /**
     * Shows a value for each calendar day, so a partial first or last day looks smaller than it
     * was. These sections carry the partial-day warning.
     */
    public val showsDailyValues: Boolean
        get() = when (this) {
            GLUCOSE_PERCENTILE_BY_DAY, GLUCOSE_DISTRIBUTION_BY_DAY, GLUCOSE_HEATMAP_BY_DAY,
            CARBS_TOTALS, INSULIN_TOTAL_DAILY_DOSE, INSULIN_BOLUS_DISTRIBUTION,
            -> true
            OVERVIEW, GLUCOSE_DISTRIBUTION, GLYCEMIA_RISK_INDEX, THERAPY_SETTINGS, DATA_QUALITY -> false
        }

    public companion object {
        public fun fromRawValue(rawValue: String): ReportSection? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/** What to put in a report: name, range and ordered sections. */
@Serializable
public data class ReportDefinition(
    /** Names a saved preset in the export sheet. Not printed in the report. */
    val name: String = "",
    val range: ReportRange = ReportRange.month,
    /**
     * Sections this version does not know are skipped when decoding, so saved presets keep loading
     * after a section is removed or one from a newer version appears.
     */
    @Serializable(with = LenientSectionsSerializer::class)
    val sections: List<ReportSection> = defaultSections,
) {
    /** Sections that cannot be produced for [interval] (e.g. by-day charts on a 1-day report). */
    public fun unsupportedSections(interval: DateInterval): List<ReportSection> {
        val days = interval.duration / 86400
        return sections.filter { it.minimumDays > days + 0.001 }
    }

    public companion object {
        public val defaultSections: List<ReportSection> = listOf(
            ReportSection.OVERVIEW, ReportSection.GLUCOSE_DISTRIBUTION, ReportSection.GLYCEMIA_RISK_INDEX,
            ReportSection.CARBS_TOTALS, ReportSection.INSULIN_TOTAL_DAILY_DOSE, ReportSection.DATA_QUALITY,
        )

        public val standard: ReportDefinition = ReportDefinition()
    }
}

internal object LenientSectionsSerializer : KSerializer<List<ReportSection>> {
    private val strings = ListSerializer(String.serializer())
    override val descriptor: SerialDescriptor = strings.descriptor

    override fun serialize(encoder: Encoder, value: List<ReportSection>) {
        encoder.encodeSerializableValue(strings, value.map { it.rawValue })
    }

    override fun deserialize(decoder: Decoder): List<ReportSection> =
        decoder.decodeSerializableValue(strings).mapNotNull(ReportSection::fromRawValue)
}

/** Header information so a printed report can be read on its own. */
@Serializable
public data class ReportMetadata(
    /** Printed under the report title. */
    val patientName: String? = null,
    val appName: String? = null,
    val appVersion: String? = null,
    val buildDate: String? = null,
    val cgm: String? = null,
    val pump: String? = null,
    val device: String? = null,
    /** Host-chosen settings that help interpret the numbers (closed loop, SMB, dynamic ISF, …). */
    val settings: List<Item> = emptyList(),
) {
    @Serializable
    public data class Item(val label: String, val value: String)

    val hardwareItems: List<Item> get() = items("CGM" to cgm, "Pump" to pump, "Device" to device)

    val softwareItems: List<Item> get() = items("App" to appName, "Version" to appVersion, "Build date" to buildDate)

    /** The patient name without surrounding whitespace, or `null` when there is none to print. */
    val printablePatientName: String? get() = patientName?.trim()?.ifEmpty { null }

    /** Whether there is no hardware, software or settings information to print. */
    val isEmpty: Boolean get() = hardwareItems.isEmpty() && softwareItems.isEmpty() && settings.isEmpty()

    /** Drops missing and empty values (e.g. no pump paired yet). */
    private fun items(vararg pairs: Pair<String, String?>): List<Item> =
        pairs.mapNotNull { (label, value) -> if (value.isNullOrBlank()) null else Item(label, value) }
}

/**
 * A named, reusable report definition, so the same multi-section report (e.g. for a recurring
 * clinic visit) can be regenerated without re-picking every section.
 */
@Serializable
public data class ReportPreset(
    val id: String = kotlin.uuid.Uuid.random().toString().uppercase(),
    val name: String,
    val definition: ReportDefinition,
    val createdAt: Instant = Clock.System.now(),
)

/**
 * Persistence for presets. Hosts back it with their own storage; [ReportPresetCodec] turns the
 * list into the JSON the Swift package writes.
 */
public interface ReportPresetStore {
    public fun load(): List<ReportPreset>

    public fun save(presets: List<ReportPreset>)

    /** Most recently created first. */
    public fun presets(): List<ReportPreset> = load().sortedByDescending { it.createdAt }

    /** Inserts, or replaces the preset with the same id. */
    public fun upsert(preset: ReportPreset) {
        save(load().filter { it.id != preset.id } + preset)
    }

    public fun delete(id: String) {
        save(load().filter { it.id != id })
    }
}

public object ReportPresetCodec {
    private val serializer = ListSerializer(ReportPreset.serializer())

    public fun encode(presets: List<ReportPreset>): String = ReportJson.encode(serializer, presets)

    public fun decode(json: String): List<ReportPreset> = ReportJson.format.decodeFromString(serializer, json)
}
