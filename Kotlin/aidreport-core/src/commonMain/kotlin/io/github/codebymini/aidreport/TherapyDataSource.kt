package io.github.codebymini.aidreport

import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.abs
import kotlin.time.Instant

/**
 * The seam between the library and wherever data lives. Host apps implement it for their own
 * stores (AndroidAPS's database, …); see `Integrations/` in the repository.
 *
 * Contract:
 * - Glucose in mg/dL.
 * - Insulin `units` are absolute delivered units, not net-of-scheduled-basal.
 * - Results should cover the interval; they may extend past its edges (the pipeline clamps).
 */
public interface TherapyDataSource {
    public val info: DataSourceInfo

    public suspend fun glucose(interval: DateInterval): List<GlucoseReading>

    public suspend fun insulin(interval: DateInterval): List<InsulinDose>

    public suspend fun carbs(interval: DateInterval): List<CarbIntake>

    /** Fetches all three. Override when the backing store can do it in fewer round trips. */
    public suspend fun dataset(interval: DateInterval): TherapyDataset =
        TherapyDataset(interval, info, glucose(interval), insulin(interval), carbs(interval))
}

/** How a [MergedTherapyDataSource] combines one stream (glucose, insulin or carbs) across sources. */
public sealed interface MergeStrategy {
    /** Use only the first source. */
    public data object PrimaryOnly : MergeStrategy

    /** Use the first source (in order) that returns any data for the interval. */
    public data object FirstNonEmpty : MergeStrategy

    /**
     * Start from the first source; add records from later sources only where nothing from an
     * earlier source lies within [window] seconds. Basal-like doses are clipped to uncovered time.
     */
    public data class FillGaps(val window: Double) : MergeStrategy
}

/**
 * Combines several sources — typically a host app's own store and Nightscout — into one, without
 * double counting the data each app mirrors to the others.
 *
 * Defaults: glucose fills gaps (a reading missing from one source can come from another), insulin
 * and carbs come whole from the first source that has any, because partial insulin merges are
 * where double counting happens.
 *
 * A source that throws is skipped; the merge throws only if every source fails.
 */
public class MergedTherapyDataSource(
    public val sources: List<TherapyDataSource>,
    info: DataSourceInfo? = null,
    public var glucoseStrategy: MergeStrategy = MergeStrategy.FillGaps(150.0),
    public var insulinStrategy: MergeStrategy = MergeStrategy.FirstNonEmpty,
    public var carbStrategy: MergeStrategy = MergeStrategy.FirstNonEmpty,
) : TherapyDataSource {
    init {
        require(sources.isNotEmpty()) { "MergedTherapyDataSource needs at least one source" }
    }

    override val info: DataSourceInfo = info ?: sources[0].info.let { primary ->
        DataSourceInfo(
            app = HostApp.MERGED,
            name = sources.joinToString(" + ") { it.info.name },
            appVersion = primary.appVersion,
            displayUnit = primary.displayUnit,
            timeZoneIdentifier = primary.timeZoneIdentifier,
        )
    }

    override suspend fun glucose(interval: DateInterval): List<GlucoseReading> =
        combine(fetchAll(glucoseStrategy) { it.glucose(interval) }, glucoseStrategy, ::fillGlucose)

    override suspend fun insulin(interval: DateInterval): List<InsulinDose> =
        combine(fetchAll(insulinStrategy) { it.insulin(interval) }, insulinStrategy, ::fillInsulin)

    override suspend fun carbs(interval: DateInterval): List<CarbIntake> =
        combine(fetchAll(carbStrategy) { it.carbs(interval) }, carbStrategy, ::fillCarbs)

    /**
     * One `dataset` call per source, so sources that fetch several streams in one round trip
     * (Nightscout treatments) are not asked twice.
     */
    override suspend fun dataset(interval: DateInterval): TherapyDataset {
        val strategies = listOf(glucoseStrategy, insulinStrategy, carbStrategy)
        val needed = if (strategies.all { it == MergeStrategy.PrimaryOnly }) sources.take(1) else sources
        val datasets = mutableListOf<TherapyDataset?>()
        var firstError: Exception? = null
        for (source in needed) {
            try {
                datasets += source.dataset(interval)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (firstError == null) firstError = e
                datasets += null
            }
        }
        if (datasets.all { it == null } && firstError != null) throw firstError
        return TherapyDataset(
            interval = interval,
            source = info,
            glucose = combine(datasets.map { it?.glucose.orEmpty() }, glucoseStrategy, ::fillGlucose),
            insulin = combine(datasets.map { it?.insulin.orEmpty() }, insulinStrategy, ::fillInsulin),
            carbs = combine(datasets.map { it?.carbs.orEmpty() }, carbStrategy, ::fillCarbs),
        )
    }

    /**
     * Fetches one stream from every source (only the first for [MergeStrategy.PrimaryOnly]). A source
     * that throws contributes nothing; the call throws only if every source fails.
     */
    private suspend fun <T> fetchAll(strategy: MergeStrategy, fetch: suspend (TherapyDataSource) -> List<T>): List<List<T>> {
        if (strategy == MergeStrategy.PrimaryOnly) return listOf(fetch(sources[0]))
        val results = mutableListOf<List<T>>()
        val errors = mutableListOf<Exception>()
        for (source in sources) {
            try {
                results += fetch(source)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errors += e
                results += emptyList<T>()
            }
        }
        if (errors.size == sources.size) throw errors.first()
        return results
    }

    internal companion object {
        fun <T> combine(results: List<List<T>>, strategy: MergeStrategy, fill: (List<T>, List<T>, Double) -> List<T>): List<T> {
            val first = results.firstOrNull() ?: return emptyList()
            return when (strategy) {
                MergeStrategy.PrimaryOnly -> first
                MergeStrategy.FirstNonEmpty -> results.firstOrNull { it.isNotEmpty() }.orEmpty()
                is MergeStrategy.FillGaps -> results.drop(1).fold(first) { merged, next -> fill(merged, next, strategy.window) }
            }
        }

        fun fillGlucose(base: List<GlucoseReading>, candidates: List<GlucoseReading>, window: Double): List<GlucoseReading> =
            fillPoints(base, candidates, window) { it.date }

        fun fillCarbs(base: List<CarbIntake>, candidates: List<CarbIntake>, window: Double): List<CarbIntake> =
            fillPoints(base, candidates, window) { it.date }

        fun fillInsulin(base: List<InsulinDose>, candidates: List<InsulinDose>, window: Double): List<InsulinDose> {
            val boluses = fillPoints(base.filter { !it.isBasalLike }, candidates.filter { !it.isBasalLike }, window) { it.start }
            val basal = base.filter { it.isBasalLike }
            val covered = BasalTimeline.coveredIntervals(basal)
            val extraBasal = candidates.filter { it.isBasalLike }.flatMap { dose ->
                if (dose.duration <= 0) {
                    emptyList()
                } else {
                    BasalTimeline.gaps(DateInterval(dose.start, dose.end), covered).mapNotNull { dose.clamped(it) }
                }
            }
            return boluses + basal + extraBasal
        }

        /** Adds each candidate whose timestamp is more than [window] seconds from every record in [base]. */
        fun <T> fillPoints(base: List<T>, candidates: List<T>, window: Double, date: (T) -> Instant): List<T> {
            val baseDates = base.map(date).sorted()
            return base + candidates.filter { nearestDistance(date(it), baseDates) > window }
        }

        private fun nearestDistance(target: Instant, sorted: List<Instant>): Double {
            if (sorted.isEmpty()) return Double.POSITIVE_INFINITY
            var low = 0
            var high = sorted.size
            while (low < high) {
                val mid = (low + high) / 2
                if (sorted[mid] < target) low = mid + 1 else high = mid
            }
            var best = Double.POSITIVE_INFINITY
            if (low < sorted.size) best = minOf(best, abs(sorted[low].secondsSince(target)))
            if (low > 0) best = minOf(best, abs(sorted[low - 1].secondsSince(target)))
            return best
        }
    }
}
