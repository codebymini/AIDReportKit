@file:UseSerializers(IsoInstantSerializer::class)

package io.github.codebymini.aidreport

import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import java.io.File
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail
import kotlin.time.Instant

/**
 * The report fixtures in `Fixtures/reports` that the Swift and Kotlin code must both reproduce.
 *
 * Each case folder holds `input.json` (written by the Swift tests) and `report.json` (the report
 * the Swift package builds from it). Kotlin must build the same report from the same input. The
 * Swift side's `SharedFixtureTests` explains how to add cases.
 */
class SharedFixtureTest {
    private val directory = File(System.getProperty("aidreport.fixtures") ?: fail("aidreport.fixtures is not set"))
    private val output = File(System.getProperty("aidreport.fixtureOutput") ?: fail("aidreport.fixtureOutput is not set")).apply { mkdirs() }

    @Test
    fun everyCaseMatchesItsReport() {
        val cases = directory.listFiles().orEmpty().filter { File(it, "input.json").exists() }.sortedBy { it.name }
        assertTrue(cases.isNotEmpty(), "No cases in $directory")
        val failures = cases.mapNotNull { folder ->
            val input = ReportJson.decode(SharedFixtureInput.serializer(), File(folder, "input.json").readText())
            val report = ReportBuilder(input.options).build(input.definition, input.dataset, input.now)
            val rendered = JsonReportRenderer.render(report)
            // Kept for comparing by hand, and for checking that Swift reads what Kotlin writes.
            File(output, "${folder.name}.json").writeText(rendered)
            val actual = ReportJson.format.parseToJsonElement(rendered)
            val expected = ReportJson.format.parseToJsonElement(File(folder, "report.json").readText())
            val differences = differences(expected, actual)
            if (differences.isEmpty()) null else "${folder.name}:\n" + differences.take(20).joinToString("\n")
        }
        assertTrue(failures.isEmpty(), failures.joinToString("\n\n"))
    }

    @Test
    fun aChangedNumberOrKeyIsCaught() {
        val expected = ReportJson.format.parseToJsonElement(File(directory, "golden-utc/report.json").readText()).jsonObject
        val summary = expected.getValue("summary").jsonObject
        val glucose = summary.getValue("glucose").jsonObject
        val changedMean = JsonObject(expected + ("summary" to JsonObject(summary + ("glucose" to JsonObject(glucose + ("mean" to JsonPrimitive(145.001)))))))
        assertEquals(listOf("$.summary.glucose.mean: 145.001, expected 145.0"), differences(expected, changedMean))
        val extraKey = JsonObject(expected + ("extra" to JsonPrimitive(1)))
        assertEquals(listOf("$.extra: not expected"), differences(expected, extraKey))
    }

    @Test
    fun swiftReportsDecodeAndEncodeUnchanged() {
        for (folder in directory.listFiles().orEmpty().filter { File(it, "report.json").exists() }) {
            val text = File(folder, "report.json").readText()
            val report = JsonReportRenderer.decode(text)
            val differences = differences(ReportJson.format.parseToJsonElement(text), ReportJson.format.parseToJsonElement(JsonReportRenderer.render(report)))
            assertTrue(differences.isEmpty(), "${folder.name}:\n" + differences.take(20).joinToString("\n"))
        }
    }

    /**
     * Where [actual] differs from [expected], as JSON paths. Numbers may differ by a relative 1e-9
     * (the two languages add in different orders); validation messages are not compared, because
     * Swift translates them.
     */
    private fun differences(expected: JsonElement, actual: JsonElement, path: String = "$"): List<String> = when {
        expected is JsonObject && actual is JsonObject ->
            (expected.keys + actual.keys - "message").sorted().flatMap { key ->
                val e = expected[key]
                val a = actual[key]
                when {
                    e != null && a != null -> differences(e, a, "$path.$key")
                    e == null -> listOf("$path.$key: not expected")
                    else -> listOf("$path.$key: missing")
                }
            }
        expected is JsonArray && actual is JsonArray ->
            if (expected.size != actual.size) {
                listOf("$path: ${actual.size} items, expected ${expected.size}")
            } else {
                expected.zip(actual).flatMapIndexed { index, (e, a) -> differences(e, a, "$path[$index]") }
            }
        expected is JsonNull || actual is JsonNull ->
            if (expected == actual) emptyList() else listOf("$path: $actual, expected $expected")
        expected is JsonPrimitive && actual is JsonPrimitive -> when {
            expected.isString || actual.isString ->
                if (expected.isString == actual.isString && expected.content == actual.content) emptyList() else listOf("$path: $actual, expected $expected")
            expected.booleanOrNull != null || actual.booleanOrNull != null ->
                if (expected.booleanOrNull == actual.booleanOrNull) emptyList() else listOf("$path: $actual, expected $expected")
            else -> {
                val x = expected.doubleOrNull ?: Double.NaN
                val y = actual.doubleOrNull ?: Double.NaN
                if (abs(x - y) <= 1e-9 * maxOf(1.0, abs(x), abs(y))) emptyList() else listOf("$path: $y, expected $x")
            }
        }
        else -> listOf("$path: $actual, expected $expected")
    }
}

/** What a case feeds the report builder; the same fields as `SharedFixtureInput` in the Swift tests. */
@Serializable
private data class SharedFixtureInput(
    val now: Instant,
    val definition: ReportDefinition,
    val dataset: TherapyDataset,
    val thresholds: GlucoseThresholds? = null,
    val validation: ValidationConfiguration? = null,
    val basalSchedule: BasalSchedule? = null,
    val therapySettings: TherapySettingsSnapshot? = null,
    val agpBucketMinutes: Int? = null,
    val metadata: ReportMetadata? = null,
) {
    val options: ReportOptions
        get() = ReportOptions(
            thresholds = thresholds ?: GlucoseThresholds.consensus,
            validation = validation ?: ValidationConfiguration(),
            basalSchedule = basalSchedule,
            therapySettings = therapySettings,
            agpBucketMinutes = agpBucketMinutes ?: 60,
            metadata = metadata ?: ReportMetadata(),
        )
}
