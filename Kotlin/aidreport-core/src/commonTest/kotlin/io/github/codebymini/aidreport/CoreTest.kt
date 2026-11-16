package io.github.codebymini.aidreport

import kotlinx.coroutines.test.runTest
import kotlinx.datetime.TimeZone
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Instant

/** 2026-01-01 00:00 UTC */
private val t0 = Instant.fromEpochSeconds(1_767_225_600)
private const val HOUR = 3600.0
private const val DAY = 86400.0
private val utc = TimeZone.UTC

private fun at(hours: Double): Instant = t0.plusSeconds(hours * HOUR)

private fun readings(values: List<Double>, start: Instant = t0, step: Double = 300.0): List<GlucoseReading> =
    values.mapIndexed { index, value -> GlucoseReading(start.plusSeconds(index * step), value, sourceId = "g$index") }

private fun dataset(
    interval: DateInterval = DateInterval(t0, DAY),
    glucose: List<GlucoseReading> = emptyList(),
    insulin: List<InsulinDose> = emptyList(),
    carbs: List<CarbIntake> = emptyList(),
): TherapyDataset = TherapyDataset(interval, DataSourceInfo(HostApp.SYNTHETIC, timeZone = utc), glucose, insulin, carbs)

class FormatTest {
    @Test
    fun fixedRoundsHalvesToEvenLikePrintf() {
        assertEquals("2", fixed(2.5, 0))
        assertEquals("4", fixed(3.5, 0))
        assertEquals("0.12", fixed(0.125, 2))
        assertEquals("-0", fixed(-0.3, 0))
        assertEquals("10.0", fixed(180.0 / GlucoseUnit.MGDL_PER_MMOLL, 1))
        assertEquals("6.1 mmol/L", GlucoseUnit.MMOLL.format(110.0, includeUnit = true))
        assertEquals("110", GlucoseUnit.MGDL.format(110.4))
    }
}

class StatisticsTest {
    @Test
    fun glucoseStatisticsByHand() {
        // 144 readings at 100 and 144 at 200: mean 150, half in range, half high.
        val stats = GlucoseStatistics.compute(readings(List(144) { 100.0 } + List(144) { 200.0 }), DateInterval(t0, DAY))!!
        assertEquals(288, stats.readingCount)
        assertEquals(150.0, stats.mean, 1e-9)
        assertEquals(sqrt(144 * 2500.0 * 2 / 287), stats.standardDeviation, 1e-9)
        assertEquals(3.31 + 0.02392 * 150, stats.gmi, 1e-9)
        assertEquals((150 + 46.7) / 28.7, stats.estimatedA1c, 1e-9)
        assertEquals(0.5, stats.timeInRanges.inRange, 1e-9)
        assertEquals(0.5, stats.timeInRanges.high, 1e-9)
        assertEquals(1.0, stats.coverage, 1e-9)
        // GRI: hyper = 0.5 × 50 = 25 → 1.6 × 25 = 40, zone B.
        assertEquals(40.0, stats.gri.score, 1e-9)
        assertEquals(GlycemiaRiskIndex.Zone.B, stats.gri.zone)
    }

    @Test
    fun percentilesInterpolateBetweenRanks() {
        val p = Percentiles.of(listOf(1.0, 2.0, 3.0, 4.0, 5.0))!!
        assertEquals(1.2, p.p5, 1e-9)
        assertEquals(3.0, p.p50, 1e-9)
        assertNull(Percentiles.of(emptyList()))
    }

    @Test
    fun daysFollowTheTimeZoneAcrossTheClockChange() {
        // 2026-03-29 in Stockholm has 23 hours: clocks go from 02:00 to 03:00.
        val stockholm = TimeZone.of("Europe/Stockholm")
        val start = Instant.parse("2026-03-27T23:00:00Z") // 2026-03-28 00:00 in Stockholm
        val days = StatsAggregator(timeZone = stockholm).dayIntervals(DateInterval(start, 3 * DAY))
        assertEquals(listOf(24 * HOUR, 23 * HOUR, 24 * HOUR, 1 * HOUR), days.map { it.second.duration })
    }

    @Test
    fun dayPeriodsUseTheLocalHour() {
        val periods = DayPeriodRanges.compute(readings(listOf(60.0, 120.0), start = at(5.0), step = 2 * HOUR), utc)
        assertEquals(listOf(1, 1, 0, 0), periods.map { it.readingCount })
        assertEquals("06–12", DayPeriodRanges.Period.MORNING.hoursText)
    }
}

class BasalTest {
    private val schedule = BasalSchedule(
        listOf(BasalSchedule.Entry(6 * HOUR, 1.2), BasalSchedule.Entry(22 * HOUR, 0.9), BasalSchedule.Entry(3 * HOUR, 0.8)),
        utc,
    )!!

    @Test
    fun theEarliestEntryStartsAtMidnight() {
        assertEquals(listOf(0.0, 6 * HOUR, 22 * HOUR), schedule.entries.map { it.startOffset })
        assertEquals(0.8 * 6 + 1.2 * 16 + 0.9 * 2, schedule.dailyTotal, 1e-9)
        assertEquals(1.2, schedule.rate(at(12.0)))
        assertNull(BasalSchedule(emptyList(), utc))
    }

    @Test
    fun scheduledDosesSplitAtBoundariesAndMidnight() {
        val doses = schedule.doses(DateInterval(at(21.0), at(27.0)))
        assertEquals(listOf(at(21.0), at(22.0), at(24.0)), doses.map { it.start })
        assertEquals(1.2 + 0.9 * 2 + 0.8 * 3, doses.sumOf { it.units }, 1e-9)
    }

    @Test
    fun aNewTempBasalEndsTheRunningOneAndSuspensionsWin() {
        val doses = BasalTimeline.truncatingOverlaps(
            listOf(
                InsulinDose.basal(start = at(6.0), end = at(8.0), ratePerHour = 2.0),
                InsulinDose.basal(start = at(7.0), end = at(8.0), ratePerHour = 0.5),
                InsulinDose(InsulinDose.Kind.SUSPEND, at(7.5), at(7.75), 0.0),
            ),
        )
        assertEquals(2.0 + 0.25 + 0.125, doses.sumOf { it.units }, 1e-9)
        assertEquals(listOf(at(6.0), at(7.0), at(7.5), at(7.75)), doses.map { it.start })
    }
}

class ValidationTest {
    @Test
    fun readingsOutOfOrderDoNotLookLikeGaps() {
        // A whole day every 5 minutes, then a reading appended out of order to the JSON, as Swift
        // code that appends to a dataset writes it. Decoding keeps that order.
        val json = ReportJson.format.encodeToJsonElement(TherapyDataset.serializer(), dataset(glucose = readings(List(288) { 110.0 }))).jsonObject
        val late = GlucoseReading(at(2.0).plusSeconds(60.0), 112.0, sourceId = "late")
        val glucose = JsonArray(json.getValue("glucose").jsonArray + ReportJson.format.encodeToJsonElement(GlucoseReading.serializer(), late))
        val unsorted = ReportJson.format.decodeFromJsonElement(TherapyDataset.serializer(), JsonObject(json + ("glucose" to glucose)))
        assertEquals(late, unsorted.glucose.last())
        val codes = DatasetValidator().validate(unsorted, t0.plusSeconds(DAY)).issues.map { it.code }
        assertFalse(ValidationCode.glucoseGap in codes, codes.toString())
    }

    @Test
    fun badRecordsAreReportedAndLeftOutOfStatistics() {
        val data = dataset(
            glucose = readings(List(288) { 120.0 }) + GlucoseReading(at(3.01), 900.0, sourceId = "bad"),
            insulin = listOf(InsulinDose.bolus(at(8.0), 5.0, sourceId = "b1"), InsulinDose.bolus(at(8.0).plusSeconds(5.0), 5.0, sourceId = "b1")),
        )
        val report = ReportBuilder(ReportOptions(basalSchedule = BasalSchedule(listOf(BasalSchedule.Entry(0.0, 1.0)), utc))).build(
            ReportDefinition(range = ReportRange.Custom(data.interval)), data, t0.plusSeconds(DAY),
        )
        val codes = report.validation.issues.map { it.code }.toSet()
        assertTrue(ValidationCode.glucoseImplausibleValue in codes)
        assertTrue(ValidationCode.insulinDuplicateBolus in codes)
        assertEquals(120.0, report.summary.glucose!!.mean, 1e-9)
        assertEquals(5.0, report.summary.insulin.bolusUnits, 1e-9)
        // Scheduled basal fills from the first record (00:00) to the last (23:55).
        assertEquals(24 - 5.0 / 60, report.summary.insulin.basalUnits, 1e-9)
    }
}

class JsonTest {
    @Test
    fun rangesUseSwiftsEnumShape() {
        assertEquals("""{"lastDays":{"_0":7}}""", ReportJson.format.encodeToString(ReportRange.serializer(), ReportRange.week))
        val custom = ReportRange.Custom(DateInterval(t0, DAY))
        val json = ReportJson.format.encodeToString(ReportRange.serializer(), custom)
        assertEquals("""{"custom":{"_0":{"start":"2026-01-01T00:00:00Z","duration":86400.0}}}""", json)
        assertEquals(custom, ReportJson.format.decodeFromString(ReportRange.serializer(), json))
    }

    @Test
    fun unknownSectionsAreSkipped() {
        val json = """{"name":"Clinic","range":{"lastDays":{"_0":14}},"sections":["overview","glucosePercentileByTime","dataQuality"]}"""
        val definition = ReportJson.format.decodeFromString(ReportDefinition.serializer(), json)
        assertEquals(listOf(ReportSection.OVERVIEW, ReportSection.DATA_QUALITY), definition.sections)
        assertEquals(ReportRange.twoWeeks, definition.range)
    }

    @Test
    fun instantsAreWrittenToTheWholeSecond() {
        val reading = GlucoseReading(t0.plusSeconds(0.75), 100.0)
        assertTrue(""""date":"2026-01-01T00:00:00Z"""" in ReportJson.format.encodeToString(GlucoseReading.serializer(), reading))
    }
}

class MergeTest {
    private class Source(override val info: DataSourceInfo, private val readings: List<GlucoseReading>, private val fails: Boolean = false) : TherapyDataSource {
        override suspend fun glucose(interval: DateInterval): List<GlucoseReading> = if (fails) error("offline") else readings
        override suspend fun insulin(interval: DateInterval): List<InsulinDose> = if (fails) error("offline") else emptyList()
        override suspend fun carbs(interval: DateInterval): List<CarbIntake> = if (fails) error("offline") else emptyList()
    }

    @Test
    fun glucoseFillsGapsWithoutDoubleCounting() = runTest {
        val app = Source(DataSourceInfo(HostApp.ANDROID_APS, timeZone = utc), readings(List(6) { 100.0 }))
        val nightscout = Source(DataSourceInfo(HostApp.NIGHTSCOUT, timeZone = utc), readings(List(12) { 100.0 }, start = t0.plusSeconds(10.0)))
        val merged = MergedTherapyDataSource(listOf(app, nightscout)).dataset(DateInterval(t0, DAY))
        assertEquals(12, merged.glucose.size)
        assertEquals("AndroidAPS + Nightscout", merged.source.name)
    }

    @Test
    fun aFailingSourceIsSkipped() = runTest {
        val offline = Source(DataSourceInfo(HostApp.NIGHTSCOUT, timeZone = utc), emptyList(), fails = true)
        val app = Source(DataSourceInfo(HostApp.ANDROID_APS, timeZone = utc), readings(listOf(100.0, 110.0)))
        assertEquals(2, MergedTherapyDataSource(listOf(offline, app)).dataset(DateInterval(t0, DAY)).glucose.size)
    }
}
