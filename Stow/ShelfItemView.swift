import AppKit
import SwiftUI

/// The SwiftUI view drawn inside each shelf cell: thumbnail plus filename.
///
/// It is display-only. Clicks, selection, dragging and the right-click menu are all
/// handled by the AppKit collection view around it (see ShelfCollectionView).
struct ShelfItemView: View {
    let item: ShelfItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ShelfThumbnail(item: item)
                // Cells get reused for different items. A new id gives the thumbnail
                // fresh @State, so a reused cell never flashes the previous item's image.
                .id(item.id)
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
