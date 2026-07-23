import SwiftUI

/// Hand-rolled bar chart: thin bars with rounded data-ends anchored to a
/// hairline baseline, 2pt gaps, selective direct labels (max bar + hovered bar),
/// full-column hover targets. Values wear text ink, never the series color.
struct BarChartView: View {
	struct BarDatum: Identifiable {
		let id: Int
		let axisLabel: String?
		let value: Int
		let color: Color
	}

	let title: String
	let data: [BarDatum]
	@State private var hovered: Int?

	private static let plotHeight: CGFloat = 64

	private var maxValue: Int {
		max(data.map(\.value).max() ?? 0, 1)
	}

	private var isEmpty: Bool {
		data.allSatisfy { $0.value == 0 }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title)
				.font(.caption)
				.foregroundStyle(.secondary)
			if isEmpty {
				Text("none in range")
					.font(.caption2)
					.foregroundStyle(Viz.mutedInk)
					.frame(maxWidth: .infinity, minHeight: Self.plotHeight + 24)
			} else {
				VStack(spacing: 0) {
					HStack(alignment: .bottom, spacing: 2) {
						ForEach(data) { d in
							column(d)
						}
					}
					Rectangle()
						.fill(Viz.gridline)
						.frame(height: 1)
					HStack(alignment: .top, spacing: 2) {
						ForEach(data) { d in
							Text(d.axisLabel ?? " ")
								.font(.system(size: 8))
								.foregroundStyle(Viz.mutedInk)
								.frame(maxWidth: .infinity)
								.lineLimit(1)
								.fixedSize(horizontal: false, vertical: true)
						}
					}
				}
			}
		}
	}

	@ViewBuilder
	private func column(_ d: BarDatum) -> some View {
		let ratio = CGFloat(d.value) / CGFloat(maxValue)
		let showLabel = hovered == d.id || (d.value == maxValue && d.value > 0 && hovered == nil)
		VStack(spacing: 1) {
			Text(showLabel ? "\(d.value)" : " ")
				.font(.system(size: 9))
				.foregroundStyle(.secondary)
				.lineLimit(1)
			UnevenRoundedRectangle(cornerRadii: .init(topLeading: 2, topTrailing: 2))
				.fill(d.color)
				.frame(height: d.value > 0 ? max(2, ratio * Self.plotHeight) : 0)
		}
		.frame(maxWidth: .infinity, alignment: .bottom)
		.frame(height: Self.plotHeight + 13, alignment: .bottom)
		.contentShape(Rectangle())
		.onHover { inside in
			if inside {
				hovered = d.id
			} else if hovered == d.id {
				hovered = nil
			}
		}
	}
}
