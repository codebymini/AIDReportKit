package io.github.codebymini.aidreport

import kotlin.math.abs
import kotlin.math.round

/**
 * [value] with exactly [decimals] digits after the point, as C's `%.nf` (and Swift's
 * `String(format:)`) print it: halves round to even, a negative value keeps its sign ("-0").
 */
internal fun fixed(value: Double, decimals: Int): String {
    if (value.isNaN()) return "nan"
    if (value.isInfinite()) return if (value > 0) "inf" else "-inf"
    var scale = 1.0
    repeat(decimals) { scale *= 10 }
    val digits = round(abs(value) * scale).toLong().toString().padStart(decimals + 1, '0')
    val text = if (decimals == 0) digits else digits.dropLast(decimals) + "." + digits.takeLast(decimals)
    val negative = value < 0 || (value == 0.0 && 1.0 / value < 0)
    return if (negative) "-$text" else text
}

/** [value] as a whole number padded with zeros to [width] digits, like `%02d`. */
internal fun padded(value: Int, width: Int): String = value.toString().padStart(width, '0')
