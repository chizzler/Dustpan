import Testing
@testable import DustpanCore

// OpenSpec subtasks, "Parent progress" and "Completing a parent". A port of tests/test_model.py's ProgressTest.

private func task(_ id: String, _ parent: String? = nil, done: JSON = nil, deleted: JSON = nil) -> Row {
    Row(id: id, values: ["parent_id": parent.map(JSON.string) ?? nil, "completed_at": done, "deleted_at": deleted])
}

@Suite struct ProgressTests {
    @Test func countsDirectLiveSubtasks() {
        let tasks = [task("trip"), task("a", "trip", done: "t1"), task("b", "trip", done: "t2"),
                     task("c", "trip", done: "t3"), task("d", "trip"), task("e", "trip"),
                     task("gone", "trip", deleted: "t4"), task("grand", "a", done: "t5"), task("solo")]
        let progress = progressMap(tasks)
        #expect(progress["trip"] == SubtaskProgress(done: 3, total: 5))
        #expect(progress["a"] == SubtaskProgress(done: 1, total: 1))
        #expect(progress["solo"] == nil)
        #expect(progress["trip"]?.text == "3 of 5 subtasks completed")
    }

    @Test func sweptSubtasksStillCount() {
        let tasks = [task("trip"), task("a", "trip", done: "t1"), task("b", "trip", done: "t2"), task("c", "trip")]
        let progress = progressMap(tasks, cleared: ["a": ["t1", "trip"], "b": ["older", "trip"]])
        #expect(progress["trip"] == SubtaskProgress(done: 2, total: 3, swept: 1))
        #expect(progress["trip"]?.text == "2 of 3 subtasks completed (1 swept)")
        #expect(SubtaskProgress(done: 0, total: 1).text == "0 of 1 subtask completed")
    }

    @Test func readyParentAfterTheLastOpenSubtask() {
        var tasks = Dictionary(uniqueKeysWithValues: [task("trip"), task("a", "trip", done: "t1"),
                                                      task("b", "trip", done: "t2"), task("gone", "trip", deleted: "t3"),
                                                      task("top", done: "t4")].map { ($0.id, $0) })
        #expect(readyParent("b", tasks: tasks)?.id == "trip")
        #expect(readyParent("top", tasks: tasks) == nil)
        tasks["c"] = task("c", "trip")
        #expect(readyParent("b", tasks: tasks) == nil)
    }

    @Test func noOfferForADoneOrDeletedParent() {
        for parent in [task("trip", done: "t0"), task("trip", deleted: "t0")] {
            let tasks = Dictionary(uniqueKeysWithValues: [parent, task("a", "trip", done: "t1")].map { ($0.id, $0) })
            #expect(readyParent("a", tasks: tasks) == nil)
        }
    }
}
