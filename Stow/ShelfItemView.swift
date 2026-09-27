import AppKit
import SwiftUI

/// The SwiftUI view drawn inside each shelf cell: a preview plus a name.
///
/// It is display-only. Clicks, selection, dragging and the right-click menu are all
/// handled by the AppKit collection view around it (see ShelfCollectionView).
struct ShelfItemView: View {
    let item: ShelfItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            preview
                .frame(width: 64, height: 64)
            Text(item.displayName)
                .font(.system(size: 11))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.clear)
        }
    }
}

private extension ShelfItemView {
    @ViewBuilder var preview: some View {
        switch item.content {
        case .file:
            ShelfThumbnail(item: item)
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

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? ThumbnailProvider.shared.icon(for: item))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .task {
                thumbnail = await ThumbnailProvider.shared.thumbnail(
                    for: item,
                    size: CGSize(width: 64, height: 64),
                    scale: displayScale
                )
            }
    }
}
