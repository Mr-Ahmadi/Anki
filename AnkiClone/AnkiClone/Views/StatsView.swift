import SwiftUI
import SwiftData
import Charts

struct StatsView: View {
    @Query private var decks: [Deck]
    @Query private var cards: [Card]
    @Query private var logs: [ReviewLog]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header

                    if cards.isEmpty {
                        ContentUnavailableView("No Data", systemImage: "chart.bar", description: Text("Study some cards to see statistics."))
                            .padding(.top, 40)
                    } else {
                        countsChart
                        deckBreakdown
                        forecastChart
                        reviewLogChart
                    }
                }
                .padding()
            }
            .navigationTitle("Statistics")
            .background(Color(.secondarySystemGroupedBackground))
        }
    }

    private var header: some View {
        GroupBox {
            HStack(spacing: 16) {
                StatItem(value: "\(cards.count)", label: "Total", color: .primary)
                Divider()
                StatItem(value: "\(cards.filter { $0.type == 0 }.count)", label: "New", color: .blue)
                Divider()
                StatItem(value: "\(cards.filter { $0.queue == 1 || $0.queue == 3 }.count)", label: "Learn", color: .red)
                Divider()
                StatItem(value: "\(cards.filter { $0.queue == 2 }.count)", label: "Review", color: .green)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var countsChart: some View {
        GroupBox("Counts") {
            Chart {
                BarMark(x: .value("Category", "New"), y: .value("Count", cards.filter { $0.type == 0 }.count))
                    .foregroundStyle(.blue)
                BarMark(x: .value("Category", "Learning"), y: .value("Count", cards.filter { $0.queue == 1 || $0.queue == 3 }.count))
                    .foregroundStyle(.red)
                BarMark(x: .value("Category", "Due"), y: .value("Count", cards.filter { $0.queue == 2 && $0.dueDate <= Date() }.count))
                    .foregroundStyle(.green)
                BarMark(x: .value("Category", "Not Due"), y: .value("Count", cards.filter { $0.queue == 2 && $0.dueDate > Date() }.count))
                    .foregroundStyle(.orange)
            }
            .frame(height: 160)
            // Fallback if Charts not available on older OS: handled by build target 17, so ok.
        }
    }

    private var deckBreakdown: some View {
        GroupBox("Decks") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(decks) { deck in
                    HStack {
                        Text(deck.displayName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Text("\(deck.totalCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        // Mini bar
                        HStack(spacing: 2) {
                            if deck.newCount > 0 {
                                Rectangle().fill(Color.blue).frame(width: CGFloat(deck.newCount) * 2 + 4, height: 8).clipShape(Capsule())
                            }
                            if deck.learnCount > 0 {
                                Rectangle().fill(Color.red).frame(width: CGFloat(deck.learnCount) * 6 + 4, height: 8).clipShape(Capsule())
                            }
                            if deck.dueCount > 0 {
                                Rectangle().fill(Color.green).frame(width: CGFloat(deck.dueCount) * 2 + 4, height: 8).clipShape(Capsule())
                            }
                        }
                    }
                    if deck.id != decks.last?.id { Divider() }
                }
            }
        }
    }

    private var forecastChart: some View {
        GroupBox("Due Forecast (next 7 days)") {
            let forecast = buildForecast()
            Chart {
                ForEach(forecast, id: \.day) { item in
                    BarMark(
                        x: .value("Day", item.label),
                        y: .value("Cards", item.count)
                    )
                    .foregroundStyle(.green.gradient)
                }
            }
            .frame(height: 140)
            HStack {
                ForEach(forecast.prefix(7), id: \.day) { item in
                    VStack {
                        Text(item.label).font(.caption2)
                        Text("\(item.count)").font(.caption.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
        }
    }

    private var reviewLogChart: some View {
        GroupBox("Review History") {
            if logs.isEmpty {
                Text("No reviews yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                // Simple last 7 days
                let grouped = Dictionary(grouping: logs) { Calendar.current.startOfDay(for: $0.timestamp) }
                let sorted = grouped.keys.sorted().suffix(14)
                Chart {
                    ForEach(sorted, id: \.self) { day in
                        let count = grouped[day]?.count ?? 0
                        BarMark(
                            x: .value("Date", day, unit: .day),
                            y: .value("Reviews", count)
                        )
                        .foregroundStyle(.blue.gradient)
                    }
                }
                .frame(height: 120)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) {
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
            }
        }
    }

    private func buildForecast() -> [(day: Date, label: String, count: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).map { offset in
            let day = cal.date(byAdding: .day, value: offset, to: today)!
            let label = offset == 0 ? "Today" : DateFormatter.cachedShort.string(from: day)
            // Fix precedence bug: today includes overdue + due today; future days only exact day
            let count: Int
            if offset == 0 {
                count = cards.filter { $0.queue == 2 && $0.dueDate <= cal.date(byAdding: .day, value: 1, to: day)! }.count
                // Simpler: all due up to end of today
                let endOfToday = cal.date(byAdding: .day, value: 1, to: day)!
                let preciseToday = cards.filter { $0.queue == 2 && $0.dueDate < endOfToday }.count
                return (day, label, preciseToday)
            } else {
                let precise = cards.filter {
                    $0.queue == 2 && cal.isDate($0.dueDate, inSameDayAs: day)
                }.count
                return (day, label, precise)
            }
        }
    }
}

struct StatItem: View {
    let value: String
    let label: String
    let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold)).foregroundStyle(color).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private extension DateFormatter {
    static let cachedShort: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd"
        return f
    }()
}
