import AppKit
import Foundation
import Testing
@testable import Stow

/// Stacks, filtering, reordering, pinning and clearing: the shelf's rules, checked on
/// plain text items so no files are needed.
struct ShelfRowTests {
    private let stack = UUID()

    private func item(_ name: String, in stackID: UUID? = nil, named stackName: String? = nil) -> ShelfItem {
        ShelfItem(content: .text(name), stackID: stackID, stackName: stackName)
    }

    @Test func looseItemsAreRowsOfTheirOwn() {
        let rows = ShelfRow.rows(for: [item("a"), item("b")], expanded: [], filter: "")
        #expect(rows.map(\.isStack) == [false, false])
        #expect(rows.count == 2)
    }

    @Test func aClosedStackIsOneRow() {
        let items = [item("a", in: stack), item("b", in: stack), item("c", in: stack), item("d")]
        let rows = ShelfRow.rows(for: items, expanded: [], filter: "")
        #expect(rows.count == 2)
        #expect(rows[0].isStack)
        #expect(rows[0].items.count == 3)
    }

    @Test func anOpenStackListsItsMembers() {
        let items = [item("a", in: stack), item("b", in: stack)]
        let rows = ShelfRow.rows(for: items, expanded: [stack], filter: "")
        #expect(rows.count == 3)
        #expect(rows[0].isStack)
        #expect(rows[1].isMember && rows[2].isMember)
    }

    @Test func aStackOfOneIsAnOrdinaryItem() {
        let rows = ShelfRow.rows(for: [item("a", in: stack)], expanded: [], filter: "")
        #expect(rows.count == 1)
        #expect(!rows[0].isStack && !rows[0].isMember)
    }

    @Test func filteringShowsMatchingMembersOfAStack() {
        let items = [item("Report.pdf", in: stack), item("photo.jpg", in: stack), item("notes")]
        let rows = ShelfRow.rows(for: items, expanded: [], filter: "report")
        #expect(rows.count == 2)
        #expect(rows[0].isStack)
        #expect(rows[1].items.first?.displayName == "Report.pdf")
    }

    @Test func filteringByAStacksNameShowsAllOfIt() {
        let items = [item("a", in: stack, named: "Tax docs"), item("b", in: stack, named: "Tax docs")]
        let rows = ShelfRow.rows(for: items, expanded: [], filter: "tax")
        #expect(rows.count == 3)
        #expect(rows[0].stackName == "Tax docs")
    }
}

struct ShelfViewModelTests {
    private let defaults: UserDefaults
    private let settings: AppSettings

    init() {
        let suite = "StowTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        settings = AppSettings(defaults: defaults)
    }

    private func names(_ viewModel: ShelfViewModel) -> [String] {
        viewModel.items.map(\.displayName)
    }

    private func viewModel(_ items: [ShelfItem]) -> ShelfViewModel {
        let viewModel = ShelfViewModel(settings: settings)
        viewModel.loadSaved(items)
        return viewModel
    }

    @Test func reorderMovesItemsBeforeTheTarget() {
        let a = ShelfItem(content: .text("a"))
        let b = ShelfItem(content: .text("b"))
        let c = ShelfItem(content: .text("c"))
        let model = viewModel([a, b, c])
        model.reorder([c.id], before: a.id, detaching: [])
        #expect(names(model) == ["c", "a", "b"])
        model.reorder([c.id], before: nil, detaching: [])
        #expect(names(model) == ["a", "b", "c"])
    }

    @Test func reorderingAMemberOutTakesItOutOfTheStack() {
        let stack = UUID()
        let a = ShelfItem(content: .text("a"), stackID: stack)
        let b = ShelfItem(content: .text("b"), stackID: stack)
        let c = ShelfItem(content: .text("c"))
        let model = viewModel([a, b, c])
        model.reorder([a.id], before: nil, detaching: [a.id])
        #expect(names(model) == ["b", "c", "a"])
        #expect(model.items.last?.stackID == nil)
    }

    @Test func stackingGathersItemsTogether() {
        let a = ShelfItem(content: .text("a"))
        let b = ShelfItem(content: .text("b"))
        let c = ShelfItem(content: .text("c"))
        let model = viewModel([a, b, c])
        model.stack([a.id, c.id])
        #expect(names(model) == ["a", "c", "b"])
        #expect(model.items[0].stackID != nil)
        #expect(model.items[0].stackID == model.items[1].stackID)
        model.unstack([a.id, c.id])
        #expect(model.items.allSatisfy { $0.stackID == nil })
    }

    @Test func renamingAStackNamesEveryMember() {
        let stack = UUID()
        let model = viewModel([ShelfItem(content: .text("a"), stackID: stack), ShelfItem(content: .text("b"), stackID: stack)])
        model.renameStack(stack, to: "  Tax docs ")
        #expect(model.items.allSatisfy { $0.stackName == "Tax docs" })
        model.renameStack(stack, to: "")
        #expect(model.items.allSatisfy { $0.stackName == nil })
    }

    @Test func leavingAStackForgetsItsName() {
        var item = ShelfItem(content: .text("a"), stackID: UUID(), stackName: "Named")
        item.stackID = nil
        #expect(item.stackName == nil)
    }

    @Test func clearKeepsPinnedItems() {
        let a = ShelfItem(content: .text("a"), isPinned: true)
        let b = ShelfItem(content: .text("b"))
        let model = viewModel([a, b])
        model.clear()
        #expect(names(model) == ["a"])
    }

    @Test func pinnedItemsStayAfterBeingCopiedOutButNotMoved() {
        settings.removeAfterDrag = true
        let pinned = ShelfItem(content: .text("pinned"), isPinned: true)
        let loose = ShelfItem(content: .text("loose"))
        let model = viewModel([pinned, loose])
        model.finishDragOut(of: [pinned.id, loose.id], operation: .copy)
        #expect(names(model) == ["pinned"])
        model.finishDragOut(of: [pinned.id], operation: .move)
        #expect(model.items.isEmpty)
    }

    @Test func cancelledDragsRemoveNothing() {
        let a = ShelfItem(content: .text("a"))
        let model = viewModel([a])
        model.finishDragOut(of: [a.id], operation: [])
        #expect(names(model) == ["a"])
    }

    @Test func quickActionResultsGoAfterTheWholeStack() {
        let stack = UUID()
        let a = ShelfItem(content: .text("a"), stackID: stack)
        let b = ShelfItem(content: .text("b"), stackID: stack)
        let c = ShelfItem(content: .text("c"))
        let model = viewModel([a, b, c])
        let made = URL(filePath: "/tmp/made.zip")
        model.addStowCopies([made], after: a.id)
        #expect(names(model) == ["a", "b", "made.zip", "c"])
        #expect(model.items[2].stackID == nil)
    }
}
