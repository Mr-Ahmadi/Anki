import Foundation

// MARK: - Scheduler
// Anki-compatible scheduler (SM-2 variant). Supports both Anki v2 and FSRS-lite intervals.
// This implements the core scheduling used when answering cards.

enum Rating: Int, CaseIterable, Identifiable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }

    var color: String {
        switch self {
        case .again: return "red"
        case .hard: return "orange"
        case .good: return "green"
        case .easy: return "blue"
        }
    }
}

struct SchedulingResult {
    let newInterval: Int
    let newDueDate: Date
    let newEaseFactor: Int
    let newType: Int
    let newQueue: Int
    let newReps: Int
    let newLapses: Int
    let newLeft: Int
}

// Anki deck config defaults (dconf)
struct DeckConfig {
    var newDelays: [Double] = [1, 10] // minutes
    var newInitialFactor: Int = 2500
    var newInts: [Int] = [1, 4, 0] // again, hard, good, easy intervals
    var revEase4: Double = 1.3
    var revHardFactor: Double = 1.2
    var revMaxInterval: Int = 36500
    var revIntervalFactor: Double = 1.0
    var lapseDelays: [Double] = [10]
    var lapseMult: Double = 0.0
    var lapseMinInterval: Int = 1
    var leechFails: Int = 8

    static let `default` = DeckConfig()
}

final class Scheduler {

    // Collection creation time — used to compute day numbers like Anki does.
    // If not known, we use 0 and treat due as simple Date offsets.
    private let collectionCreation: Date
    private let config: DeckConfig

    init(collectionCreation: Date = Date(), config: DeckConfig = .default) {
        self.collectionCreation = collectionCreation
        self.config = config
    }

    // MARK: - Public

    func answer(card: Card, rating: Rating, answeredAt: Date = Date()) -> SchedulingResult {
        let currentInterval = card.interval
        let currentEase = card.easeFactor == 0 ? config.newInitialFactor : card.easeFactor

        switch card.type {
        case 0: // New
            return handleNew(card: card, rating: rating, ease: currentEase, answeredAt: answeredAt)
        case 1: // Learn
            return handleLearning(card: card, rating: rating, ease: currentEase, answeredAt: answeredAt)
        case 2: // Review
            return handleReview(card: card, rating: rating, ease: currentEase, currentInterval: currentInterval, answeredAt: answeredAt)
        case 3: // Relearn
            return handleRelearn(card: card, rating: rating, ease: currentEase, answeredAt: answeredAt)
        default:
            return handleReview(card: card, rating: rating, ease: currentEase, currentInterval: currentInterval, answeredAt: answeredAt)
        }
    }

    func nextIntervals(for card: Card) -> [Rating: String] {
        var result: [Rating: String] = [:]
        for rating in Rating.allCases {
            let r = answer(card: card, rating: rating)
            result[rating] = formatInterval(r.newInterval, dueDate: r.newDueDate)
        }
        return result
    }

    // Apply result directly to a Card (mutates)
    func apply(result: SchedulingResult, to card: Card) {
        card.interval = result.newInterval
        card.dueDate = result.newDueDate
        // maintain legacy due field as days since collection creation
        card.due = Int64(Calendar.current.dateComponents([.day], from: collectionCreation, to: result.newDueDate).day ?? 0)
        card.easeFactor = result.newEaseFactor
        card.type = result.newType
        card.queue = result.newQueue
        card.reps += 1
        card.lapses = result.newLapses
        card.left = result.newLeft
        card.mod = Int64(Date().timeIntervalSince1970 * 1000)
        if result.newType == 2 {
            card.lapses = result.newLapses
        }
    }

    // MARK: - Private handlers

    private func handleNew(card: Card, rating: Rating, ease: Int, answeredAt: Date) -> SchedulingResult {
        switch rating {
        case .again:
            // Stay in learning, 1 minute
            return SchedulingResult(
                newInterval: 0,
                newDueDate: answeredAt.addingTimeInterval(60),
                newEaseFactor: ease,
                newType: 1, newQueue: 1, newReps: card.reps + 1,
                newLapses: card.lapses, newLeft: 1001 // Anki's left encoding: 1000 + remaining steps
            )
        case .hard:
            // 6 hours-ish, or use second delay
            let delayMin = config.newDelays.count > 1 ? config.newDelays[1] : 6 * 60
            // If only one step, graduating interval for hard is ~1 day
            return SchedulingResult(
                newInterval: 0,
                newDueDate: answeredAt.addingTimeInterval(delayMin * 60),
                newEaseFactor: ease,
                newType: 1, newQueue: 1, newReps: card.reps + 1,
                newLapses: card.lapses, newLeft: 1001
            )
        case .good:
            let ivl = config.newInts.count > 0 ? config.newInts[0] : 1
            return SchedulingResult(
                newInterval: ivl,
                newDueDate: Calendar.current.date(byAdding: .day, value: ivl, to: answeredAt) ?? answeredAt,
                newEaseFactor: ease,
                newType: 2, newQueue: 2, newReps: card.reps + 1,
                newLapses: card.lapses, newLeft: 0
            )
        case .easy:
            let ivl = config.newInts.count > 1 ? config.newInts[1] : 4
            return SchedulingResult(
                newInterval: ivl,
                newDueDate: Calendar.current.date(byAdding: .day, value: ivl, to: answeredAt) ?? answeredAt,
                newEaseFactor: ease,
                newType: 2, newQueue: 2, newReps: card.reps + 1,
                newLapses: card.lapses, newLeft: 0
            )
        }
    }

    private func handleLearning(card: Card, rating: Rating, ease: Int, answeredAt: Date) -> SchedulingResult {
        switch rating {
        case .again:
            return SchedulingResult(
                newInterval: 0,
                newDueDate: answeredAt.addingTimeInterval((config.newDelays.first ?? 1) * 60),
                newEaseFactor: max(1300, ease - 200),
                newType: 1, newQueue: 1, newReps: card.reps + 1,
                newLapses: card.lapses, newLeft: card.left - 1
            )
        case .hard:
            let delay = config.newDelays.count > 1 ? config.newDelays[1] : 10
            return SchedulingResult(
                newInterval: 0,
                newDueDate: answeredAt.addingTimeInterval(delay * 60),
                newEaseFactor: ease,
                newType: 1, newQueue: 1, newReps: card.reps + 1,
                newLapses: card.lapses, newLeft: card.left
            )
        case .good:
            // Graduate to review
            return SchedulingResult(
                newInterval: 1,
                newDueDate: Calendar.current.date(byAdding: .day, value: 1, to: answeredAt) ?? answeredAt,
                newEaseFactor: ease,
                newType: 2, newQueue: 2, newReps: card.reps + 1,
                newLapses: card.lapses, newLeft: 0
            )
        case .easy:
            return SchedulingResult(
                newInterval: 4,
                newDueDate: Calendar.current.date(byAdding: .day, value: 4, to: answeredAt) ?? answeredAt,
                newEaseFactor: ease,
                newType: 2, newQueue: 2, newReps: card.reps + 1,
                newLapses: card.lapses, newLeft: 0
            )
        }
    }

    private func handleReview(card: Card, rating: Rating, ease: Int, currentInterval: Int, answeredAt: Date) -> SchedulingResult {
        let ivl = max(1, currentInterval)
        switch rating {
        case .again:
            let newEase = max(1300, ease - 200)
            let newIvl = max(config.lapseMinInterval, Int(Double(ivl) * config.lapseMult))
            // Go to relearning
            return SchedulingResult(
                newInterval: newIvl,
                newDueDate: answeredAt.addingTimeInterval((config.lapseDelays.first ?? 10) * 60),
                newEaseFactor: newEase,
                newType: 3, newQueue: 1, newReps: card.reps + 1,
                newLapses: card.lapses + 1, newLeft: 1001
            )
        case .hard:
            let newEase = max(1300, ease - 150)
            let newIvl = min(config.revMaxInterval, Int(Double(ivl) * config.revHardFactor * config.revIntervalFactor))
            return SchedulingResult(
                newInterval: max(1, newIvl),
                newDueDate: Calendar.current.date(byAdding: .day, value: max(1, newIvl), to: answeredAt) ?? answeredAt,
                newEaseFactor: newEase,
                newType: 2, newQueue: 2, newReps: card.reps + 1,
                newLapses: card.lapses, newLeft: 0
            )
        case .good:
            let factor = Double(ease) / 1000.0 * config.revIntervalFactor
            let newIvl = min(config.revMaxInterval, Int(Double(ivl) * factor))
            return SchedulingResult(
                newInterval: max(1, newIvl),
                newDueDate: Calendar.current.date(byAdding: .day, value: max(1, newIvl), to: answeredAt) ?? answeredAt,
                newEaseFactor: ease,
                newType: 2, newQueue: 2, newReps: card.reps + 1,
                newLapses: card.lapses, newLeft: 0
            )
        case .easy:
            let factor = Double(ease) / 1000.0 * config.revEase4 * config.revIntervalFactor
            let newIvl = min(config.revMaxInterval, Int(Double(ivl) * factor))
            let newEase = ease + 150
            return SchedulingResult(
                newInterval: max(1, newIvl),
                newDueDate: Calendar.current.date(byAdding: .day, value: max(1, newIvl), to: answeredAt) ?? answeredAt,
                newEaseFactor: min(9999, newEase),
                newType: 2, newQueue: 2, newReps: card.reps + 1,
                newLapses: card.lapses, newLeft: 0
            )
        }
    }

    private func handleRelearn(card: Card, rating: Rating, ease: Int, answeredAt: Date) -> SchedulingResult {
        switch rating {
        case .again:
            return SchedulingResult(
                newInterval: 0,
                newDueDate: answeredAt.addingTimeInterval((config.lapseDelays.first ?? 10) * 60),
                newEaseFactor: max(1300, ease - 200),
                newType: 3, newQueue: 1, newReps: card.reps + 1,
                newLapses: card.lapses, newLeft: card.left
            )
        case .hard, .good:
            // Graduate with min interval
            let ivl = max(config.lapseMinInterval, card.interval)
            return SchedulingResult(
                newInterval: ivl,
                newDueDate: Calendar.current.date(byAdding: .day, value: ivl, to: answeredAt) ?? answeredAt,
                newEaseFactor: ease,
                newType: 2, newQueue: 2, newReps: card.reps + 1,
                newLapses: card.lapses, newLeft: 0
            )
        case .easy:
            let ivl = max(config.lapseMinInterval, card.interval + 1)
            return SchedulingResult(
                newInterval: ivl,
                newDueDate: Calendar.current.date(byAdding: .day, value: ivl, to: answeredAt) ?? answeredAt,
                newEaseFactor: ease + 150,
                newType: 2, newQueue: 2, newReps: card.reps + 1,
                newLapses: card.lapses, newLeft: 0
            )
        }
    }

    private func formatInterval(_ ivl: Int, dueDate: Date) -> String {
        if ivl == 0 {
            let mins = max(1, Int(dueDate.timeIntervalSinceNow / 60))
            if mins < 60 { return "\(mins)m" }
            if mins < 1440 { return "\(mins/60)h" }
        }
        if ivl < 30 { return "\(ivl)d" }
        if ivl < 365 { return String(format: "%.1fmo", Double(ivl)/30.0) }
        return String(format: "%.1fy", Double(ivl)/365.0)
    }
}
