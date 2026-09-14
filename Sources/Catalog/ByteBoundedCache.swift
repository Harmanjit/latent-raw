import Foundation

/// A least-recently-used cache that holds at most `budget` bytes.
///
/// NSCache was used for thumbnails before, with a count limit and no
/// cost, so a scroll through a big folder could keep well over a gigabyte
/// of decoded pixels. NSCache's eviction is also left to the system and
/// can't be tested; this one evicts in a fixed order (the entry used
/// longest ago goes first), so the budget is a promise.
///
/// Not thread-safe: the owner holds a lock around it.
final class ByteBoundedCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        /// Towards the most recently used end.
        var newer: Node?
        /// Towards the least recently used end.
        var older: Node?

        init(key: Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private var nodes: [Key: Node] = [:]
    private var newest: Node?
    private var oldest: Node?

    /// The most bytes kept. Lowering it evicts straight away.
    var budget: Int {
        didSet { evict(downTo: budget) }
    }
    private(set) var totalCost = 0
    var count: Int { nodes.count }

    init(budget: Int) {
        self.budget = max(0, budget)
    }

    /// The value, which also becomes the most recently used entry.
    func value(forKey key: Key) -> Value? {
        guard let node = nodes[key] else { return nil }
        moveToNewest(node)
        return node.value
    }

    /// Whether `key` is cached, without touching its recency.
    func contains(_ key: Key) -> Bool { nodes[key] != nil }

    /// Stores `value`, evicting the least recently used entries until the
    /// total fits. A value larger than the whole budget isn't kept at all,
    /// rather than emptying the cache for something that can't fit.
    func insert(_ value: Value, forKey key: Key, cost: Int) {
        let cost = max(0, cost)
        remove(key)
        guard cost <= budget else { return }
        let node = Node(key: key, value: value, cost: cost)
        nodes[key] = node
        link(asNewest: node)
        totalCost += cost
        evict(downTo: budget)
    }

    func remove(_ key: Key) {
        guard let node = nodes.removeValue(forKey: key) else { return }
        unlink(node)
        totalCost -= node.cost
    }

    func removeAll(where shouldRemove: (Key) -> Bool) {
        for key in nodes.keys where shouldRemove(key) { remove(key) }
    }

    func removeAll() {
        nodes.removeAll()
        newest = nil
        oldest = nil
        totalCost = 0
    }

    /// Evicts the least recently used entries until at most `bytes` remain.
    func evict(downTo bytes: Int) {
        while totalCost > bytes, let victim = oldest {
            remove(victim.key)
        }
    }

    /// Keys from most to least recently used, for tests.
    var keysByRecency: [Key] {
        var keys: [Key] = []
        var node = newest
        while let current = node {
            keys.append(current.key)
            node = current.older
        }
        return keys
    }

    // MARK: - List

    private func link(asNewest node: Node) {
        node.older = newest
        node.newer = nil
        newest?.newer = node
        newest = node
        if oldest == nil { oldest = node }
    }

    private func unlink(_ node: Node) {
        if let newer = node.newer { newer.older = node.older } else { newest = node.older }
        if let older = node.older { older.newer = node.newer } else { oldest = node.newer }
        node.newer = nil
        node.older = nil
    }

    private func moveToNewest(_ node: Node) {
        guard newest !== node else { return }
        unlink(node)
        link(asNewest: node)
    }
}
