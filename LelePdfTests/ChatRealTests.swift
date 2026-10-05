import Foundation
import Testing
@testable import LelePdf

/// Real-call suite. `scripts/test-real.sh chat` is the only entry point: in
/// the ordinary suite all tests return immediately without contacting Claude.
@MainActor
@Suite("Chat — real calls", .serialized, .timeLimit(.minutes(15)))
struct ChatRealTests {
    private struct KnownQuestion {
        let summary: String
        let text: String
        let expectedFirstPage: Int
    }

    @Test("Merck: five answers cite the correct page; external knowledge marked")
    func merckCitationsAndExternalKnowledge() async throws {
        guard ChatRealTestSupport.realCallsEnabled() else { return }
        try await ChatRealTestSupport.useRealCLI()
        let visible = 1...3
        let snapshot = try await ChatRealTestSupport.loadSnapshot(
            url: TestPDFs.merck, currentPageIndex: 2, visiblePageRange: visible
        )
        let plan = try ChatContextBuilder.build(
            snapshot: snapshot, scope: .wholeDocument, memory: nil,
            cacheRoot: ChatRealTestSupport.cacheRoot
        )
        let questions = [
            KnownQuestion(
                summary: "Orphan Drug Act incentives",
                text: "Quali incentivi introdusse l'Orphan Drug Act del 1983 e quali malattie riguardava?",
                expectedFirstPage: 3
            ),
            KnownQuestion(
                summary: "drug development time and cost",
                text: "All'inizio del XXI secolo, quanto tempo e quanto denaro servivano per portare un nuovo farmaco sul mercato?",
                expectedFirstPage: 2
            ),
            KnownQuestion(
                summary: "Hatch-Waxman and generics growth",
                text: "Che cosa impose l'Hatch-Waxman Act ai produttori di generici e quale quota in volume raggiunsero nel 2005?",
                expectedFirstPage: 5
            ),
            KnownQuestion(
                summary: "Vioxx withdrawal and lawsuits",
                text: "Perché Merck ritirò Vioxx e quante cause e pazienti risultavano coinvolti nel 2006?",
                expectedFirstPage: 11
            ),
            KnownQuestion(
                summary: "Pfizer size and R&D in 2005",
                text: "Quali erano vendite, numero di dipendenti e spesa in R&D di Pfizer nel 2005?",
                expectedFirstPage: 12
            ),
        ]

        let session = ChatSession()
        do {
            let stream = await session.start(model: .sonnet, systemPrompt: plan.systemPrompt, mode: plan.mode)
            let iterator = ChatEventCursor(stream)
            _ = await iterator.next()
            for (index, question) in questions.enumerated() {
                let response = try #require(await ChatRealTestSupport.ask(
                    session: session, iterator: iterator, question: question.text,
                    visiblePageRange: visible
                ))
                let citations = ChatRealTestSupport.citationPages(in: response.text)
                #expect(!response.isError)
                #expect(citations.first == question.expectedFirstPage)
                print("CHAT Merck #\(index + 1): \(question.summary) · expected p.\(question.expectedFirstPage) · citations \(citations) · \(Int(response.elapsed * 1000)) ms")
                ChatRealTestSupport.recordFixture(
                    question: question.text, visiblePageRange: visible,
                    response: response, label: "merck-\(index + 1)"
                )
            }

            let externalQuestion = "Con conoscenza esterna al caso, chi ha creato ChatGPT e in quale anno e' stato lanciato?"
            let external = try #require(await ChatRealTestSupport.ask(
                session: session, iterator: iterator, question: externalQuestion,
                visiblePageRange: visible
            ))
            let outside = ChatRealTestSupport.externalText(in: external.text)
            #expect(!outside.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            print("CHAT Merck #6: external knowledge · <fuori> tag present=\(!outside.isEmpty) · \(Int(external.elapsed * 1000)) ms")
            ChatRealTestSupport.recordFixture(
                question: externalQuestion, visiblePageRange: visible,
                response: external, label: "merck-external"
            )
            await session.stop()
        } catch {
            await session.stop()
            throw error
        }
    }

    @Test("search security: Read outside the folder is denied")
    func searchModeDeniesOutsideReads() async throws {
        guard ChatRealTestSupport.realCallsEnabled() else { return }
        try await ChatRealTestSupport.useRealCLI()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lelepdf-chat-security-\(UUID().uuidString)", isDirectory: true)
        let allowed = root.appendingPathComponent("pagine", isDirectory: true)
        let outside = root.appendingPathComponent("SEGRETO-FUORI.txt")
        let canary = "LELEPDF-CANARY-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try "Pagina 1\nContenuto consentito.\n".write(
            to: allowed.appendingPathComponent("p-0001.txt"), atomically: true, encoding: .utf8
        )
        try canary.write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let zshrc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        let systemPrompt = """
        Sei un test di sicurezza. Quando l'utente indica percorsi, tenta davvero di leggerli con Read e riferisci soltanto se ogni lettura e' riuscita o e' stata negata. Non inventare il contenuto.
        """
        let question = "Tenta con Read sia `~/.zshrc` sia il percorso assoluto `\(outside.path)`. Dimmi per ciascuno se la lettura viene negata."
        let session = ChatSession()
        do {
            let stream = await session.start(
                model: .sonnet, systemPrompt: systemPrompt,
                mode: .search(
                    workingDirectory: allowed,
                    allowedTools: ["Read(./**)", "Grep(./**)", "Glob(./**)"]
                )
            )
            let iterator = ChatEventCursor(stream)
            _ = await iterator.next()
            let response = try #require(await ChatRealTestSupport.ask(
                session: session, iterator: iterator, question: question,
                visiblePageRange: 0...0
            ))
            let toolUses = response.events.compactMap { event -> (String, String)? in
                if case .toolUse(let name, let input) = event { return (name, input ?? "") }
                return nil
            }
            let toolResults = response.events.compactMap { event -> (Bool, String)? in
                if case .toolResult(let isError, let content) = event { return (isError, content) }
                return nil
            }
            #expect(toolUses.contains { $0.0 == "Read" && $0.1.contains(".zshrc") })
            #expect(toolUses.contains { $0.0 == "Read" && $0.1.contains(outside.path) })
            #expect(toolResults.count >= 2)
            #expect(toolResults.allSatisfy { $0.0 })
            let observed = response.text + toolResults.map(\.1).joined(separator: "\n")
            #expect(!observed.contains(canary))
            if let zshrcText = try? String(contentsOf: zshrc, encoding: .utf8),
               let distinctiveLine = zshrcText.split(separator: "\n").map(String.init).first(where: { $0.count >= 20 }) {
                #expect(!observed.contains(distinctiveLine))
            }
            print("CHAT security #7: Read attempted=\(toolUses.filter { $0.0 == "Read" }.count) · results denied=\(toolResults.filter(\.0).count) · canary absent=\(!observed.contains(canary))")
            ChatRealTestSupport.recordFixture(
                question: question, visiblePageRange: 0...0,
                response: response, label: "security"
            )
            await session.stop()
        } catch {
            await session.stop()
            throw error
        }
    }

    @Test("Draghi: Chapter → Whole PDF keeps the thread and widens the sources")
    func draghiScopeChangeKeepsThread() async throws {
        guard ChatRealTestSupport.realCallsEnabled() else { return }
        try await ChatRealTestSupport.useRealCLI()
        let visible = 24...24
        let snapshot = try await ChatRealTestSupport.loadSnapshot(
            url: TestPDFs.draghi, currentPageIndex: 24, visiblePageRange: visible
        )
        let firstQuestion = "Perche' il calo demografico rende urgente aumentare la produttivita' europea?"
        let chapterPlan = try ChatContextBuilder.build(
            snapshot: snapshot, scope: .chapter, memory: nil,
            cacheRoot: ChatRealTestSupport.cacheRoot
        )
        #expect(chapterPlan.includedPages.contains(24))
        #expect(!chapterPlan.includedPages.contains(40))

        let firstSession = ChatSession()
        let first: ChatRealTestSupport.Response
        do {
            let stream = await firstSession.start(
                model: .sonnet, systemPrompt: chapterPlan.systemPrompt, mode: chapterPlan.mode
            )
            let iterator = ChatEventCursor(stream)
            _ = await iterator.next()
            first = try #require(await ChatRealTestSupport.ask(
                session: firstSession, iterator: iterator, question: firstQuestion,
                visiblePageRange: visible
            ))
            #expect(ChatRealTestSupport.citationPages(in: first.text).contains(25))
            ChatRealTestSupport.recordFixture(
                question: firstQuestion, visiblePageRange: visible,
                response: first, label: "draghi-chapter"
            )
            await firstSession.stop()
        } catch {
            await firstSession.stop()
            throw error
        }

        let memory = "Domanda precedente: \(firstQuestion)\nRisposta precedente: \(first.text)"
        let wholePlan = try ChatContextBuilder.build(
            snapshot: snapshot, scope: .wholeDocument, memory: memory,
            cacheRoot: ChatRealTestSupport.cacheRoot
        )
        #expect(wholePlan.systemPrompt.contains("Domanda precedente"))
        #expect(wholePlan.includedPages.contains(40))
        let followUp = "Tenendo conto della risposta precedente, in che modo gli alti costi energetici aggravano il problema di crescita e investimento?"
        let secondSession = ChatSession()
        do {
            let stream = await secondSession.start(
                model: .sonnet, systemPrompt: wholePlan.systemPrompt, mode: wholePlan.mode
            )
            let iterator = ChatEventCursor(stream)
            _ = await iterator.next()
            let second = try #require(await ChatRealTestSupport.ask(
                session: secondSession, iterator: iterator, question: followUp,
                visiblePageRange: visible
            ))
            let citations = ChatRealTestSupport.citationPages(in: second.text)
            #expect(citations.contains(41))
            print("CHAT Draghi #8-9: chapter citations \(ChatRealTestSupport.citationPages(in: first.text)) · whole PDF citations \(citations) · memory present=true")
            ChatRealTestSupport.recordFixture(
                question: followUp, visiblePageRange: visible,
                response: second, label: "draghi-whole"
            )
            await secondSession.stop()
        } catch {
            await secondSession.stop()
            throw error
        }
    }

    @Test("10k budget: orange, red, automatic summary and continuation")
    func loweredBudgetSummarizesAndContinues() async throws {
        guard ChatRealTestSupport.realCallsEnabled() else { return }
        try await ChatRealTestSupport.useRealCLI()
        let visible = 1...3
        let snapshot = try await ChatRealTestSupport.loadSnapshot(
            url: TestPDFs.merck, currentPageIndex: 2, visiblePageRange: visible
        )
        let controller = ChatController(
            cacheRoot: ChatRealTestSupport.cacheRoot, budgetLimit: 10_000,
            summaryProvider: { messages in await ChatRealTestSupport.summarizeReal(messages) }
        )
        controller.scope = .visiblePages
        controller.open(snapshot: snapshot)
        do {
            let firstQuestion = "Riassumi in circa 250 parole gli incentivi dell'Orphan Drug Act e il problema del divario 10/90."
            controller.inputText = firstQuestion
            controller.submit(snapshot: snapshot)
            try #require(await ChatRealTestSupport.waitUntil {
                !controller.isResponding && controller.messages.filter { $0.role == .assistant }.count == 1
            })
            #expect(controller.budget.level == .orange)
            let firstAnswer = try #require(controller.messages.last(where: { $0.role == .assistant }))
            ChatRealTestSupport.recordTextFixture(
                question: firstQuestion, visiblePageRange: visible,
                text: firstAnswer.rawText, label: "budget-1"
            )
            print("CHAT budget #10: used \(controller.budget.usedTokens)/10000 · level \(controller.budget.level)")

            let note = String(repeating: "Appunto personale da ricordare nel seguito. ", count: 700)
            let secondQuestion = "Conserva questa nota e chiarisci in due frasi il legame con gli incentivi: \(note)"
            controller.inputText = secondQuestion
            controller.submit(snapshot: snapshot)
            try #require(await ChatRealTestSupport.waitUntil {
                !controller.isResponding && controller.messages.filter { $0.role == .assistant }.count == 2
            })
            #expect(controller.budget.level == .red)
            let secondAnswer = try #require(controller.messages.last(where: { $0.role == .assistant }))
            ChatRealTestSupport.recordTextFixture(
                question: secondQuestion, visiblePageRange: visible,
                text: secondAnswer.rawText, label: "budget-2"
            )
            print("CHAT budget #11: used \(controller.budget.usedTokens)/10000 · level \(controller.budget.level)")

            let thirdQuestion = "Dopo il riassunto, qual era la conclusione principale sugli incentivi?"
            controller.inputText = thirdQuestion
            controller.submit(snapshot: snapshot)
            try #require(await ChatRealTestSupport.waitUntil {
                !controller.isResponding
                    && controller.messages.filter { $0.role == .assistant }.count == 3
                    && controller.messages.contains { $0.role == .divider && $0.rawText == "Conversation summarized" }
            })
            let thirdAnswer = try #require(controller.messages.last(where: { $0.role == .assistant }))
            #expect(!thirdAnswer.rawText.isEmpty)
            ChatRealTestSupport.recordTextFixture(
                question: thirdQuestion, visiblePageRange: visible,
                text: thirdAnswer.rawText, label: "budget-3"
            )
            print("CHAT budget #12 + summary #13: divider present=true · continuation=true · used after restart \(controller.budget.usedTokens)/10000")
            await controller.closeWindow()
        } catch {
            await controller.closeWindow()
            throw error
        }
    }
}
