import SwiftUI

struct WrappingHStack<Content: View>: View {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 6
    @ViewBuilder var content: () -> Content

    var body: some View {
        WrappingHStackLayout(horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing) {
            content()
        }
    }
}

private struct WrappingHStackLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    struct Item {
        let index: Int
        let size: CGSize
    }

    struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = availableWidth(from: proposal, subviews: subviews)
        let rows = makeRows(subviews: subviews, maxWidth: width)
        let height = rows.reduce(CGFloat.zero) { total, row in
            total + row.height
        } + CGFloat(max(rows.count - 1, 0)) * verticalSpacing
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = makeRows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = CGSize(width: min(item.size.width, bounds.width), height: item.size.height)
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func availableWidth(from proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        if let width = proposal.width, width.isFinite, width > 0 {
            return width
        }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let contentWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width }
            + CGFloat(max(sizes.count - 1, 0)) * horizontalSpacing
        return max(contentWidth, 1)
    }

    private func makeRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        let maxWidth = max(maxWidth, 1)
        var rows: [Row] = []
        var row = Row()

        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            size.width = min(size.width, maxWidth)
            let proposedWidth = row.items.isEmpty
                ? size.width
                : row.width + horizontalSpacing + size.width

            if !row.items.isEmpty, proposedWidth > maxWidth {
                rows.append(row)
                row = Row()
            }

            row.items.append(Item(index: index, size: size))
            row.width = row.items.count == 1 ? size.width : row.width + horizontalSpacing + size.width
            row.height = max(row.height, size.height)
        }

        if !row.items.isEmpty {
            rows.append(row)
        }
        return rows
    }
}
