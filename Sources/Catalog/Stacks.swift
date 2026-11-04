import Foundation
import GRDB

/// A stack: photos folded under one thumbnail, as Lightroom's Group into
/// Stack and Auto-Stack by Capture Time make them. Bursts, brackets and the
/// frames of a panorama collapse to their top photo so the grid stays tidy
/// while culling, and expand again with S.
///
/// Stacks are the catalog's own (tables `stacks` and `stack_members`, added
/// by migration `stacks_v1_stack_tables`); they are not written to sidecars,
/// so a database rebuilt from the sidecars starts without them.
public struct ImageStack: Sendable, Equatable, Identifiable {
    public var id: Int64
    /// Image row ids, top of the stack first.
    public var memberIDs: [Int64]
    /// Collapsed, the grid shows the top photo alone, with the stack's count.
    public var isCollapsed: Bool

    public init(id: Int64, memberIDs: [Int64], isCollapsed: Bool) {
        self.id = id
        self.memberIDs = memberIDs
        self.isCollapsed = isCollapsed
    }

    public var topID: Int64? { memberIDs.first }
}

/// One photo's place in its stack, for the grid's badge and for laying out
/// the visible list.
public struct StackMembership: Sendable, Equatable {
    public var stackID: Int64
    /// 0 for the top of the stack.
    public var position: Int
    public var count: Int
    public var isCollapsed: Bool

    public var isTop: Bool { position == 0 }
}

enum StackSchema {
    static func migrate(_ db: Database) throws {
        try db.create(table: "stacks") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("collapsed", .boolean).notNull().defaults(to: true)
        }
        // One stack per photo at most. A photo leaving the catalog leaves
        // its stack with it; a stack left with fewer than two photos is
        // not read back as one (Catalog.allStacks).
        try db.create(table: "stack_members") { t in
            t.column("image_id", .integer).notNull().primaryKey().references("images", onDelete: .cascade)
            t.column("stack_id", .integer).notNull().references("stacks", onDelete: .cascade)
            t.column("position", .integer).notNull()
        }
        try db.create(index: "idx_stack_members_stack", on: "stack_members", columns: ["stack_id", "position"])
    }
}

/// How stacks shape the grid's list.
public enum StackLayout {
    /// Each stacked photo's place, by image id.
    public static func memberships(_ stacks: [ImageStack]) -> [Int64: StackMembership] {
        var result: [Int64: StackMembership] = [:]
        for stack in stacks {
            for (position, id) in stack.memberIDs.enumerated() {
                result[id] = StackMembership(stackID: stack.id, position: position, count: stack.memberIDs.count,
                                             isCollapsed: stack.isCollapsed)
            }
        }
        return result
    }

    /// The visible list with stacks applied to `sorted` (already filtered
    /// and sorted). A stack's photos stay together, in stack order, where
    /// the first of them falls in the sort. A collapsed stack shows one
    /// photo: its top, or, when a filter or collection hides the top, the
    /// highest of its photos that passed, so a filter never hides a whole
    /// stack that has a match in it.
    public static func arrange(_ sorted: [ImageRecord], memberships: [Int64: StackMembership]) -> [ImageRecord] {
        guard !memberships.isEmpty else { return sorted }
        var passing: [Int64: [ImageRecord]] = [:]
        for record in sorted {
            if let id = record.id, let member = memberships[id] { passing[member.stackID, default: []].append(record) }
        }
        guard !passing.isEmpty else { return sorted }
        func position(_ record: ImageRecord) -> Int { record.id.flatMap { memberships[$0]?.position } ?? 0 }
        var result: [ImageRecord] = []
        result.reserveCapacity(sorted.count)
        var placed = Set<Int64>()
        for record in sorted {
            guard let id = record.id, let member = memberships[id] else {
                result.append(record)
                continue
            }
            guard placed.insert(member.stackID).inserted else { continue }
            let group = (passing[member.stackID] ?? [record]).sorted { position($0) < position($1) }
            if member.isCollapsed {
                result.append(group[0])
            } else {
                result.append(contentsOf: group)
            }
        }
        return result
    }
}

/// The stack actions as changes of the whole list of stacks. Pure, so the
/// rules are tested without a catalog; the Library writes the result.
public enum StackEditing {
    /// The stack holding each photo, by image id.
    static func stackIDs(_ stacks: [ImageStack]) -> [Int64: Int64] {
        var result: [Int64: Int64] = [:]
        for stack in stacks { for id in stack.memberIDs { result[id] = stack.id } }
        return result
    }

    static func nextID(_ stacks: [ImageStack]) -> Int64 { (stacks.map(\.id).max() ?? 0) + 1 }

    /// Group into Stack: `ids` (in grid order) become one collapsed stack,
    /// with `top` on top when it is among them. A photo already in a stack
    /// brings its whole stack, as in Lightroom, so grouping merges stacks.
    public static func group(_ ids: [Int64], top: Int64?, in stacks: [ImageStack]) -> [ImageStack] {
        let owner = stackIDs(stacks)
        let byID = Dictionary(stacks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var members: [Int64] = []
        var seen = Set<Int64>()
        var absorbed = Set<Int64>()
        for id in ids {
            if let stackID = owner[id] {
                guard absorbed.insert(stackID).inserted, let stack = byID[stackID] else { continue }
                for member in stack.memberIDs where seen.insert(member).inserted { members.append(member) }
            } else if seen.insert(id).inserted {
                members.append(id)
            }
        }
        guard members.count >= 2 else { return stacks }
        if let top, let index = members.firstIndex(of: top) {
            members.remove(at: index)
            members.insert(top, at: 0)
        }
        let kept = stacks.filter { !absorbed.contains($0.id) }
        return kept + [ImageStack(id: nextID(stacks), memberIDs: members, isCollapsed: true)]
    }

    /// Unstack: every stack holding one of `ids` comes apart.
    public static func unstack(_ ids: Set<Int64>, in stacks: [ImageStack]) -> [ImageStack] {
        stacks.filter { $0.memberIDs.allSatisfy { !ids.contains($0) } }
    }

    /// Remove from Stack: `ids` leave their stacks; a stack left with one
    /// photo is no longer a stack.
    public static func remove(_ ids: Set<Int64>, from stacks: [ImageStack]) -> [ImageStack] {
        stacks.compactMap { stack in
            var stack = stack
            stack.memberIDs.removeAll { ids.contains($0) }
            return stack.memberIDs.count >= 2 ? stack : nil
        }
    }

    /// Move to Top of Stack.
    public static func moveToTop(_ id: Int64, in stacks: [ImageStack]) -> [ImageStack] {
        stacks.map { stack in
            guard let index = stack.memberIDs.firstIndex(of: id), index > 0 else { return stack }
            var stack = stack
            stack.memberIDs.remove(at: index)
            stack.memberIDs.insert(id, at: 0)
            return stack
        }
    }

    /// Collapses or expands the stacks `stackIDs` (all of them when nil);
    /// a nil `collapsed` turns each the other way.
    public static func setCollapsed(_ collapsed: Bool?, stackIDs: Set<Int64>?, in stacks: [ImageStack]) -> [ImageStack] {
        stacks.map { stack in
            guard stackIDs?.contains(stack.id) ?? true else { return stack }
            var stack = stack
            stack.isCollapsed = collapsed ?? !stack.isCollapsed
            return stack
        }
    }

    /// Adds the photo `id` to the stack of `source`, just above or below it,
    /// or makes the two a stack when `source` has none. The stack is left
    /// expanded so the new photo shows. Used for exports added to the
    /// catalog with their original.
    public static func add(_ id: Int64, besides source: Int64, above: Bool, in stacks: [ImageStack]) -> [ImageStack] {
        guard id != source else { return stacks }
        var result = remove([id], from: stacks)
        if let index = result.firstIndex(where: { $0.memberIDs.contains(source) }),
           let position = result[index].memberIDs.firstIndex(of: source) {
            result[index].memberIDs.insert(id, at: above ? position : position + 1)
            result[index].isCollapsed = false
        } else {
            result.append(ImageStack(id: nextID(result), memberIDs: above ? [id, source] : [source, id],
                                     isCollapsed: false))
        }
        return result
    }

    /// Auto-Stack by Capture Time: `records` taken no more than `gap`
    /// seconds after the one before become collapsed stacks, earliest on
    /// top. Photos already in a stack, and photos without a capture time,
    /// are left alone. Returns the new list and how many stacks it added.
    public static func autoStack(_ records: [ImageRecord], gap: TimeInterval,
                                 in stacks: [ImageStack]) -> (stacks: [ImageStack], added: Int) {
        let owner = stackIDs(stacks)
        let candidates = records
            .compactMap { record -> (id: Int64, time: Int64, path: String)? in
                guard let id = record.id, owner[id] == nil, let time = record.captureTime else { return nil }
                return (id, time, record.relPath)
            }
            .sorted { $0.time != $1.time ? $0.time < $1.time : $0.path < $1.path }
        var result = stacks
        var nextID = nextID(stacks)
        var added = 0
        var run: [Int64] = []
        var lastTime: Int64?
        let limit = max(gap, 0)
        for candidate in candidates {
            if let lastTime, Double(candidate.time - lastTime) > limit {
                if run.count >= 2 {
                    result.append(ImageStack(id: nextID, memberIDs: run, isCollapsed: true))
                    nextID += 1
                    added += 1
                }
                run = []
            }
            run.append(candidate.id)
            lastTime = candidate.time
        }
        if run.count >= 2 {
            result.append(ImageStack(id: nextID, memberIDs: run, isCollapsed: true))
            added += 1
        }
        return (result, added)
    }
}
