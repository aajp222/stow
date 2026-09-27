import AppKit
import SwiftUI

/// The SwiftUI view drawn inside each row of the shelf: a preview plus a name, or for
/// a stack, a little pile of previews and how many items it holds.
///
/// It is display-only. Clicks, selection, dragging, the ✕ and the right-click menu are
/// all handled by the AppKit list around it (see ShelfCollectionView), and VoiceOver
/// reads the row itself (see ShelfItemCell), so this view is hidden from it.
struct ShelfItemView: View {
    let row: ShelfRow
    let isSelected: Bool
    let isHovered: Bool
    let isExpanded: Bool

    var body: some View {
        VStack(spacing: 4) {
            preview
                .frame(width: 64, height: 64)
            title
                .font(.system(size: 11))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(background)
        }
        .overlay(alignment: .topLeading) {
            if isHovered {
                RemoveBadge()
                    .padding(4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if row.isPinned {
                PinBadge()
                    .padding(5)
            }
        }
        .accessibilityHidden(true)
    }

    private var background: Color {
        if isSelected {
            Color.accentColor.opacity(0.28)
        } else if row.isMember {
            // A faint tint marks the rows that belong to an open stack.
            Color.primary.opacity(0.06)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var preview: some View {
        switch row {
        case .item(let item), .member(let item, _):
            ItemPreview(item: item, side: 64)
        case .stack(_, let members):
            StackPreview(members: members)
        }
    }

    @ViewBuilder private var title: some View {
        switch row {
        case .item(let item), .member(let item, _):
            Text(item.displayName)
        case .stack(_, let members):
            HStack(spacing: 3) {
                Text(row.stackName ?? "\(members.count) items")
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The picture for one item: its thumbnail, a text card or a link badge.
private struct ItemPreview: View {
    let item: ShelfItem
    let side: CGFloat

    var body: some View {
        switch item.content {
        case .file:
            ShelfThumbnail(item: item, side: side)
                // Cells get reused for different items. A new id gives the thumbnail
                // fresh @State, so a reused cell never flashes the previous item's image.
                .id(item.id)
        case .text(let text):
            TextCard(text: text)
        case .link:
            LinkBadge()
        }
    }
}

/// A stack: up to three of its items fanned out on top of each other, with a count.
private struct StackPreview: View {
    let members: [ShelfItem]

    private static let angles: [Double] = [0, -8, 8]
    private static let offsets: [CGFloat] = [0, -5, 5]

    var body: some View {
        let shown = Array(members.prefix(3).enumerated())
        ZStack {
            // Drawn back to front, so the first item ends up on top.
            ForEach(shown.reversed(), id: \.element.id) { entry in
                ItemPreview(item: entry.element, side: 50)
                    .frame(width: 50, height: 50)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .rotationEffect(.degrees(Self.angles[entry.offset]))
                    .offset(x: Self.offsets[entry.offset])
            }
        }
        .frame(width: 64, height: 64)
        .overlay(alignment: .bottomTrailing) {
            Text("\(members.count)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Color.accentColor, in: Capsule())
        }
    }
}

/// The ✕ shown in a row's corner while the pointer is over it. Clicks on it are
/// caught by ShelfCollectionView (see ShelfLayout.removeButtonRect).
private struct RemoveBadge: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
    }
}

/// The pin shown in a pinned item's corner.
private struct PinBadge: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .rotationEffect(.degrees(45))
    }
}

/// A little note card showing the start of the text, like a text clipping.
private struct TextCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 7))
            .foregroundStyle(.black.opacity(0.75))
            .lineLimit(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(5)
            .background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            .padding(.horizontal, 6)
    }
}

/// A round accent-coloured badge with a link symbol.
private struct LinkBadge: View {
    var body: some View {
        Image(systemName: "link")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(Color.accentColor.gradient, in: Circle())
    }
}

private struct ShelfThumbnail: View {
    let item: ShelfItem
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? ThumbnailProvider.shared.icon(for: item))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .task {
                thumbnail = await ThumbnailProvider.shared.thumbnail(
                    for: item,
                    size: CGSize(width: side, height: side),
                    scale: displayScale
                )
            }
    }
}
