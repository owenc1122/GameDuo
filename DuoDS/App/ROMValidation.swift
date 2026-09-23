#if DEBUG
import Foundation
import UIKit

@MainActor
enum ROMValidation {
    static func run(root: URL, session: EmulatorSession) async {
        let library = GameLibraryStore()
        var results: [String: String] = [:]
        let output = root.appendingPathComponent("Results", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let good = ["FuzedNeo.nds", "HelloWorld.n64", "games.zip", "games.7z", "games.rar", "games.tar.gz", "renamed.bin", "homebrew.srl", "InputCPU.v64", "InputCPU-little.n64", "Mars3D.cia", "Mars3D.zcia", "Mars3D.ciax", "Mars3D-Z3DS.ciax", "Mars3D.z3dsx"]
        for name in good {
            let game = await library.importGame(from: root.appendingPathComponent(name))
            var ok = library.importError == nil && game != nil
            if name == "games.zip", let game,
               let batch = game.url.path.components(separatedBy: "/ROMs/").last?.split(separator: "/").first {
                let companion = ROMFiles.supportDirectory().appendingPathComponent("ROMs/" + batch + "/中文目录/assets/data.bin")
                ok = ok && (try? Data(contentsOf: companion)) == Data("companion data".utf8)
            }
            results[name] = ok ? "PASS imported" : "FAIL \(library.importError ?? "missing game")"
            print("FORMAT_CHECK \(name): \(results[name]!)")
        }
        for name in ["bad-system.zip", "broken.nds", "truncated.cia", "corrupt.ciax", "encrypted.ciax", "encrypted-Z3DS.ciax", "traversal.zip", "symlink.zip", "nested.zip", "empty-games.zip", "corrupt-game.zip"] {
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) else {
                results[name] = "FAIL missing fixture"; continue
            }
            let before = library.games.count
            _ = await library.importGame(from: root.appendingPathComponent(name))
            let ok = library.importError != nil && library.games.count == before
            results[name] = ok ? "PASS rejected: \(library.importError!)" : "FAIL invalid input changed library or was accepted"
            print("FORMAT_CHECK \(name): \(results[name]!)")
        }
        for name in ["bios7.bin", "bios9.bin"] {
            let before = library.games.count
            _ = await library.importGame(from: root.appendingPathComponent(name))
            let destination = ROMFiles.supportDirectory().appendingPathComponent("DS/System/" + name)
            let equal = FileManager.default.contentsEqual(atPath: root.appendingPathComponent(name).path, andPath: destination.path)
            results[name] = equal && library.importError == nil && library.games.count == before ? "PASS open-source BIOS routed as system data" : "FAIL system-file routing"
        }
        _ = await library.importGame(from: root.appendingPathComponent("nds-save-package.zip"))
        let ndsSave = ROMFiles.supportDirectory().appendingPathComponent("Saves/FuzedNeo.dsv")
        results["import-nds-save"] = (try? Data(contentsOf: ndsSave)) == Data(repeating: 0x5a, count: 32768)
            ? "PASS matched .sav to NDS game" : "FAIL NDS save was not routed"
        _ = await library.importGame(from: root.appendingPathComponent("n64-save-package.zip"))
        let n64Save = ROMFiles.supportDirectory().appendingPathComponent("N64/Saves/HelloWorld.z64.srm")
        results["import-n64-save"] = (try? Data(contentsOf: n64Save)) == Data(repeating: 0xa5, count: 32768)
            ? "PASS matched .srm to N64 game" : "FAIL N64 save was not routed"
        _ = await library.importGame(from: root.appendingPathComponent("3ds-save-package.zip"))
        let zeroID = String(repeating: "0", count: 32)
        let threeDSSave = ROMFiles.azaharSaves(ROMFiles.supportDirectory())
            .appendingPathComponent("Azahar/sdmc/Nintendo 3DS/\(zeroID)/\(zeroID)/title/00040000/12345678/data/00000001/main")
        results["import-3ds-save"] = (try? Data(contentsOf: threeDSSave)) == Data("3ds save fixture".utf8)
            ? "PASS routed structured 3DS save tree" : "FAIL 3DS save tree was not routed"
        if !ProcessInfo.processInfo.arguments.contains("-format-management-only") {
            let launchTargets = ["nds": library.games.first { $0.url.lastPathComponent == "TrailMix.nds" },
                                 "nds-restart": library.games.first { $0.url.lastPathComponent == "FuzedNeo.nds" },
                                 "n64": library.games.first { $0.url.lastPathComponent == "InputCPU.z64" },
                                 "n64-restart": library.games.first { $0.url.lastPathComponent == "HelloWorld.z64" },
                                 "cia": library.games.first { $0.url.pathExtension == "app" },
                                 "z3dsx": library.games.first { $0.url.pathExtension == "z3dsx" }]
            for key in ["nds", "nds-restart", "n64", "n64-restart", "cia", "z3dsx"] {
                guard let game = launchTargets[key] ?? nil else { results["launch-" + key] = "FAIL no game"; continue }
                session.start(romURL: game.url)
                try? await Task.sleep(for: .seconds(5))
                let first = session.topImage.flatMap { UIImage(cgImage: $0).pngData() }
                if let first { try? first.write(to: output.appendingPathComponent(key + "-before.png")) }
                if key == "n64" { session.setN64Button(7, pressed: true) }
                else if key == "nds" { session.press(.start) }
                else { session.press(.a) }
                try? await Task.sleep(for: .seconds(1))
                let second = session.topImage.flatMap { UIImage(cgImage: $0).pngData() }
                if let second { try? second.write(to: output.appendingPathComponent(key + "-after.png")) }
                let video = session.topImage?.dataProvider?.data
                let distinct = video.map { Set(($0 as Data).prefix(512 * 1024)).count } ?? 0
                let running = session.isRunning
                let audio = session.isAudioRunning
                let changed = first != second
                session.releaseAllInputs()
                session.saveGame()
                session.stop()
                if key == "n64" {
                    let info = library.saveInfo(for: game)
                    results["n64-save"] = info.exists && info.byteCount > 0 ? "PASS persisted SRAM" : "FAIL missing SRAM"
                }
                let ok = running && distinct > (key.hasPrefix("n64") ? 2 : 8) && (key != "n64" || changed)
                results["launch-" + key] = "\(ok ? "PASS" : "FAIL") running=\(running) imageValues=\(distinct) inputChangedFrame=\(changed) audioEngine=\(audio) error=\(session.launchError ?? "none")"
                print("FORMAT_CHECK launch-\(key): \(results["launch-" + key]!)")
                fflush(stdout)
            }
            if let mk64 = Bundle.main.url(forResource: "MK64-3DS", withExtension: "3dsx") {
                session.start(romURL: mk64)
                results["mk64-direct-launch"] = session.launchError?.contains("美版") != true ? "PASS no extra-ROM preflight block" : "FAIL extra-ROM preflight still active"
                session.stop()
            } else { results["mk64-direct-launch"] = "FAIL missing fixture" }
        }
        let routedROM = ROMFiles.mk64Directory(ROMFiles.supportDirectory()).appendingPathComponent("mk64.z64")
        if !FileManager.default.fileExists(atPath: routedROM.path) {
            if let launch = await library.importGame(from: root.appendingPathComponent("SyntheticMK64.v64")),
               launch.isBundledMK64Port,
               let game = library.games.first(where: { $0.url.lastPathComponent == "SyntheticMK64.z64" }),
               let normalized = try? Data(contentsOf: game.url),
               let routed = try? Data(contentsOf: routedROM), normalized == routed,
               Array(routed.prefix(4)) == [0x80, 0x37, 0x12, 0x40] {
                results["mk64-resource-routing"] = "PASS detected, normalized, routed and selected MK64 port"
            } else { results["mk64-resource-routing"] = "FAIL routing or normalization" }
            try? FileManager.default.removeItem(at: routedROM)
        } else { results["mk64-resource-routing"] = "FAIL validation simulator has unexpected MK64 data" }
        let routedO2R = ROMFiles.mk64Directory(ROMFiles.supportDirectory()).appendingPathComponent("mk64.o2r")
        let routedCompanion = ROMFiles.mk64Directory(ROMFiles.supportDirectory()).appendingPathComponent("config/preset.ini")
        if let launch = await library.importGame(from: root.appendingPathComponent("mixed-mk64.zip")),
           launch.isBundledMK64Port,
           FileManager.default.fileExists(atPath: routedROM.path),
           FileManager.default.fileExists(atPath: routedO2R.path),
           (try? Data(contentsOf: routedCompanion)) == Data("companion data retained".utf8),
           library.importMessage?.contains("正在启动 Mario Kart 64 3DS") == true {
            results["mk64-mixed-package-auto-config"] = "PASS archive unpacked, ROM/O2R/SD data routed, bundled port selected"
        } else {
            results["mk64-mixed-package-auto-config"] = "FAIL \(library.importError ?? "package was not fully configured")"
        }
        try? FileManager.default.removeItem(at: routedROM)
        try? FileManager.default.removeItem(at: routedO2R)
        try? FileManager.default.removeItem(at: routedCompanion)
        let listedSaves = library.games.map { library.saveInfo(for: $0) }
        results["settings-game-and-save-list"] = listedSaves.count == library.games.count && !listedSaves.isEmpty
            ? "PASS listed \(listedSaves.count) games with per-game save state"
            : "FAIL settings list did not cover every game"
        if let input = library.games.first(where: { $0.url.lastPathComponent == "HelloWorld.z64" }) {
            let save = library.saveInfo(for: input)
            do {
                try library.deleteGame(input)
                results["delete-game-preserves-save"] = !FileManager.default.fileExists(atPath: input.url.path)
                    && save.location.map { FileManager.default.fileExists(atPath: $0.path) } == true
                    && !library.games.contains(where: { $0.id == input.id })
                    && library.managedSaveInfos().contains(where: { $0.game.title == input.title && $0.exists })
                    ? "PASS removed card and retained save" : "FAIL card/save separation"
            } catch { results["delete-game-preserves-save"] = "FAIL \(error.localizedDescription)" }
        } else { results["delete-game-preserves-save"] = "FAIL missing N64 game" }
        if let nds = library.games.first(where: { $0.url.lastPathComponent == "FuzedNeo.nds" }) {
            let save = library.saveInfo(for: nds)
            do {
                try library.deleteSave(save)
                results["delete-save-keeps-game"] = FileManager.default.fileExists(atPath: nds.url.path)
                    && !library.saveInfo(for: nds).exists
                    ? "PASS removed save and retained card" : "FAIL save/card separation"
            } catch { results["delete-save-keeps-game"] = "FAIL \(error.localizedDescription)" }
        } else { results["delete-save-keeps-game"] = "FAIL missing NDS game" }
        if let bundled = library.games.first(where: { $0.isBundledTest }) {
            do {
                try library.deleteGame(bundled)
                let hidden = !library.games.contains(where: { $0.id == bundled.id }) && library.hasHiddenBundledGames
                library.restoreBundledGames()
                let restored = library.games.contains(where: { $0.id == bundled.id }) && !library.hasHiddenBundledGames
                results["bundled-card-hide-and-restore"] = hidden && restored
                    ? "PASS removed bundled card and restored it from settings"
                    : "FAIL bundled card visibility state"
            } catch { results["bundled-card-hide-and-restore"] = "FAIL \(error.localizedDescription)" }
        } else { results["bundled-card-hide-and-restore"] = "FAIL missing bundled card" }
        try? JSONEncoder().encode(results).write(to: output.appendingPathComponent("results.json"), options: .atomic)
        print("FORMAT_CHECK_COMPLETE failures=\(results.values.filter { $0.hasPrefix("FAIL") }.count)")
        fflush(stdout)
        exit(results.values.contains { $0.hasPrefix("FAIL") } ? 1 : 0)
    }
}
#endif
