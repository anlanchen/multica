import XCTest
@testable import MulticaCore

final class IssueModalTests: XCTestCase {
    func testRunGateAssignConfirmsUnlessParkedInBacklog() {
        let agent = ActorRef(type: "agent", id: "a1")
        let intent = IssueModalRunGate.intent(issueID: "i", status: "todo", statusCategory: nil, assignee: nil,
                                              newAssignee: agent, newStatus: nil, catalog: nil)
        XCTAssertEqual(intent?.mode, .assign)
        XCTAssertEqual(intent?.assigneeID, "a1")
        XCTAssertNil(IssueModalRunGate.intent(issueID: "i", status: "backlog", statusCategory: nil, assignee: nil,
                                              newAssignee: agent, newStatus: nil, catalog: nil))
        XCTAssertNil(IssueModalRunGate.intent(issueID: "i", status: "todo", statusCategory: nil, assignee: nil,
                                              newAssignee: ActorRef(type: "member", id: "u"), newStatus: nil, catalog: nil))
    }

    func testRunGatePromotesOwnedBacklogIssueToActiveStatus() {
        let squad = ActorRef(type: "squad", id: "s1")
        let promote = IssueModalRunGate.intent(issueID: "i", status: "backlog", statusCategory: .unstarted, assignee: squad,
                                               newAssignee: nil, newStatus: "in_progress", catalog: nil)
        XCTAssertEqual(promote?.mode, .promote)
        XCTAssertEqual(promote?.status, "in_progress")
        XCTAssertEqual(promote?.assigneeType, "squad")
        XCTAssertNil(IssueModalRunGate.intent(issueID: "i", status: "backlog", statusCategory: nil, assignee: squad,
                                              newAssignee: nil, newStatus: "done", catalog: nil))
        XCTAssertNil(IssueModalRunGate.intent(issueID: "i", status: "todo", statusCategory: nil, assignee: squad,
                                              newAssignee: nil, newStatus: "in_progress", catalog: nil))
        let unknownTarget = IssueModalRunGate.intent(issueID: "i", status: "backlog", statusCategory: nil, assignee: squad,
                                                     newAssignee: nil, newStatus: "custom_later", catalog: nil)
        XCTAssertEqual(unknownTarget?.mode, .promote, "an unresolvable target fails toward confirming")
        let unknownSource = IssueModalRunGate.intent(issueID: "i", status: "custom_x", statusCategory: nil, assignee: squad,
                                                     newAssignee: nil, newStatus: "todo", catalog: nil)
        XCTAssertEqual(unknownSource?.mode, .promote)
    }

    func testRunGateResolvesCustomStatusesThroughTheCatalog() {
        let catalog = StatusCatalog([IssueStatusEntry(id: "1", key: "shipped", name: "Shipped", category: .done, isSystem: false)])
        XCTAssertEqual(IssueModalRunGate.category(statusKey: "shipped", carried: nil, catalog: catalog), .done)
        XCTAssertEqual(IssueModalRunGate.category(statusKey: "todo", carried: nil, catalog: nil), .unstarted)
        XCTAssertNil(IssueModalRunGate.category(statusKey: "mystery", carried: nil, catalog: catalog))
        XCTAssertNil(IssueModalRunGate.intent(issueID: "i", status: "backlog", statusCategory: nil, assignee: ActorRef(type: "agent", id: "a"),
                                              newAssignee: nil, newStatus: "shipped", catalog: catalog))
    }

    func testCLIVersionGate() {
        XCTAssertEqual(IssueModalCLIVersion.check("0.2.21", minimum: IssueModalCLIVersion.minQuickCreate).state, .ok)
        XCTAssertEqual(IssueModalCLIVersion.check("v0.4.10", minimum: IssueModalCLIVersion.minQuickCreateFields).state, .ok)
        XCTAssertEqual(IssueModalCLIVersion.check("0.2.20", minimum: IssueModalCLIVersion.minQuickCreate).state, .tooOld)
        XCTAssertEqual(IssueModalCLIVersion.check("0.4.2", minimum: IssueModalCLIVersion.minQuickCreateFields).state, .tooOld)
        XCTAssertEqual(IssueModalCLIVersion.check("", minimum: "0.2.21").state, .missing)
        XCTAssertEqual(IssueModalCLIVersion.check("garbage", minimum: "0.2.21").state, .missing)
        XCTAssertEqual(IssueModalCLIVersion.check("v0.1.0-235-gdaf0e935-dirty", minimum: "0.2.21").state, .ok)
        XCTAssertEqual(IssueModalCLIVersion.check("multica 1.0.0 (abc)", minimum: "0.2.21").state, .ok)
        XCTAssertEqual(IssueModalCLIVersion.runtimeCLIVersion(["cli_version": .string("0.3.0")]), "0.3.0")
        XCTAssertEqual(IssueModalCLIVersion.runtimeCLIVersion(["cli_version": .number(3)]), "")
    }

    func testBillingRecoveryFollowsCloudActions() {
        typealias R = IssueModalBillingRecovery
        XCTAssertEqual(R.resolve(actions: ["checkout": true], billingEnabled: false, loading: false, portalFailed: false), .billingDisabled)
        XCTAssertEqual(R.resolve(actions: ["checkout": true], billingEnabled: true, loading: false, portalFailed: true), .billingUnavailable)
        XCTAssertEqual(R.resolve(actions: ["checkout": true, "portal": true], billingEnabled: true, loading: false, portalFailed: false), .checkout)
        XCTAssertEqual(R.resolve(actions: ["portal": true], billingEnabled: true, loading: false, portalFailed: false), .portal)
        XCTAssertEqual(R.resolve(actions: ["purchaseSeats": true], billingEnabled: true, loading: false, portalFailed: false), .billing)
        XCTAssertEqual(R.resolve(actions: ["checkout": false], billingEnabled: true, loading: false, portalFailed: false), .contactAdmin)
        XCTAssertEqual(R.resolve(actions: nil, billingEnabled: true, loading: true, portalFailed: false), .checking)
        XCTAssertEqual(R.resolve(actions: nil, billingEnabled: true, loading: false, portalFailed: false), .billingUnavailable)
    }

    func testStageOptions() {
        XCTAssertEqual(IssueModalStage.options(stage: nil, maxStage: 0), [1, 2, 3])
        XCTAssertEqual(IssueModalStage.options(stage: 5, maxStage: 2), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(IssueModalStage.options(stage: nil, maxStage: 4), [1, 2, 3, 4, 5])
        XCTAssertEqual(IssueModalStage.maxSibling([nil, 2, 7, nil, 3]), 7)
        XCTAssertEqual(IssueModalStage.maxSibling([]), 0)
    }

    func testAttachmentReferences() {
        let body = "See ![shot](/api/attachments/abc/download) and !file[x](https://cdn.example/f.zip?sig=1)"
        XCTAssertTrue(IssueModalAttachments.contentReferences(body, id: "abc", url: nil, downloadURL: nil, markdownURL: nil))
        XCTAssertTrue(IssueModalAttachments.contentReferences(body, id: "zzz", url: "https://cdn.example/f.zip?sig=2", downloadURL: nil, markdownURL: nil))
        XCTAssertFalse(IssueModalAttachments.contentReferences(body, id: "zzz", url: "https://cdn.example/other", downloadURL: nil, markdownURL: nil))
        XCTAssertFalse(IssueModalAttachments.contentReferences("", id: "abc", url: nil, downloadURL: nil, markdownURL: nil))
        XCTAssertEqual(IssueModalAttachments.appendMarkdown("", "![a](b)"), "![a](b)")
        XCTAssertEqual(IssueModalAttachments.appendMarkdown("hello \n\n", "![a](b)"), "hello\n\n![a](b)")
    }

    func testActorRefValues() {
        XCTAssertEqual(IssueModalActorRefs.rawValues(.string("member:u1")), ["member:u1"])
        XCTAssertEqual(IssueModalActorRefs.refs(.array([.string("member:u1"), .string("robot:x"), .number(1)])), [ActorRef(type: "member", id: "u1")])
        XCTAssertTrue(IssueModalActorRefs.hasUnknown(.array([.string("member:u1"), .string("robot:x")])))
        XCTAssertFalse(IssueModalActorRefs.hasUnknown(.string("member:u1")))
        XCTAssertNil(IssueModalActorRefs.parse("member:"))
        XCTAssertEqual(IssueModalActorRefs.toggle(["robot:x", "member:a"], key: "member:b"), ["robot:x", "member:a", "member:b"])
        XCTAssertEqual(IssueModalActorRefs.toggle(["robot:x", "member:a"], key: "member:a"), ["robot:x"])
        XCTAssertNil(IssueModalActorRefs.toggle(["member:a"], key: "member:a"))
        let full = (0..<IssueModalActorRefs.maxValues).map { "member:\($0)" }
        XCTAssertEqual(IssueModalActorRefs.toggle(full, key: "member:new"), full)
    }

    func testAgentAccess() {
        let user = "u1"
        var a = AgentRecord(id: "a", runtimeId: "rt", permissionMode: "private", ownerId: "owner")
        XCTAssertNotNil(IssueModalAgentAccess.denial(a, userID: user, role: "admin"), "admins no longer bypass private agents")
        a.ownerId = user
        XCTAssertNil(IssueModalAgentAccess.denial(a, userID: user, role: "member"))
        a.ownerId = "owner"
        a.permissionMode = "public_to"
        a.invocationTargets = [AgentInvocationTarget(targetType: "workspace")]
        XCTAssertNil(IssueModalAgentAccess.denial(a, userID: user, role: "member"))
        XCTAssertNotNil(IssueModalAgentAccess.denial(a, userID: user, role: nil))
        a.invocationTargets = [AgentInvocationTarget(targetType: "member", targetId: user)]
        XCTAssertNil(IssueModalAgentAccess.denial(a, userID: user, role: nil))
        a.invocationTargets = [AgentInvocationTarget(targetType: "team", targetId: "t")]
        XCTAssertNotNil(IssueModalAgentAccess.denial(a, userID: user, role: "owner"))
        XCTAssertNotNil(IssueModalAgentAccess.denial(a, userID: nil, role: "owner"))
        XCTAssertTrue(IssueModalAgentAccess.isRuntimeBound(a))
        a.runtimeBound = false
        XCTAssertFalse(IssueModalAgentAccess.isRuntimeBound(a))
        a.runtimeBound = nil
        a.runtimeId = "  "
        XCTAssertFalse(IssueModalAgentAccess.isRuntimeBound(a))
    }

    func testFencedRunsAndLabelColor() {
        let s = "Assign this issue to \(IssueModalFence.fenced("Ada")). Go."
        let runs = IssueModalFence.runs(s)
        XCTAssertEqual(runs.map(\.text), ["Assign this issue to ", "Ada", ". Go."])
        XCTAssertEqual(runs.map(\.bold), [false, true, false])
        XCTAssertEqual(IssueModalFence.runs("plain").map(\.text), ["plain"])
        XCTAssertEqual(IssueModalLabelColor.pick("bug"), "#ec4899")
        XCTAssertEqual(IssueModalLabelColor.pick("bug"), IssueModalLabelColor.pick("bug"))
        XCTAssertTrue(IssueModalDuplicates.isDuplicate(status: "cancelled", duplicateOfID: "x"))
        XCTAssertFalse(IssueModalDuplicates.isDuplicate(status: "done", duplicateOfID: "x"))
        XCTAssertFalse(IssueModalDuplicates.isDuplicate(status: "cancelled", duplicateOfID: nil))
    }

    func testCreateSettingsKeepCanonicalOrder() {
        var s = IssueModalCreateSettings()
        XCTAssertEqual(s.manualFields, ["status", "priority", "assignee", "labels", "project"])
        s.setManualField("start_date", visible: true)
        s.setManualField("status", visible: false)
        s.setManualField("due_date", visible: true)
        XCTAssertEqual(s.manualFields, ["priority", "assignee", "labels", "project", "due_date", "start_date"])
        s.setQuickField("due_date", visible: true)
        s.setQuickField("priority", visible: true)
        XCTAssertEqual(s.quickFields, ["project", "priority", "due_date"])
    }

    func testDraftDecodesPartialPayloadsAndPrunesUploads() throws {
        let json = #"{"manual":{"title":"T"},"shared":{"priority":"high","attachments":[{"id":"c1","status":"uploading","filename":"a.png"}]},"activeMode":"agent"}"#
        var d = try JSONDecoder().decode(IssueModalDraft.self, from: Data(json.utf8))
        XCTAssertEqual(d.manual.title, "T")
        XCTAssertEqual(d.manual.status, "todo")
        XCTAssertEqual(d.shared.priority, "high")
        XCTAssertEqual(d.activeMode, "agent")
        XCTAssertTrue(d.hasContent)
        d.shared.attachments = [
            IssueModalDraftUpload(id: "1", status: .uploaded, filename: "a", attachmentID: "a1", url: "https://x/a"),
            IssueModalDraftUpload(id: "2", status: .uploaded, filename: "b", attachmentID: "b1", url: "https://x/b"),
            IssueModalDraftUpload(id: "3", status: .failed, filename: "c"),
        ]
        d.agent.prompt = "look ![a](https://x/a)"
        d.pruneUploads()
        XCTAssertEqual(d.shared.attachments.map(\.id), ["1", "3"])
        XCTAssertFalse(IssueModalDraft().hasContent)
    }

    @MainActor
    func testDraftStorePersistsAndClearsWithLastAssignee() throws {
        let suite = "issue-modal-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IssueModalDraftStore(workspaceID: "ws", defaults: defaults)
        let g0 = store.generation
        store.update { $0.manual.title = "Hello"; $0.activeMode = "agent" }
        XCTAssertEqual(store.generation, g0 + 1)
        store.update { $0.manual.title = "Hello" }
        XCTAssertEqual(store.generation, g0 + 1, "no-op writes keep the generation")
        store.setLastAssignee(type: "agent", id: "a1")
        store.keepOpen = true
        store.persistNow()
        let reloaded = IssueModalDraftStore(workspaceID: "ws", defaults: defaults)
        XCTAssertEqual(reloaded.draft.manual.title, "Hello")
        XCTAssertEqual(reloaded.lastAssigneeID, "a1")
        XCTAssertTrue(reloaded.keepOpen)
        reloaded.clearDraft()
        XCTAssertEqual(reloaded.draft.manual.title, "")
        XCTAssertEqual(reloaded.draft.manual.assigneeID, "a1")
        XCTAssertEqual(reloaded.draft.activeMode, "agent")

        let isolated = IssueModalDraftStore(isolatedFrom: reloaded)
        isolated.update { $0.agent.prompt = "from comment" }
        isolated.setLastActor(type: "squad", id: "s1")
        XCTAssertEqual(isolated.draft.activeMode, "agent")
        XCTAssertEqual(reloaded.draft.agent.prompt, "")
        XCTAssertEqual(reloaded.lastActorID, "s1", "preferences still reach the persisted store")
    }

    func testAPIErrorKeepsStructuredBody() {
        let body = Data(#"{"error":"Limit reached","code":"issue_limit_reached","property_id":"p1"}"#.utf8)
        let e = APIError.from(status: 402, body: body)
        XCTAssertEqual(e.message, "Limit reached")
        XCTAssertEqual(e.code, "issue_limit_reached")
        XCTAssertEqual(e.body?["property_id"]?.stringValue, "p1")
        let plain = APIError.from(status: 500, body: Data("oops".utf8))
        XCTAssertNil(plain.code)
        XCTAssertEqual(plain.message, "Request failed with status 500")
    }
}
