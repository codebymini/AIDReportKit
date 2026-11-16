@file:UseSerializers(IsoInstantSerializer::class)

package io.github.codebymini.aidreport

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlin.time.Instant

/**
 * A span of time from [start] to [end]. Foundation's `DateInterval`: written to JSON as
 * `{"start": …, "duration": seconds}`, as Swift writes it.
 */
@Serializable(with = DateIntervalSerializer::class)
public data class DateInterval(val start: Instant, val end: Instant) {
    init {
        require(end >= start) { "A DateInterval cannot end ($end) before it starts ($start)" }
    }

    public constructor(start: Instant, duration: Double) : this(start, start.plusSeconds(duration))

    /** Length in seconds. */
    val duration: Double get() = end.secondsSince(start)

    /** `start <= date < end`. Foundation's `contains` includes `end`, which double-counts at day boundaries. */
    public fun containsHalfOpen(date: Instant): Boolean = date >= start && date < end

    /** The time both intervals cover; zero-length when they only touch, `null` when they are apart. */
    public fun intersection(other: DateInterval): DateInterval? {
        val start = maxOf(start, other.start)
        val end = minOf(end, other.end)
        return if (end < start) null else DateInterval(start, end)
    }
}

@Serializable
private class DateIntervalSurrogate(val start: Instant, val duration: Double)

internal object DateIntervalSerializer : KSerializer<DateInterval> {
    override val descriptor: SerialDescriptor =
        SerialDescriptor("io.github.codebymini.aidreport.DateInterval", DateIntervalSurrogate.serializer().descriptor)

    override fun serialize(encoder: Encoder, value: DateInterval) {
        encoder.encodeSerializableValue(DateIntervalSurrogate.serializer(), DateIntervalSurrogate(value.start, value.duration))
    }

    override fun deserialize(decoder: Decoder): DateInterval {
        val surrogate = decoder.decodeSerializableValue(DateIntervalSurrogate.serializer())
        return DateInterval(surrogate.start, surrogate.duration)
    }
}
