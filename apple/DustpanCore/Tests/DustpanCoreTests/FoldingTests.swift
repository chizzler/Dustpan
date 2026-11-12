import Testing
@testable import DustpanCore

@Suite struct Folding {
    let tasks: [String: Row] = Dictionary(uniqueKeysWithValues: [
        ("a", nil), ("b", "a"), ("c", "b"), ("x", nil), ("loop1", "loop2"), ("loop2", "loop1"),
    ].map { ($0.0, task($0.0, ["parent_id": $0.1.map(JSON.string) ?? nil])) })

    @Test func keepsTheOrderAndForgetsGoneTasks() {
        #expect(foldedAfter([], "a", fold: true, tasks: tasks) == ["a"])
        #expect(foldedAfter(["x", "gone", "a"], "b", fold: true, tasks: tasks) == ["x", "a", "b"])
        #expect(foldedAfter(["x", "a"], "a", fold: true, tasks: tasks) == ["x", "a"])
        #expect(foldedAfter(["x", "a"], "a", fold: false, tasks: tasks) == ["x"])
        #expect(foldedAfter(["x"], "gone", fold: true, tasks: tasks) == ["x"])
    }

    @Test func unfoldsTheWayDownToANewParentOnly() {
        #expect(unfoldedDownTo(["a", "b", "c", "x"], "b", tasks: tasks) == ["c", "x"])
        #expect(unfoldedDownTo(["a", "x"], nil, tasks: tasks) == ["a", "x"])
        #expect(unfoldedDownTo(["loop1", "x"], "loop2", tasks: tasks) == ["x"])
    }
}
