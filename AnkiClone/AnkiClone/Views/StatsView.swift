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
            HStack(spacing: 12) {
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
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    private var countsChart: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Counts", systemImage: "chart.bar.fill").font(.caption.weight(.heavy)).foregroundStyle(.indigo)
                Chart {
                    BarMark(x: .value("Category", "New"), y: .value("Count", cards.filter { $0.type == 0 }.count))
                        .foregroundStyle(.blue.gradient).cornerRadius(6)
                    BarMark(x: .value("Category", "Learning"), y: .value("Count", cards.filter { $0.queue == 1 || $0.queue == 3 }.count))
                        .foregroundStyle(.red.gradient).cornerRadius(6)
                    BarMark(x: .value("Category", "Due"), y: .value("Count", cards.filter { $0.queue == 2 && $0.dueDate <= Date() }.count))
                        .foregroundStyle(.green.gradient).cornerRadius(6)
                    BarMark(x: .value("Category", "Not Due"), y: .value("Count", cards.filter { $0.queue == 2 && $0.dueDate > Date() }.count))
                        .foregroundStyle(.orange.gradient).cornerRadius(6)
                }
                .frame(height: 160)
                .chartYAxis { AxisMarks(position: .leading) }
            }
        }
    }

    private var deckBreakdown: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Decks", systemImage: "rectangle.stack.fill").font(.caption.weight(.heavy)).foregroundStyle(.indigo)
                ForEach(decks) { deck in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deck.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let parent = deck.parentPath { Text(parent).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        Text("\(deck.totalCount)").font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(.secondary)
                        HStack(spacing: 3) {
                            if deck.newCount > 0 { Capsule().fill(Color.blue).frame(width: min(40, CGFloat(deck.newCount)*3+6), height: 8) }
                            if deck.learnCount > 0 { Capsule().fill(Color.red).frame(width: min(30, CGFloat(deck.learnCount)*6+6), height: 8) }
                            if deck.dueCount > 0 { Capsule().fill(Color.green).frame(width: min(40, CGFloat(deck.dueCount)*3+6), height: 8) }
                        }
                        .frame(width: 56, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    if deck.id != decks.last?.id { Divider().opacity(0.5) }
                }
            }
        }
    }

    private var forecastChart: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Due Forecast — next 7 days", systemImage: "calendar").font(.caption.weight(.heavy)).foregroundStyle(.indigo)
                let forecast = buildForecast()
                Chart {
                    ForEach(forecast, id: \.day) { item in
                        BarMark(x: .value("Day", item.label), y: .value("Cards", item.count))
                            .foregroundStyle(.green.gradient).cornerRadius(6)
                            .annotation(position: .top) {
                                if item.count > 0 { Text("\(item.count)").font(.caption2.weight(.bold)).foregroundStyle(.green) }
                            }
                    }
                }
                .frame(height: 140)
                .chartYAxis { AxisMarks(position: .leading) }
                HStack {
                    ForEach(forecast.prefix(7), id: \.day) { item in
                        VStack(spacing: 2) {
                            Text(item.label).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            Text("\(item.count)").font(.caption.weight(.bold)).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(item.count > 0 ? Color.green.opacity(0.10) : Color.clear))
                    }
                }
            }
        }
    }

    private var reviewLogChart: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Review History", systemImage: "clock.arrow.circlepath").font(.caption.weight(.heavy)).foregroundStyle(.indigo)
                if logs.isEmpty {
                    Text("No reviews yet — complete a study session to see history.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                } else {
                    let grouped = Dictionary(grouping: logs) { Calendar.current.startOfDay(for: $0.timestamp) }
                    let sorted = grouped.keys.sorted().suffix(14)
                    Chart {
                        ForEach(sorted, id: \.self) { day in
                            let count = grouped[day]?.count ?? 0
                            BarMark(x: .value("Date", day, unit: .day), y: .value("Reviews", count))
                                .foregroundStyle(.blue.gradient).cornerRadius(4)
                        }
                    }
                    .frame(height: 120)
                    .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.month().day()) } }
                    .chartYAxis { AxisMarks(position: .leading) }
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
            let endOfDay = cal.date(byAdding: .day, value: 1, to: day)!
            if offset == 0 {
                let preciseToday = cards.filter { $0.queue == 2 && $0.dueDate < endOfDay }.count
                return (day, label, preciseToday)
            } else {
                let precise = cards.filter { $0.queue == 2 && cal.isDate($0.dueDate, inSameDayAs: day) }.count
                return (day, label, precise)
            }
        }
    }
}

struct StatItem: View {
    let value: String; let label: String; let color: Color
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
        let f = DateFormatter(); f.dateFormat = "MM/dd"; return f
    }()
}
