import Foundation

/// One row of the shelf's list, built from the items.
///
/// Items that share a stack ID sit next to each other in `ShelfViewModel.items` and
/// show as a single stack row. While the stack is fanned open, one member row per
/// item follows it. A "stack" of just one item shows as an ordinary row.
enum ShelfRow: Equatable {
    case item(ShelfItem)
    case stack(id: UUID, members: [ShelfItem])
    case member(ShelfItem, stackID: UUID)

    /// A stable identity for the row, used to keep it selected across reloads.
    var id: UUID {
        switch self {
        case .item(let item), .member(let item, _): item.id
        case .stack(let id, _): id
        }
    }

    /// The items the row stands for. A stack row stands for all of its members.
    var items: [ShelfItem] {
        switch self {
        case .item(let item), .member(let item, _): [item]
        case .stack(_, let members): members
        }
    }

    var isStack: Bool {
        if case .stack = self { true } else { false }
    }

    var isMember: Bool {
        if case .member = self { true } else { false }
    }

    /// Builds the rows for `items`. Stacks in `expanded` are fanned open. A non-empty
    /// `filter` keeps only items whose name contains it; a stack with matching
    /// members shows those members fanned open.
    static func rows(for items: [ShelfItem], expanded: Set<UUID>, filter: String) -> [ShelfRow] {
        func matches(_ item: ShelfItem) -> Bool {
            filter.isEmpty || item.displayName.localizedStandardContains(filter)
        }

        var rows: [ShelfRow] = []
        var index = items.startIndex
        while index < items.endIndex {
            let item = items[index]
            guard let stackID = item.stackID else {
                if matches(item) {
                    rows.append(.item(item))
                }
                index += 1
                continue
            }
            // The run of items sharing this stack ID.
            var members: [ShelfItem] = []
            while index < items.endIndex, items[index].stackID == stackID {
                members.append(items[index])
                index += 1
            }
            if members.count == 1 {
                if matches(item) {
                    rows.append(.item(item))
                }
                continue
            }
            let shown = members.filter(matches)
            guard !shown.isEmpty else { continue }
            rows.append(.stack(id: stackID, members: members))
            if expanded.contains(stackID) || !filter.isEmpty {
                rows += shown.map { .member($0, stackID: stackID) }
            }
        }
        return rows
    }
}
