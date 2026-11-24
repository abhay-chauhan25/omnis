import Foundation
import Testing
@testable import OmnisCore

@Suite struct SystemStatsTests {
    @Test func memoryAndSwapReadNaturally() {
        let gigabyte: UInt64 = 1_073_741_824
        let usage = MemoryUsage(usedBytes: 14 * gigabyte + gigabyte / 5, totalBytes: 24 * gigabyte,
                                swapUsedBytes: 2_982_000_000, swapTotalBytes: 4 * gigabyte, pressure: .normal)
        #expect(usage.memoryLabel == "14.2 of 24 GB")
        #expect(usage.swapLabel == "2.8 of 4 GB")
        #expect(MemoryUsage(usedBytes: 0, totalBytes: gigabyte, swapUsedBytes: 0, swapTotalBytes: 0, pressure: .normal).swapLabel == "none")
        #expect(MemoryUsage.pressure(level: 1) == .normal && MemoryUsage.pressure(level: 2) == .warning
                && MemoryUsage.pressure(level: 4) == .critical && MemoryUsage.pressure(level: 9) == .unknown)
    }

    @Test func theRealFiguresAreSane() throws {
        let usage = try #require(MemoryUsage.current())
        #expect(usage.totalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(usage.usedBytes > 0 && usage.usedBytes <= usage.totalBytes)
        #expect(usage.swapUsedBytes <= usage.swapTotalBytes || usage.swapTotalBytes == 0)
    }

    @Test func energyUseIsReadFromTheSecondSampleWithHelpersAddedIn() {
        let output = """
        Processes: 700 total
        COMMAND          POWER
        Safari           0.0
        Code             0.0

        Processes: 701 total
        Disks: 268281741/6447G read, 79773568/1738G written.

        COMMAND          POWER
        BTLEServer       98.5
        Code Helper (Ren 23.2
        WindowServer     14.8
        top              7.2
        2.1.326          4.9
        SpaceJump        3.0
        Code Helper      2.7
        Code             2.5
        Google Chrome He 0.6
        Finder           0.0
        not a row
        """
        #expect(EnergyUse.parse(output) == [
            .init(name: "BTLEServer", impact: 98.5), .init(name: "Code", impact: 28.4),
            .init(name: "WindowServer", impact: 14.8), .init(name: "2.1.326", impact: 4.9),
        ])
        #expect(EnergyUse.parse(output, limit: 10).map(\.name) == ["BTLEServer", "Code", "WindowServer", "2.1.326", "SpaceJump"])
        #expect(EnergyUse.parse("").isEmpty && EnergyUse.parse("COMMAND POWER\n").isEmpty)
        let asked = Collected<[String]>()
        let items = EnergyUse.current(run: { program, arguments in
            asked.add([program] + arguments)
            return output
        })
        #expect(items.first?.name == "BTLEServer")
        #expect(asked.values.first?.first == "/usr/bin/top" && asked.values.first?.contains("power") == true)
    }
}
