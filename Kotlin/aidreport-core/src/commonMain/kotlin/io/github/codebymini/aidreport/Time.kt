package io.github.codebymini.aidreport

import kotlinx.datetime.DateTimeUnit
import kotlinx.datetime.IllegalTimeZoneException
import kotlinx.datetime.TimeZone
import kotlinx.datetime.atStartOfDayIn
import kotlinx.datetime.plus
import kotlinx.datetime.toLocalDateTime
import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlin.time.Duration.Companion.seconds
import kotlin.time.DurationUnit
import kotlin.time.Instant

// Times are instants; lengths of time are seconds as Double, like Swift's `TimeInterval`, so the
// arithmetic reads the same in both implementations.

/** Seconds from [other] to this instant; negative when [other] is later. Swift's `timeIntervalSince`. */
internal fun Instant.secondsSince(other: Instant): Double = (this - other).toDouble(DurationUnit.SECONDS)

/** This instant moved by [seconds]. */
internal fun Instant.plusSeconds(seconds: Double): Instant = this + seconds.seconds

/** The time zone with [identifier], or the device's when there is none by that name. */
internal fun zoneNamed(identifier: String): TimeZone =
    try {
        TimeZone.of(identifier)
    } catch (_: IllegalTimeZoneException) {
        TimeZone.currentSystemDefault()
    }

/** Local midnight of the day [instant] falls on (the first moment of the day if midnight is skipped). */
internal fun TimeZone.startOfDay(instant: Instant): Instant = instant.toLocalDateTime(this).date.atStartOfDayIn(this)

/** The same local time [days] calendar days later, so a day across a clock change is 23 or 25 hours. */
internal fun TimeZone.addingDays(days: Int, instant: Instant): Instant = instant.plus(days, DateTimeUnit.DAY, this)

/**
 * Instants as ISO 8601 in UTC to the whole second ("2026-01-01T00:00:00Z"), the way Swift's
 * `JSONEncoder.DateEncodingStrategy.iso8601` writes and reads them, so either side reads the
 * other's JSON. Fractions of a second are dropped when writing.
 */
public object IsoInstantSerializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("io.github.codebymini.aidreport.Instant", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: Instant) {
        encoder.encodeString(Instant.fromEpochSeconds(value.epochSeconds).toString())
    }

    override fun deserialize(decoder: Decoder): Instant = Instant.parse(decoder.decodeString())
}
