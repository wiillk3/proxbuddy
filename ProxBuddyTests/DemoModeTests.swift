import Testing
@testable import ProxBuddy

struct DemoHelpCatalogTests {

    @Test func rootHelpParsesIntoGroups() {
        let page = CommandListParser.parse(DemoHelpCatalog.lines(for: "help"))
        #expect(!page.isEmpty)
        let names = page.sections.flatMap(\.entries).map(\.name)
        #expect(names.contains("hf"))
        #expect(names.contains("hw"))
        #expect(page.sections.flatMap(\.entries).contains { $0.name == "hf" && $0.isGroup })
    }

    @Test func hfPageHasMifareGroupAndSearchLeaf() {
        let page = CommandListParser.parse(DemoHelpCatalog.lines(for: "hf"))
        let entries = page.sections.flatMap(\.entries)
        #expect(entries.contains { $0.name == "mf" && $0.isGroup })
        #expect(entries.contains { $0.name == "search" && !$0.isGroup })
    }

    @Test func helpProbeReturnsOptions() {
        let help = HelpParser.parse(DemoHelpCatalog.lines(for: "hf mf info --help"))
        #expect(help.hasContent)
        #expect(help.usage.contains("hf mf info"))
        #expect(help.options.contains { $0.flags.contains("--file") })
    }

    @Test func unknownCommandStillHasStubHelp() {
        let help = HelpParser.parse(DemoHelpCatalog.lines(for: "hf madeup --help"))
        #expect(help.hasContent)
        #expect(help.options.contains { $0.flags.contains("--help") })
    }
}

@MainActor
struct DemoEngineTests {

    @Test func captureReturnsCatalogWithoutARunner() async {
        let engine = TerminalEngine()
        engine.isDemo = true
        let lines = await engine.captureOutputSilent("help")
        #expect(lines.contains { $0.contains("{High frequency") })
    }

    @Test func sendDoesNotRequireARunner() {
        let engine = TerminalEngine()
        engine.isDemo = true
        engine.sendCommand("hf mf info")
        #expect(engine.lines.contains { $0.isInput && $0.raw.contains("hf mf info") })
        #expect(engine.lines.contains { $0.raw == DemoHelpCatalog.blockedMessage })
    }

    @Test func sessionEnterDemoSetsFlagsAndLeavesClientStopped() {
        let session = PM3Session(label: "PM5 1")
        session.enterDemo()
        #expect(session.isDemo)
        #expect(session.engine.isDemo)
        #expect(!session.isRunning)
        #expect(session.statusMessage.contains("Demo"))
        session.exitDemo()
        #expect(!session.isDemo)
        #expect(!session.engine.isDemo)
    }
}

struct DemoSampleDumpTests {

    @Test func jsonParsesAsClassic1KWithDeadc0deUID() throws {
        let dump = try #require(ParsedMFDump.fromJSON(DemoSampleDump.jsonData()))
        #expect(dump.uid == DemoSampleDump.uid)
        #expect(dump.atqa == "0004")
        #expect(dump.sak == "08")
        #expect(dump.blockCount == 64)
        #expect(dump.cardLabel.contains("1K"))
        let block0 = dump.sectors[0].blocks[0].data
        #expect(Array(block0.prefix(4)) == [0xDE, 0xAD, 0xC0, 0xDE])
        #expect(block0[4] == 0xDE ^ 0xAD ^ 0xC0 ^ 0xDE)
    }

    @Test func dumpLivesInTmpNotDocumentsPM3() throws {
        let file = try DemoSampleDump.dumpFile()
        #expect(file.fileName == DemoSampleDump.fileName)
        #expect(file.groupKey == DemoSampleDump.groupID)
        #expect(file.family == .mifareClassic)
        #expect(file.url.path.contains("proxbuddy-demo"))
        #expect(!file.url.path.contains("/pm3/"))
        let parsed = try #require(ParsedMFDump.from(url: file.url))
        #expect(parsed.blockCount == 64)
    }
}

@MainActor
struct DemoFilesOverlayTests {

    @Test func viewModelInjectsSampleOnlyWhenAsked() throws {
        let vm = DumpManagerViewModel()
        vm.showDemoSample = false
        vm.refresh()
        #expect(!vm.groups.contains(where: \.isDemoSample))

        vm.showDemoSample = true
        vm.refresh()
        let demo = try #require(vm.groups.first(where: \.isDemoSample))
        #expect(demo.id == DemoSampleDump.groupID)
        #expect(demo.uid == "DE AD C0 DE")

        vm.delete(demo)
        #expect(vm.groups.contains(where: \.isDemoSample))

        vm.showDemoSample = false
        vm.refresh()
        #expect(!vm.groups.contains(where: \.isDemoSample))
    }
}
