import Foundation

/// One ancestor of a removed node, paired with the rebuilt node that replaces it.
///
/// `DiskNode` is immutable, so shrinking a directory means constructing a new one;
/// callers that key state off node identity (the expanded-rows set, the breadcrumb
/// stack, the treemap layout cache) need this pairing to carry that state across.
public struct DiskNodeReplacement: Sendable {
    public let old: DiskNode
    public let new: DiskNode

    public init(old: DiskNode, new: DiskNode) {
        self.old = old
        self.new = new
    }
}

/// The result of pruning one node out of a scanned tree: a new root whose every
/// affected directory has already been resized, plus the ancestor pairings needed
/// to move UI state onto it.
public struct DiskTreeRemoval: Sendable {
    public let root: DiskNode
    public let removed: DiskNode
    /// Root first, immediate parent last — the order the tree cache relies on when
    /// it re-points children at their rebuilt parents.
    public let replacedAncestors: [DiskNodeReplacement]

    public init(root: DiskNode, removed: DiskNode, replacedAncestors: [DiskNodeReplacement]) {
        self.root = root
        self.removed = removed
        self.replacedAncestors = replacedAncestors
    }
}

/// Pure tree surgery for "this item is no longer on disk".
///
/// Kept entirely free of AppKit, the filesystem and the view so the arithmetic that
/// keeps the displayed totals honest can be tested directly. Only the chain from the
/// root down to the removed node is rebuilt; every other subtree is carried over by
/// reference, which keeps the operation proportional to the tree's depth rather than
/// its size and lets identity-keyed caches survive untouched.
public enum DiskTreeMutator {
    /// Removes `node` from the tree rooted at `root`, shrinking every ancestor.
    /// Returns nil when `node` is the root itself (a scan has to keep its root) or
    /// is not in this tree at all.
    public static func removing(_ node: DiskNode, from root: DiskNode) -> DiskTreeRemoval? {
        guard let path = ancestorPath(to: node, from: root) else { return nil }
        return removing(nodeAt: path)
    }

    /// Removes the last node of `path`, where `path` runs from the tree's root down
    /// to the doomed node. The view takes this overload because its tree index
    /// already knows every node's ancestry, so the search below can be skipped.
    public static func removing(nodeAt path: [DiskNode]) -> DiskTreeRemoval? {
        // A single-element path is the root, which has no parent to remove it from.
        guard path.count >= 2, let removed = path.last else { return nil }

        var replacements: [DiskNodeReplacement] = []
        var child = removed
        // Nil until the first rebuild, which is what distinguishes "drop this child"
        // (the removed node) from "swap this child for its resized rebuild".
        var rebuiltChild: DiskNode?

        for index in stride(from: path.count - 2, through: 0, by: -1) {
            let parent = path[index]
            guard let slot = parent.children.firstIndex(where: { $0 === child }) else {
                // The supplied path does not describe this tree; refuse rather than
                // hand back a tree whose sizes no longer add up.
                return nil
            }

            var children = parent.children
            if let rebuiltChild {
                children[slot] = rebuiltChild
            } else {
                children.remove(at: slot)
            }
            // The scanner hands back children biggest-first, and both the treemap's
            // squarify pass and the tree pane read that order as meaningful. A
            // shrunken directory can easily be smaller than the sibling that used to
            // sit below it, so the order is restored rather than left lying.
            children.sort { $0.size > $1.size }

            let rebuiltParent = DiskNode(
                path: parent.path,
                name: parent.name,
                isDirectory: parent.isDirectory,
                size: reducing(parent.size, by: removed.size),
                children: children,
                isSynthetic: parent.isSynthetic
            )

            replacements.append(DiskNodeReplacement(old: parent, new: rebuiltParent))
            child = parent
            rebuiltChild = rebuiltParent
        }

        guard let newRoot = rebuiltChild else { return nil }

        return DiskTreeRemoval(
            root: newRoot,
            removed: removed,
            replacedAncestors: replacements.reversed()
        )
    }

    /// The chain of nodes from `root` down to `node`, or nil if `node` is not in the
    /// tree. Matching is by object identity, not by path string: the reconciliation
    /// placeholder deliberately shares the root's path, so a string comparison could
    /// pick the wrong node.
    static func ancestorPath(to node: DiskNode, from root: DiskNode) -> [DiskNode]? {
        if node === root { return [root] }

        for child in root.children {
            if let tail = ancestorPath(to: node, from: child) {
                return [root] + tail
            }
        }

        return nil
    }

    /// A directory's size is the sum of what the scanner attributed to its children,
    /// so subtracting the removed subtree is exact. The floor is only there so a tree
    /// that somehow disagrees with itself can't wrap UInt64 around into an
    /// astronomically wrong total on screen.
    private static func reducing(_ size: UInt64, by amount: UInt64) -> UInt64 {
        size > amount ? size - amount : 0
    }
}

/// Moves the analyzer's identity-keyed navigation state onto a tree that has just
/// had a node pruned out of it. Pure so the awkward cases — trashing the folder you
/// are currently looking at, trashing an ancestor of the highlighted row — are
/// testable without a running view.
enum DiskTreeNavigationPatch {
    static func replacementMap(for replacements: [DiskNodeReplacement]) -> [ObjectIdentifier: DiskNode] {
        var map: [ObjectIdentifier: DiskNode] = [:]
        for replacement in replacements {
            map[replacement.old.id] = replacement.new
        }
        return map
    }

    /// The new breadcrumb stack. If the removed node is on the current path then the
    /// user was standing inside (or on) something that no longer exists, so the walk
    /// stops at its parent; otherwise the stack keeps its shape and only swaps in the
    /// rebuilt ancestors.
    static func patchedPath(
        _ stack: [DiskNode],
        removing removed: DiskNode,
        using replacements: [ObjectIdentifier: DiskNode],
        fallbackRoot: DiskNode
    ) -> [DiskNode] {
        var kept = stack
        if let index = kept.firstIndex(where: { $0 === removed }) {
            kept = Array(kept.prefix(index))
        }

        let patched = kept.map { replacements[$0.id] ?? $0 }
        // The stack must never be empty: it is what the treemap draws from.
        return patched.isEmpty ? [fallbackRoot] : patched
    }

    /// Carries the expanded-rows set across the rebuild, so a folder the user had
    /// open does not silently collapse because its object was replaced.
    static func patchedExpansion(
        _ expanded: Set<ObjectIdentifier>,
        using replacements: [DiskNodeReplacement]
    ) -> Set<ObjectIdentifier> {
        var patched = expanded
        for replacement in replacements where patched.contains(replacement.old.id) {
            patched.remove(replacement.old.id)
            patched.insert(replacement.new.id)
        }
        return patched
    }

    /// The hovered/focused row after the rebuild: gone if the removal put it out of
    /// the tree, otherwise remapped so the highlight follows a rebuilt ancestor.
    ///
    /// Testing identity against `removed` alone is not enough, because everything
    /// *underneath* the removed node left the tree with it. A descendant left in
    /// place would keep the action bar enabled and the hover chip drawn for a row the
    /// tree has already forgotten, and ⌘⌫ would then raise a real "Move to the Trash?"
    /// confirmation for a file that is already in the Trash — or, worse, for whatever
    /// has since been written to that path. `survivesRemoval` is how the caller's
    /// index answers "is this still in the tree?" in constant time; walking the
    /// removed subtree to find out would cost as much as the trashed folder is big.
    static func patchedSelection(
        _ selection: DiskNode?,
        removing removed: DiskNode,
        using replacements: [ObjectIdentifier: DiskNode],
        survivesRemoval: (DiskNode) -> Bool
    ) -> DiskNode? {
        guard let selection else { return nil }
        if selection === removed { return nil }
        let patched = replacements[selection.id] ?? selection
        return survivesRemoval(patched) ? patched : nil
    }
}
