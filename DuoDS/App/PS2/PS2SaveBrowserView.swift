import SwiftUI
import SceneKit
import UIKit
import UniformTypeIdentifiers

// PS2 memory-card save browser: a recreation of the look of the PS2 system browser's memory card
// screen (drifting haze, floating 3D save icons, glowing thin type). Everything is drawn in code —
// no Sony artwork, fonts or sounds.

// MARK: - Model

/// One save plus its parsed `icon.sys` / normal icon (either may be missing or unreadable).
struct PS2BrowserSave: Identifiable, Sendable {
    let entry: PS2SaveEntry
    let iconSys: PS2IconSys?
    let icon: PS2Icon?

    var id: String { entry.id }

    var titleLines: [String] {
        if let iconSys, !iconSys.title.isEmpty { return iconSys.titleLines }
        return [entry.fallbackTitle, ""]
    }

    var sizeKB: Int64 { (entry.totalSize + 1023) / 1024 }

    static func load(_ entry: PS2SaveEntry) -> PS2BrowserSave {
        let sys = entry.iconSysData().flatMap { try? PS2IconSys(data: $0) }
        var icon: PS2Icon?
        if let name = sys?.iconFiles.normal, !name.isEmpty,
           let file = entry.files.first(where: { $0.name == name })
               ?? entry.files.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
           let data = try? Data(contentsOf: file.url) {
            icon = try? PS2Icon(data: data)
        }
        return PS2BrowserSave(entry: entry, iconSys: sys, icon: icon)
    }
}

enum PS2SaveFileTypes {
    static let psu = UTType(filenameExtension: "psu") ?? .data
    static let max = UTType(filenameExtension: "max") ?? .data
}

/// `.psu` bytes for `.fileExporter`.
struct PS2PSUDocument: FileDocument {
    static var readableContentTypes: [UTType] { [PS2SaveFileTypes.psu] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - View

struct PS2SaveBrowserView: View {
    let card: PS2MemoryCard
    let gameTitle: String
    let onClose: () -> Void

    init(card: PS2MemoryCard, gameTitle: String, onClose: @escaping () -> Void) {
        self.card = card
        self.gameTitle = gameTitle
        self.onClose = onClose
    }

    private enum Prompt: Identifiable {
        case delete(PS2BrowserSave)
        case overwrite(URL, String)
        case message(String)

        var id: String {
            switch self {
            case .delete(let save): "delete-\(save.id)"
            case .overwrite(let url, _): "overwrite-\(url.path)"
            case .message(let text): "message-\(text)"
            }
        }
    }

    private enum PanelAction: CaseIterable { case copy, delete, back }

    @StateObject private var stage = PS2IconStage()
    @Environment(\.scenePhase) private var scenePhase
    @State private var saves: [PS2BrowserSave] = []
    @State private var loaded = false
    @State private var selectedID: String?
    @State private var focused = false
    @State private var panelHighlight: PanelAction = .copy
    @State private var prompt: Prompt?
    @State private var toast: String?
    @State private var busy = false
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportDocument: PS2PSUDocument?
    @State private var exportName = ""
    @State private var isVisible = false

    private var selected: PS2BrowserSave? { saves.first { $0.id == selectedID } }
    private var paused: Bool { !isVisible || scenePhase == .background }
    private var usedBytes: Int64 { saves.reduce(0) { $0 + $1.entry.totalSize } }

    var body: some View {
        ZStack {
            PS2BrowserBackdrop(paused: paused, tint: tintColors, tintOpacity: tintOpacity)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                infoBlock
                    .padding(.top, 14)
                ZStack(alignment: .bottom) {
                    PS2IconGridView(stage: stage, saves: saves, selectedID: selectedID,
                                    focused: focused, paused: paused, onTap: handleTap)
                        .ignoresSafeArea(.container, edges: .horizontal)
                    if loaded && saves.isEmpty { emptyState }
                    if focused, selected != nil {
                        actionPanel
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .offset(y: 16)))
                    }
                }
                .frame(maxHeight: .infinity)
                hintBar
            }

            if let prompt { promptView(prompt).transition(.opacity) }
            if let toast {
                PS2Dialog(message: toast, detail: nil, options: [])
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: focused)
        .animation(.easeInOut(duration: 0.2), value: prompt?.id)
        .animation(.easeInOut(duration: 0.2), value: toast)
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: Array(Set([PS2SaveFileTypes.psu, PS2SaveFileTypes.max])),
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { beginImport(url) }
            case .failure(let error): showError(error)
            }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: PS2SaveFileTypes.psu,
                      defaultFilename: exportName) { result in
            exportDocument = nil
            switch result {
            case .success: showToast(String(localized: "复制完成"))
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { showError(error) }
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task { await reload() }
    }

    // MARK: Header / info

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "记忆卡（PS2）/1"))
                    .font(.system(size: 21, weight: .light, design: .rounded))
                    .ps2Glow()
                if !gameTitle.isEmpty {
                    Text(gameTitle)
                        .font(.system(size: 12, weight: .light, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(verbatim: "\(Self.kbString(usedBytes)) / 8 MB")
                .font(.system(size: 15, weight: .light, design: .rounded))
                .monospacedDigit()
                .ps2Glow(0.7)
                .accessibilityLabel(String(localized: "已用 \(Self.kbString(usedBytes))，共 8 MB"))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.top, 10)
    }

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let save = selected {
                Text(save.titleLines[0])
                    .font(.system(size: 19, weight: .light, design: .rounded))
                    .ps2Glow()
                Text(save.titleLines.count > 1 ? save.titleLines[1] : "")
                    .font(.system(size: 19, weight: .light, design: .rounded))
                    .ps2Glow()
                HStack(spacing: 14) {
                    Text(verbatim: "\(save.sizeKB) KB")
                    if let date = save.entry.modificationDate {
                        Text(date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)
                            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                    }
                }
                .font(.system(size: 13, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 2)
            } else {
                Text(verbatim: " ").font(.system(size: 19))
                Text(verbatim: " ").font(.system(size: 19))
                Text(verbatim: " ").font(.system(size: 13))
            }
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .animation(nil, value: selectedID)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(String(localized: "无存档数据"))
                .font(.system(size: 20, weight: .light, design: .rounded))
                .ps2Glow()
            Text(String(localized: "轻点 △ 导入 .psu 或 .max 存档"))
                .font(.system(size: 13, weight: .light, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -30)
    }

    // MARK: Action panel

    private var actionPanel: some View {
        VStack(spacing: 6) {
            ForEach(PanelAction.allCases, id: \.self) { action in
                Button {
                    panelHighlight = action
                    PS2BrowserHaptics.tap()
                    perform(action)
                } label: {
                    Text(title(for: action))
                        .font(.system(size: 21, weight: .light, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .buttonStyle(PS2MenuButtonStyle(highlighted: panelHighlight == action))
                .disabled(busy)
            }
        }
        .frame(maxWidth: 300)
        .padding(.horizontal, 40)
    }

    private func title(for action: PanelAction) -> String {
        switch action {
        case .copy: String(localized: "复制")
        case .delete: String(localized: "删除")
        case .back: String(localized: "返回")
        }
    }

    private func perform(_ action: PanelAction) {
        guard let save = selected else { return }
        switch action {
        case .copy: beginExport(save)
        case .delete: prompt = .delete(save)
        case .back: focused = false
        }
    }

    // MARK: Hint bar

    private var hintBar: some View {
        HStack(spacing: 20) {
            if !focused {
                hint(.triangle, String(localized: "导入")) { isImporting = true }
                Spacer(minLength: 0)
                hint(.circle, String(localized: "确定")) {
                    if selected != nil { focusSelected() }
                }
                .opacity(selected == nil ? 0.4 : 1)
            } else {
                Spacer(minLength: 0)
            }
            hint(.cross, String(localized: "返回")) {
                if focused { focused = false } else { onClose() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .disabled(busy || prompt != nil)
    }

    private func hint(_ kind: PS2ButtonGlyph.Kind, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            PS2BrowserHaptics.tap()
            action()
        } label: {
            HStack(spacing: 7) {
                PS2ButtonGlyph(kind: kind, size: 22)
                Text(label)
                    .font(.system(size: 15, weight: .light, design: .rounded))
                    .ps2Glow(0.6)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Prompts

    @ViewBuilder
    private func promptView(_ prompt: Prompt) -> some View {
        switch prompt {
        case .delete(let save):
            PS2Dialog(message: String(localized: "确定要删除这个存档吗？"),
                      detail: save.titleLines.filter { !$0.isEmpty }.joined(separator: "\n"),
                      options: [
                        .init(title: String(localized: "是")) { self.prompt = nil; delete(save) },
                        .init(title: String(localized: "否"), isDefault: true) { self.prompt = nil },
                      ])
        case .overwrite(let url, let name):
            PS2Dialog(message: String(localized: "记忆卡上已有同名存档，要覆盖吗？"), detail: name,
                      options: [
                        .init(title: String(localized: "是")) { self.prompt = nil; runImport(url, overwrite: true) },
                        .init(title: String(localized: "否"), isDefault: true) {
                            self.prompt = nil
                            try? FileManager.default.removeItem(at: url)
                        },
                      ])
        case .message(let text):
            PS2Dialog(message: text, detail: nil,
                      options: [.init(title: String(localized: "确定"), isDefault: true) { self.prompt = nil }])
        }
    }

    private func showToast(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.3))
            if toast == text { toast = nil }
        }
    }

    private func showError(_ error: Error) {
        prompt = .message((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    // MARK: Selection

    private func handleTap(_ id: String?) {
        guard !focused, prompt == nil, let id else { return }
        if id == selectedID {
            focusSelected()
        } else {
            selectedID = id
            PS2BrowserHaptics.select()
        }
    }

    private func focusSelected() {
        panelHighlight = .copy
        focused = true
    }

    // MARK: Card I/O

    private func reload(select name: String? = nil) async {
        let card = card
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[PS2BrowserSave], Error> in
            do { return .success(try card.saves().map(PS2BrowserSave.load)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let list):
            let previousIndex = saves.firstIndex { $0.id == selectedID } ?? 0
            saves = list
            if let name, list.contains(where: { $0.id == name }) {
                selectedID = name
            } else if !list.contains(where: { $0.id == selectedID }) {
                selectedID = list.isEmpty ? nil : list[min(previousIndex, list.count - 1)].id
            }
        case .failure(let error):
            showError(error)
        }
        if !loaded {
            loaded = true
            #if DEBUG
            applyDebugLaunchState()
            #endif
        }
    }

    private func beginExport(_ save: PS2BrowserSave) {
        let card = card
        busy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
                Result { try card.archive(for: save.entry).psuData() }
            }.value
            busy = false
            switch result {
            case .success(let data):
                exportName = save.entry.name
                exportDocument = PS2PSUDocument(data: data)
                isExporting = true
            case .failure(let error):
                showError(error)
            }
        }
    }

    private func delete(_ save: PS2BrowserSave) {
        let card = card
        busy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try card.delete(save.entry) } }.value
            busy = false
            focused = false
            switch result {
            case .success:
                await reload()
                showToast(String(localized: "删除完成"))
            case .failure(let error):
                await reload()
                showError(error)
            }
        }
    }

    /// Copies the picked file out of its security scope first, so an overwrite retry can use it later.
    private func beginImport(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "psu" : url.pathExtension
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("ps2-import-\(UUID().uuidString)").appendingPathExtension(ext)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            showError(error)
            return
        }
        runImport(copy, overwrite: false)
    }

    private func runImport(_ url: URL, overwrite: Bool) {
        let card = card
        busy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try card.importArchive(at: url, overwrite: overwrite) }
            }.value
            busy = false
            switch result {
            case .success(let entry):
                try? FileManager.default.removeItem(at: url)
                focused = false
                await reload(select: entry.name)
                PS2BrowserHaptics.tap()
                showToast(String(localized: "导入完成"))
            case .failure(PS2SaveError.alreadyExists(let name)):
                prompt = .overwrite(url, name)
            case .failure(let error):
                try? FileManager.default.removeItem(at: url)
                showError(error)
            }
        }
    }

    // MARK: Helpers

    private var tintColors: [Color]? {
        guard let sys = selected?.iconSys, sys.backgroundOpacity > 0 else { return nil }
        let c = sys.backgroundColorsNormalized
        guard c.count == 4 else { return nil }
        return c.map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) }
    }

    private var tintOpacity: Double {
        guard let sys = selected?.iconSys else { return 0 }
        return Double(sys.backgroundOpacity) * (focused ? 0.55 : 0.18)
    }

    static func kbString(_ bytes: Int64) -> String {
        "\(((bytes + 1023) / 1024).formatted(.number.grouping(.automatic))) KB"
    }

    #if DEBUG
    /// `-ps2-save-browser-select <index>` / `-ps2-save-browser-focus` for screenshots.
    private func applyDebugLaunchState() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-ps2-save-browser-select"), i + 1 < args.count,
           let index = Int(args[i + 1]), saves.indices.contains(index) {
            selectedID = saves[index].id
        }
        if args.contains("-ps2-save-browser-focus"), selected != nil {
            focused = true
        }
    }
    #endif
}

// MARK: - PS2-style pieces

private enum PS2BrowserHaptics {
    @MainActor static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    @MainActor static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7) }
}

extension View {
    /// Soft white-blue halo around thin type, like the PS2 browser text.
    func ps2Glow(_ strength: Double = 1) -> some View {
        shadow(color: Color(red: 0.55, green: 0.72, blue: 1).opacity(0.85 * strength), radius: 6)
            .shadow(color: .white.opacity(0.4 * strength), radius: 1.5)
    }
}

/// Controller face-button symbol in a small dark disc (vector, no artwork).
struct PS2ButtonGlyph: View {
    enum Kind { case circle, cross, triangle, square }
    let kind: Kind
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.34), Color(white: 0.1)],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.75))
            Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
            symbol.frame(width: size * 0.48, height: size * 0.48)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.35), radius: 3)
    }

    private var color: Color {
        switch kind {
        case .circle: Color(red: 1, green: 0.38, blue: 0.45)
        case .cross: Color(red: 0.5, green: 0.68, blue: 1)
        case .triangle: Color(red: 0.3, green: 0.9, blue: 0.7)
        case .square: Color(red: 0.95, green: 0.55, blue: 0.85)
        }
    }

    @ViewBuilder private var symbol: some View {
        let lw = max(1.5, size * 0.085)
        switch kind {
        case .circle:
            Circle().stroke(color, lineWidth: lw)
        case .cross:
            PS2CrossShape().stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .padding(size * 0.03)
        case .triangle:
            PS2TriangleShape().stroke(color, style: StrokeStyle(lineWidth: lw, lineJoin: .round))
                .offset(y: -size * 0.02)
        case .square:
            Rectangle().stroke(color, lineWidth: lw).padding(size * 0.04)
        }
    }
}

private struct PS2CrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return p
    }
}

private struct PS2TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.06))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.1))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.1))
        p.closeSubpath()
        return p
    }
}

/// Menu row: glowing text on a soft horizontal light bar when highlighted or pressed.
private struct PS2MenuButtonStyle: ButtonStyle {
    let highlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        let lit = highlighted || configuration.isPressed
        configuration.label
            .foregroundStyle(.white.opacity(lit ? 1 : 0.7))
            .ps2Glow(lit ? 1 : 0.3)
            .background {
                ZStack {
                    LinearGradient(colors: [.clear, Color(red: 0.35, green: 0.5, blue: 1).opacity(0.42), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                    VStack {
                        glowLine
                        Spacer()
                        glowLine
                    }
                }
                .opacity(lit ? (configuration.isPressed ? 1 : 0.8) : 0)
            }
            .contentShape(Rectangle())
    }

    private var glowLine: some View {
        LinearGradient(colors: [.clear, .white.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
            .shadow(color: Color(red: 0.6, green: 0.75, blue: 1), radius: 3)
    }
}

/// Centered PS2-style message with a row of options (default one highlighted).
private struct PS2Dialog: View {
    struct Option: Identifiable {
        let title: String
        var isDefault = false
        let action: () -> Void
        var id: String { title }
    }

    let message: String
    let detail: String?
    let options: [Option]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 18) {
                Text(message)
                    .font(.system(size: 19, weight: .light, design: .rounded))
                    .multilineTextAlignment(.center)
                    .ps2Glow()
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 14, weight: .light, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.7))
                }
                if !options.isEmpty {
                    HStack(spacing: 16) {
                        ForEach(options) { option in
                            Button {
                                PS2BrowserHaptics.tap()
                                option.action()
                            } label: {
                                Text(option.title)
                                    .font(.system(size: 19, weight: .light, design: .rounded))
                                    .frame(width: 96, height: 42)
                            }
                            .buttonStyle(PS2MenuButtonStyle(highlighted: option.isDefault))
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: 340)
            .background {
                LinearGradient(colors: [.clear, Color(red: 0.12, green: 0.18, blue: 0.4).opacity(0.55), .clear],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - Backdrop

/// Dark void with slowly drifting blue/purple/teal haze and its faint reflection on the floor.
private struct PS2BrowserBackdrop: View {
    let paused: Bool
    let tint: [Color]?
    let tintOpacity: Double

    private struct Blob {
        var x: CGFloat, y: CGFloat, r: CGFloat, stretch: CGFloat
        var color: (Double, Double, Double), alpha: Double
        var speed: Double, ax: CGFloat, ay: CGFloat, phase: Double
    }

    /// Positions are fractions of width / horizon height; radius is a fraction of width.
    private static let blobs: [Blob] = [
        Blob(x: 0.18, y: 0.30, r: 0.55, stretch: 1.7, color: (0.16, 0.26, 0.78), alpha: 0.42, speed: 0.050, ax: 0.18, ay: 0.10, phase: 0.0),
        Blob(x: 0.80, y: 0.22, r: 0.50, stretch: 1.9, color: (0.42, 0.20, 0.72), alpha: 0.36, speed: 0.041, ax: 0.20, ay: 0.08, phase: 1.7),
        Blob(x: 0.55, y: 0.62, r: 0.62, stretch: 2.2, color: (0.08, 0.48, 0.58), alpha: 0.34, speed: 0.036, ax: 0.25, ay: 0.12, phase: 3.1),
        Blob(x: 0.30, y: 0.80, r: 0.45, stretch: 2.6, color: (0.22, 0.34, 0.90), alpha: 0.28, speed: 0.058, ax: 0.22, ay: 0.06, phase: 4.4),
        Blob(x: 0.88, y: 0.70, r: 0.40, stretch: 1.6, color: (0.30, 0.18, 0.62), alpha: 0.30, speed: 0.047, ax: 0.14, ay: 0.10, phase: 5.2),
        Blob(x: 0.50, y: 0.08, r: 0.40, stretch: 2.8, color: (0.12, 0.40, 0.66), alpha: 0.22, speed: 0.033, ax: 0.30, ay: 0.05, phase: 2.3),
        Blob(x: 0.10, y: 0.55, r: 0.35, stretch: 3.4, color: (0.10, 0.55, 0.62), alpha: 0.20, speed: 0.063, ax: 0.20, ay: 0.08, phase: 0.9),
        Blob(x: 0.70, y: 0.45, r: 0.28, stretch: 4.0, color: (0.55, 0.45, 0.95), alpha: 0.16, speed: 0.071, ax: 0.26, ay: 0.07, phase: 3.8),
    ]

    private static let horizon: CGFloat = 0.72
    private static let wisps: CGImage? = PS2BrowserBackdrop.makeWispTexture()

    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: Color(red: 0.012, green: 0.016, blue: 0.045), location: 0),
                .init(color: Color(red: 0.030, green: 0.040, blue: 0.095), location: Self.horizon),
                .init(color: Color(red: 0.010, green: 0.012, blue: 0.030), location: 1),
            ], startPoint: .top, endPoint: .bottom)

            if let tint, tintOpacity > 0 {
                MeshGradient(width: 2, height: 2,
                             points: [[0, 0], [1, 0], [0, 1], [1, 1]],
                             colors: tint)
                    .opacity(tintOpacity)
                    .blendMode(.plusLighter)
                    .animation(.easeInOut(duration: 0.5), value: tintOpacity)
            }

            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: paused)) { timeline in
                Canvas { context, size in
                    draw(&context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time t: Double) {
        let w = size.width, horizonY = size.height * Self.horizon
        context.blendMode = .plusLighter

        func blob(_ b: Blob, mirrored: Bool) {
            let cx = (b.x + b.ax * CGFloat(sin(t * b.speed + b.phase))) * w
            let skyY = (b.y + b.ay * CGFloat(cos(t * b.speed * 0.8 + b.phase * 1.3))) * horizonY
            let pulse = 0.75 + 0.25 * sin(t * b.speed * 1.9 + b.phase)
            let r = b.r * w
            var layer = context
            if mirrored {
                layer.translateBy(x: cx, y: horizonY + (horizonY - skyY) * 0.42)
                layer.scaleBy(x: b.stretch, y: 0.42)
                layer.opacity = 0.32
            } else {
                layer.translateBy(x: cx, y: skyY)
                layer.scaleBy(x: b.stretch, y: 1)
            }
            let c = Color(red: b.color.0, green: b.color.1, blue: b.color.2)
            layer.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)),
                       with: .radialGradient(Gradient(stops: [
                        .init(color: c.opacity(b.alpha * pulse), location: 0),
                        .init(color: c.opacity(b.alpha * pulse * 0.35), location: 0.45),
                        .init(color: c.opacity(0), location: 1),
                       ]), center: .zero, startRadius: 0, endRadius: r))
        }

        for b in Self.blobs { blob(b, mirrored: false) }

        // Wispy fog: a soft tileable noise texture drifting at two scales.
        if let wisps = Self.wisps {
            let image = context.resolve(Image(decorative: wisps, scale: 1))
            for (scale, speed, alpha) in [(1.9, 5.0, 0.55), (1.2, -8.0, 0.35)] as [(CGFloat, Double, Double)] {
                let tile = w * scale
                let offset = CGFloat((t * speed).truncatingRemainder(dividingBy: Double(tile)))
                var layer = context
                layer.opacity = alpha
                var x = offset - tile
                while x < w {
                    layer.draw(image, in: CGRect(x: x, y: horizonY - tile * 0.72, width: tile, height: tile * 0.9))
                    x += tile
                }
            }
        }

        for b in Self.blobs where b.y > 0.35 { blob(b, mirrored: true) }

        // Floor horizon glow.
        let band = CGRect(x: 0, y: horizonY - 30, width: w, height: 60)
        context.fill(Path(band), with: .linearGradient(Gradient(colors: [
            .clear, Color(red: 0.3, green: 0.45, blue: 0.9).opacity(0.10), .clear,
        ]), startPoint: CGPoint(x: 0, y: band.minY), endPoint: CGPoint(x: 0, y: band.maxY)))
        context.fill(Path(CGRect(x: 0, y: horizonY, width: w, height: 1)),
                     with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.10), .clear]),
                                           startPoint: .zero, endPoint: CGPoint(x: w, y: 0)))

        // Darken toward the bottom so the floor reads as a glossy surface.
        context.blendMode = .normal
        context.fill(Path(CGRect(x: 0, y: horizonY, width: w, height: size.height - horizonY)),
                     with: .linearGradient(Gradient(colors: [.clear, .black.opacity(0.45)]),
                                           startPoint: CGPoint(x: 0, y: horizonY),
                                           endPoint: CGPoint(x: 0, y: size.height)))
    }

    /// 128² tileable fractal value noise as a pale blue alpha texture.
    private static func makeWispTexture() -> CGImage? {
        let n = 128
        var rng = SystemRandomNumberGenerator()
        func lattice(_ cells: Int) -> [Float] { (0..<(cells * cells)).map { _ in Float.random(in: 0...1, using: &rng) } }
        let octaves: [(cells: Int, amp: Float)] = [(4, 0.55), (8, 0.27), (16, 0.12), (32, 0.06)]
        let grids = octaves.map { lattice($0.cells) }
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                var v: Float = 0
                for (o, (cells, amp)) in octaves.enumerated() {
                    let fx = Float(x) / Float(n) * Float(cells), fy = Float(y) / Float(n) * Float(cells)
                    let x0 = Int(fx) % cells, y0 = Int(fy) % cells
                    let x1 = (x0 + 1) % cells, y1 = (y0 + 1) % cells
                    var tx = fx - Float(Int(fx)), ty = fy - Float(Int(fy))
                    tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty)
                    let g = grids[o]
                    let a = g[y0 * cells + x0] + (g[y0 * cells + x1] - g[y0 * cells + x0]) * tx
                    let b = g[y1 * cells + x0] + (g[y1 * cells + x1] - g[y1 * cells + x0]) * tx
                    v += (a + (b - a) * ty) * amp
                }
                // Fade the top and bottom so the strip blends in; keep only the brighter wisps.
                let edge = sin(Float(y) / Float(n - 1) * .pi)
                let alpha = max(0, v - 0.42) / 0.58 * edge
                let a = alpha * alpha * 0.9
                let i = (y * n + x) * 4
                pixels[i] = UInt8(min(255, a * 0.55 * 255))       // premultiplied RGB
                pixels[i + 1] = UInt8(min(255, a * 0.70 * 255))
                pixels[i + 2] = UInt8(min(255, a * 1.00 * 255))
                pixels[i + 3] = UInt8(min(255, a * 255))
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - SceneKit icon grid

private struct PS2IconGridView: UIViewRepresentable {
    let stage: PS2IconStage
    let saves: [PS2BrowserSave]
    let selectedID: String?
    let focused: Bool
    let paused: Bool
    let onTap: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(stage: stage) }

    func makeUIView(context: Context) -> PS2IconSCNView {
        let view = PS2IconSCNView(frame: .zero)
        view.scene = stage.scene
        view.pointOfView = stage.cameraNode
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.isPlaying = true
        view.onLayout = { [weak stage] size in stage?.layout(viewSize: size) }
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        view.isAccessibilityElement = true
        view.accessibilityLabel = String(localized: "存档图标")
        return view
    }

    func updateUIView(_ view: PS2IconSCNView, context: Context) {
        context.coordinator.onTap = onTap
        stage.update(saves: saves, selectedID: selectedID, focused: focused)
        stage.setPaused(paused)
        view.isPlaying = !paused
        view.rendersContinuously = !paused
    }

    static func dismantleUIView(_ view: PS2IconSCNView, coordinator: Coordinator) {
        view.isPlaying = false
        coordinator.stage.setPaused(true)
    }

    @MainActor
    final class Coordinator: NSObject {
        let stage: PS2IconStage
        var onTap: (String?) -> Void = { _ in }

        init(stage: PS2IconStage) { self.stage = stage }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            let hits = view.hitTest(gesture.location(in: view), options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .ignoreHiddenNodes: true,
            ])
            onTap(hits.lazy.compactMap { self.stage.saveID(for: $0.node) }.first)
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .changed:
                stage.scroll(byPoints: gesture.translation(in: view).y)
                gesture.setTranslation(.zero, in: view)
            case .ended, .cancelled:
                stage.endScroll(velocity: gesture.velocity(in: view).y)
            default: break
            }
        }
    }
}

final class PS2IconSCNView: SCNView {
    var onLayout: (@MainActor (CGSize) -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size)
    }
}

/// Scene with one floating, spinning icon per save laid out in a grid; camera scrolls over the rows
/// and flies up to the selected icon when its action panel is open.
@MainActor
final class PS2IconStage: ObservableObject {
    private final class Slot {
        let id: String
        let anchor = SCNNode()
        let spinner = SCNNode()
        let mirrorSpinner = SCNNode()
        let glow: SCNNode
        var column = 0, row = 0
        var spinPeriod: Double = 0
        var visible = true

        init(id: String, glow: SCNNode) { self.id = id; self.glow = glow }
        var gridPosition: SIMD3<Float> { anchor.simdPosition }
    }

    static let spacingX: Float = 1.38
    static let spacingY: Float = 1.9
    private static let fieldOfView: Float = 40 * .pi / 180
    private static let tilt: Float = 7 * .pi / 180
    private static let defaultLightMask = 1 << 30

    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let gridRoot = SCNNode()
    private let lightRoot = SCNNode()
    private var slots: [Slot] = []
    private var entries: [PS2SaveEntry] = []
    private var columns = 3
    private var viewSize = CGSize(width: 390, height: 480)
    private var scrollY: Float = 0
    private var selectedID: String?
    private var focused = false
    private var paused = false

    init() {
        scene.background.contents = UIColor.clear
        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(Self.fieldOfView * 180 / .pi)
        camera.projectionDirection = .horizontal
        camera.zNear = 0.1
        camera.zFar = 80
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(gridRoot)
        scene.rootNode.addChildNode(lightRoot)
        addDefaultLights()
        scrollY = scrollRange.upperBound
        placeCamera(animated: false)
    }

    // MARK: State from SwiftUI

    func update(saves: [PS2BrowserSave], selectedID: String?, focused: Bool) {
        let newEntries = saves.map(\.entry)
        var needsCamera = false
        if newEntries != entries {
            entries = newEntries
            rebuild(saves)
            needsCamera = true
        }
        if selectedID != self.selectedID || needsCamera {
            self.selectedID = selectedID
            applySelection()
            if !focused { revealSelection() }
            needsCamera = true
        }
        if focused != self.focused {
            self.focused = focused
            applySelection()
            needsCamera = true
        }
        if needsCamera { placeCamera(animated: true) }
    }

    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        scene.isPaused = paused
    }

    func layout(viewSize size: CGSize) {
        guard size.width > 1, size.height > 1, size != viewSize else { return }
        viewSize = size
        let newColumns = max(3, min(6, Int(size.width / 125)))
        if newColumns != columns {
            columns = newColumns
            positionSlots()
        }
        scrollY = min(max(scrollY, scrollRange.lowerBound), scrollRange.upperBound)
        revealSelection()
        placeCamera(animated: false)
    }

    func saveID(for node: SCNNode) -> String? {
        var current: SCNNode? = node
        while let n = current {
            if let name = n.name, name.hasPrefix("ps2-slot:") { return String(name.dropFirst("ps2-slot:".count)) }
            current = n.parent
        }
        return nil
    }

    // MARK: Scrolling

    private var halfWidth: Float { Float(columns) * Self.spacingX / 2 + 0.15 }
    private var aspect: Float { Float(viewSize.height / max(viewSize.width, 1)) }
    private var gridDistance: Float { halfWidth / tan(Self.fieldOfView / 2) }
    private var gridHalfHeight: Float { halfWidth * aspect }
    private var rowCount: Int { (slots.count + columns - 1) / columns }

    private var scrollRange: ClosedRange<Float> {
        let top = 1.5 - gridHalfHeight
        let bottom = min(top, -Float(max(rowCount - 1, 0)) * Self.spacingY - 0.8 + gridHalfHeight)
        return bottom...top
    }

    func scroll(byPoints dy: CGFloat) {
        guard !focused else { return }
        let perPoint = 2 * halfWidth / Float(max(viewSize.width, 1))
        let range = scrollRange
        var y = scrollY + Float(dy) * perPoint
        if y > range.upperBound { y = range.upperBound + (y - range.upperBound) * 0.4 }
        if y < range.lowerBound { y = range.lowerBound + (y - range.lowerBound) * 0.4 }
        scrollY = y
        placeCamera(animated: false)
    }

    func endScroll(velocity: CGFloat) {
        guard !focused else { return }
        let perPoint = 2 * halfWidth / Float(max(viewSize.width, 1))
        scrollY = min(max(scrollY + Float(velocity) * perPoint * 0.25, scrollRange.lowerBound), scrollRange.upperBound)
        placeCamera(animated: true, duration: 0.45)
    }

    /// Scrolls just enough to bring the selected row into view.
    private func revealSelection() {
        guard let slot = slots.first(where: { $0.id == selectedID }) else { return }
        let y = slot.gridPosition.y
        let range = scrollRange
        let top = y + 1.5 - gridHalfHeight          // icon near the top edge
        let bottom = y - 0.8 + gridHalfHeight        // reflection near the bottom edge
        if scrollY > bottom { scrollY = bottom }
        if scrollY < top { scrollY = top }
        scrollY = min(max(scrollY, range.lowerBound), range.upperBound)
    }

    // MARK: Camera

    private func placeCamera(animated: Bool, duration: Double = 0.55) {
        let position: SIMD3<Float>
        let target: SIMD3<Float>
        if focused, let slot = slots.first(where: { $0.id == selectedID }) {
            // Icon fills ~38 % of the view height in the upper part; the action panel sits below.
            let tanV = tan(Self.fieldOfView / 2) * aspect
            let halfH: Float = 1.25 / 0.38 / 2
            let distance = halfH / tanV
            let center = slot.gridPosition + SIMD3(0, 0.62, 0)
            target = center - SIMD3(0, halfH * 0.42, 0)
            position = target + SIMD3(0, sin(Self.tilt) * 0.5, cos(Self.tilt * 0.5)) * distance
        } else {
            target = SIMD3(0, scrollY, 0)
            position = target + SIMD3(0, sin(Self.tilt), cos(Self.tilt)) * gridDistance
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? duration : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cameraNode.simdPosition = position
        cameraNode.simdLook(at: target, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        SCNTransaction.commit()
        updateVisibility(cameraTargetY: target.y, halfHeight: focused ? 3 : gridHalfHeight)
    }

    /// Hides and pauses rows that are off screen (their morph animations stop costing CPU).
    private func updateVisibility(cameraTargetY y: Float, halfHeight: Float) {
        let low = y - halfHeight - 1.2, high = y + halfHeight + 1.2
        for slot in slots {
            let sy = slot.gridPosition.y
            let visible = sy + 1.6 >= low && sy - 1 <= high && (!focused || slot.id == selectedID)
            if visible != slot.visible {
                slot.visible = visible
                slot.anchor.isPaused = !visible
                if visible { slot.anchor.isHidden = false }
            }
            // Hide after the fade-out when focusing; immediately when scrolled away.
            if !visible && !focused { slot.anchor.isHidden = true }
        }
    }

    // MARK: Building

    private func rebuild(_ saves: [PS2BrowserSave]) {
        gridRoot.childNodes.forEach { $0.removeFromParentNode() }
        lightRoot.childNodes.forEach { $0.removeFromParentNode() }
        slots = []
        for (index, save) in saves.enumerated() {
            let mask = index < 30 ? 1 << index : Self.defaultLightMask
            let lit = mask != Self.defaultLightMask && addLights(for: save.iconSys, mask: mask)
            let slot = makeSlot(save, lightMask: lit ? mask : Self.defaultLightMask, phase: Double(index) * 0.37)
            slots.append(slot)
            gridRoot.addChildNode(slot.anchor)
        }
        positionSlots()
        scrollY = min(max(scrollY, scrollRange.lowerBound), scrollRange.upperBound)
    }

    private func positionSlots() {
        for (index, slot) in slots.enumerated() {
            slot.column = index % columns
            slot.row = index / columns
            slot.anchor.simdPosition = SIMD3(
                (Float(slot.column) - Float(columns - 1) / 2) * Self.spacingX,
                -Float(slot.row) * Self.spacingY, 0)
        }
    }

    private func makeSlot(_ save: PS2BrowserSave, lightMask: Int, phase: Double) -> Slot {
        let slot = Slot(id: save.id, glow: Self.makeGlowNode())
        slot.anchor.name = "ps2-slot:\(save.id)"

        let mesh = save.icon.flatMap(PS2IconMeshBuilder.build)
        func model() -> SCNNode {
            let node = mesh?.makeNode() ?? PS2IconMeshBuilder.placeholderNode()
            node.enumerateHierarchy { n, _ in n.categoryBitMask = lightMask }
            return node
        }

        // Icon: anchor → bob → spinner → model.
        let bob = SCNNode()
        bob.addChildNode(slot.spinner)
        slot.spinner.addChildNode(model())
        slot.anchor.addChildNode(bob)

        // Floor reflection: the same icon mirrored (and squashed) below y = 0.
        let mirror = SCNNode()
        mirror.simdScale = SIMD3(1, -0.5, 1)
        mirror.opacity = 0.2
        let mirrorBob = SCNNode()
        mirrorBob.addChildNode(slot.mirrorSpinner)
        slot.mirrorSpinner.addChildNode(model())
        mirror.addChildNode(mirrorBob)
        slot.anchor.addChildNode(mirror)

        slot.anchor.addChildNode(slot.glow)

        // Invisible hit target larger than the icon.
        let hitBox = SCNBox(width: CGFloat(Self.spacingX * 0.9), height: 1.7, length: 0.9, chamferRadius: 0)
        let hitMaterial = SCNMaterial()
        hitMaterial.colorBufferWriteMask = []
        hitMaterial.writesToDepthBuffer = false
        hitBox.materials = [hitMaterial]
        let hit = SCNNode(geometry: hitBox)
        hit.simdPosition = SIMD3(0, 0.45, 0)
        slot.anchor.addChildNode(hit)

        let up = SCNAction.moveBy(x: 0, y: 0.05, z: 0, duration: 1.7)
        up.timingMode = .easeInEaseOut
        let bobAction = SCNAction.sequence([.wait(duration: phase.truncatingRemainder(dividingBy: 3.4)),
                                            .repeatForever(.sequence([up, up.reversed()]))])
        bob.runAction(bobAction, forKey: "bob")
        mirrorBob.runAction(bobAction, forKey: "bob")
        slot.spinner.eulerAngles.y = Float(phase)
        slot.mirrorSpinner.eulerAngles.y = Float(phase)
        return slot
    }

    private func applySelection() {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        for slot in slots {
            let isSelected = slot.id == selectedID
            let period: Double = isSelected ? 3.6 : 14
            if period != slot.spinPeriod {
                slot.spinPeriod = period
                for spinner in [slot.spinner, slot.mirrorSpinner] {
                    spinner.removeAction(forKey: "spin")
                    spinner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: period)), forKey: "spin")
                }
            }
            let scale: Float = isSelected ? 1.22 : 0.9
            slot.spinner.simdScale = SIMD3(repeating: scale)
            slot.mirrorSpinner.simdScale = SIMD3(repeating: scale)
            slot.glow.opacity = isSelected ? 1 : 0
            slot.anchor.opacity = focused ? (isSelected ? 1 : 0) : (isSelected ? 1 : 0.62)
        }
        SCNTransaction.commit()
    }

    // MARK: Lights

    private func addDefaultLights() {
        let key = SCNLight()
        key.type = .directional
        key.color = UIColor(white: 0.85, alpha: 1)
        key.categoryBitMask = Self.defaultLightMask
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.simdPosition = SIMD3(2, 4, 5)
        keyNode.simdLook(at: .zero)
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = UIColor(white: 0.4, alpha: 1)
        ambient.categoryBitMask = Self.defaultLightMask
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(keyNode)
        scene.rootNode.addChildNode(ambientNode)
    }

    /// Adds the three directional lights + ambient from `icon.sys`. Returns false when it defines none.
    /// Directions are in the icon's y-down space and point toward the light.
    private func addLights(for sys: PS2IconSys?, mask: Int) -> Bool {
        guard let sys else { return false }
        func color(_ v: SIMD4<Float>) -> UIColor? {
            let c = SIMD3(v.x, v.y, v.z)
            guard c.x.isFinite, c.y.isFinite, c.z.isFinite else { return nil }
            let clamped = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
            guard clamped.max() > 0.001 else { return nil }
            return UIColor(red: CGFloat(clamped.x), green: CGFloat(clamped.y), blue: CGFloat(clamped.z), alpha: 1)
        }
        var added = false
        for (dir, col) in zip(sys.lightDirections, sys.lightColors) {
            let d = SIMD3(dir.x, -dir.y, -dir.z)
            guard let c = color(col), d.x.isFinite, d.y.isFinite, d.z.isFinite, simd_length(d) > 0.0001 else { continue }
            let light = SCNLight()
            light.type = .directional
            light.color = c
            light.categoryBitMask = mask
            let node = SCNNode()
            node.light = light
            let n = simd_normalize(d)
            node.simdPosition = n * 5
            let up: SIMD3<Float> = abs(n.y) > 0.98 ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
            node.simdLook(at: .zero, up: up, localFront: SIMD3(0, 0, -1))
            lightRoot.addChildNode(node)
            added = true
        }
        if let c = color(sys.ambient) {
            let light = SCNLight()
            light.type = .ambient
            light.color = c
            light.categoryBitMask = mask
            let node = SCNNode()
            node.light = light
            lightRoot.addChildNode(node)
            added = true
        }
        return added
    }

    // MARK: Glow

    private static let glowImage: UIImage = {
        let size = CGSize(width: 128, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 0.75, green: 0.85, blue: 1, alpha: 0.9).cgColor,
                          UIColor(red: 0.35, green: 0.5, blue: 1, alpha: 0.35).cgColor,
                          UIColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 0).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.35, 1])!
            ctx.cgContext.drawRadialGradient(gradient, startCenter: CGPoint(x: 64, y: 64), startRadius: 0,
                                             endCenter: CGPoint(x: 64, y: 64), endRadius: 64, options: [])
        }
    }()

    private static func makeGlowNode() -> SCNNode {
        let plane = SCNPlane(width: 1.5, height: 1.5)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = glowImage
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.simdPosition = SIMD3(0, 0.002, 0)
        node.opacity = 0
        node.renderingOrder = -1
        return node
    }
}

// MARK: - Icon geometry

/// SceneKit geometry for one PS2 icon (shared by the icon and its reflection).
struct PS2IconMesh {
    let geometry: SCNGeometry
    let targets: [SCNGeometry]
    let initialWeights: [Float]
    let animations: [(key: String, animation: CAAnimation)]

    @MainActor
    func makeNode() -> SCNNode {
        let node = SCNNode(geometry: geometry)
        if !targets.isEmpty {
            let morpher = SCNMorpher()
            morpher.targets = targets
            morpher.calculationMode = .normalized
            node.morpher = morpher
            for (i, w) in initialWeights.enumerated() { morpher.setWeight(CGFloat(w), forTargetAt: i) }
            for (key, animation) in animations {
                node.addAnimation(SCNAnimation(caAnimation: animation), forKey: key)
            }
        }
        return node
    }
}

enum PS2IconMeshBuilder {
    /// Icon space → scene: PS2 icons are y-down; rotating 180° about x keeps handedness and faces them
    /// toward the camera. Result is centred on x/z, standing on y = 0, about one unit tall.
    static func build(_ icon: PS2Icon) -> PS2IconMesh? {
        let count = icon.vertexCount / 3 * 3
        guard count >= 3, icon.shapes.allSatisfy({ $0.count >= count }) else { return nil }
        func flip(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, -p.y, -p.z) }

        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for shape in icon.shapes {
            for i in 0..<count {
                let p = flip(shape[i])
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
        }
        guard lo.x <= hi.x else { return nil }
        let size = hi - lo
        let scale = 1 / max(size.y, max(size.x, size.z) / 1.15, 1e-4)
        let offset = SIMD3(-(lo.x + hi.x) / 2, -lo.y, -(lo.z + hi.z) / 2)

        func vertices(_ shape: [SIMD3<Float>]) -> SCNGeometrySource {
            SCNGeometrySource(vertices: (0..<count).map { i in
                let p = flip(shape[i])
                let q = p.x.isFinite && p.y.isFinite && p.z.isFinite ? (p + offset) * scale : .zero
                return SCNVector3(q.x, q.y, q.z)
            })
        }
        let normals = SCNGeometrySource(normals: (0..<count).map { i in
            let n = flip(icon.normals[i])
            let l = simd_length(n)
            let u = l > 1e-5 && l.isFinite ? n / l : SIMD3<Float>(0, 1, 0)
            return SCNVector3(u.x, u.y, u.z)
        })
        let element = SCNGeometryElement(indices: (0..<UInt32(count)).map { $0 }, primitiveType: .triangles)

        var sources = [vertices(icon.shapes[0]), normals]
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.isDoubleSided = true
        if let texture = icon.texture, let image = cgImage(texture) {
            sources.append(SCNGeometrySource(textureCoordinates: (0..<count).map { i in
                CGPoint(x: CGFloat(icon.uvs[i].x), y: CGFloat(icon.uvs[i].y))
            }))
            material.diffuse.contents = image
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .repeat
            material.diffuse.mipFilter = .linear
        } else {
            // 0x80 = full intensity; ignore vertex alpha when no vertex uses it.
            let useAlpha = icon.usesVertexAlpha
            var floats = [Float]()
            floats.reserveCapacity(count * 4)
            for i in 0..<count {
                let c = icon.colors[i]
                floats += [min(Float(c.x) / 128, 1), min(Float(c.y) / 128, 1), min(Float(c.z) / 128, 1),
                           useAlpha ? min(Float(c.w) / 128, 1) : 1]
            }
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: data, semantic: .color, vectorCount: count,
                                             usesFloatComponents: true, componentsPerVector: 4,
                                             bytesPerComponent: 4, dataOffset: 0, dataStride: 16))
            material.diffuse.contents = UIColor.white
        }
        let geometry = SCNGeometry(sources: sources, elements: [element])
        geometry.materials = [material]

        guard icon.shapeCount > 1 else {
            return PS2IconMesh(geometry: geometry, targets: [], initialWeights: [], animations: [])
        }

        // Morph targets = shapes 1…n; with `.normalized` the base (shape 0) gets 1 - Σ weights.
        let targets = icon.shapes.dropFirst().map { SCNGeometry(sources: [vertices($0), normals], elements: [element]) }
        let initial = Array(icon.shapeWeights(atFrame: 0).dropFirst())
        var animations: [(String, CAAnimation)] = []
        let frames = Double(icon.animation.frameLength)
        if frames > 0 {
            let steps = min(max(Int(frames * 4), 2), 2048)
            let samples = (0...steps).map { icon.shapeWeights(atFrame: frames * Double($0) / Double(steps)) }
            let keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
            for target in 1..<icon.shapeCount {
                let values = samples.map { NSNumber(value: $0[target]) }
                guard Set(values.map(\.floatValue)).count > 1 else { continue }
                let anim = CAKeyframeAnimation(keyPath: "morpher.weights[\(target - 1)]")
                anim.values = values
                anim.keyTimes = keyTimes
                anim.calculationMode = .linear
                anim.duration = frames / PS2Icon.defaultFramesPerSecond
                anim.repeatCount = .infinity
                anim.isRemovedOnCompletion = false
                animations.append(("ps2-morph-\(target)", anim))
            }
        }
        return PS2IconMesh(geometry: geometry, targets: targets, initialWeights: initial,
                           animations: animations.map { (key: $0.0, animation: $0.1) })
    }

    static func cgImage(_ texture: PS2Icon.Texture) -> CGImage? {
        guard texture.rgba8.count >= texture.width * texture.height * 4,
              let provider = CGDataProvider(data: texture.rgba8 as CFData) else { return nil }
        return CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: texture.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Generic block for saves without a readable icon: a small translucent-blue cube with a "?" face.
    @MainActor
    static func placeholderNode() -> SCNNode {
        let box = SCNBox(width: 0.72, height: 0.72, length: 0.72, chamferRadius: 0.07)
        let face = SCNMaterial()
        face.lightingModel = .lambert
        face.diffuse.contents = placeholderFace
        face.emission.contents = UIColor(red: 0.05, green: 0.1, blue: 0.3, alpha: 1)
        box.materials = [face]
        let node = SCNNode(geometry: box)
        node.simdPosition = SIMD3(0, 0.4, 0)
        node.eulerAngles = SCNVector3(0.18, 0, 0.12)
        let holder = SCNNode()
        holder.addChildNode(node)
        return holder
    }

    private static let placeholderFace: UIImage = {
        let size = CGSize(width: 128, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 0.35, green: 0.5, blue: 0.95, alpha: 1).cgColor,
                          UIColor(red: 0.12, green: 0.18, blue: 0.5, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 128, y: 128), options: [])
            UIColor.white.withAlphaComponent(0.55).setStroke()
            let border = UIBezierPath(roundedRect: CGRect(x: 8, y: 8, width: 112, height: 112), cornerRadius: 10)
            border.lineWidth = 3
            border.stroke()
            let text = NSAttributedString(string: "?", attributes: [
                .font: UIFont.systemFont(ofSize: 76, weight: .light),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
            ])
            let t = text.size()
            text.draw(at: CGPoint(x: (128 - t.width) / 2, y: (128 - t.height) / 2))
        }
    }()
}

// MARK: - Debug preview

#if DEBUG
/// Builds a throwaway card from the unit-test fixtures (a real `.psu` plus synthetic saves around the
/// sample `list.icn`) and shows the browser. Used by `#Preview` and the debug launch hook.
struct PS2SaveBrowserPreviewHost: View {
    @State private var card: PS2MemoryCard?

    var body: some View {
        Group {
            if let card {
                PS2SaveBrowserView(card: card, gameTitle: "Game Duo 测试", onClose: {})
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .task {
            let empty = ProcessInfo.processInfo.arguments.contains("-ps2-save-browser-empty")
            card = await Task.detached { Self.makeCard(empty: empty) }.value
        }
    }

    nonisolated static func makeCard(empty: Bool) -> PS2MemoryCard {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PS2SaveBrowserPreview", isDirectory: true)
        try? fm.removeItem(at: base)
        let card = PS2MemoryCard(root: base.appendingPathComponent("card", isDirectory: true))
        guard !empty else { return card }

        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            repo.appendingPathComponent("tools/ps2_tests/Tests/PS2CoreTests/Fixtures"),
            fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ps2fixtures"),
        ]
        let fixtures = candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("icons/list.icn").path) }
            ?? candidates[0]
        _ = try? card.importArchive(at: fixtures.appendingPathComponent("saves/mymc-BASLUS-20312GAME.psu"), overwrite: true)

        let date = Date(timeIntervalSince1970: 1_120_000_000)
        func save(_ name: String, _ files: [(String, Data)]) {
            let archive = PS2SaveArchive(directoryName: name,
                                         files: files.map { .init(name: $0.0, data: $0.1, created: date, modified: date) },
                                         created: date, modified: date)
            _ = try? card.importSave(archive, overwrite: true)
        }
        if let icon = try? Data(contentsOf: fixtures.appendingPathComponent("icons/list.icn")) {
            save("BASLUS-21000LIST", [
                ("icon.sys", iconSys("GAME DUO", "LIST ICON", icon: "list.icn",
                                     background: [(0, 20, 70), (20, 0, 60), (0, 40, 80), (10, 10, 40)])),
                ("list.icn", icon), ("DATA", Data(repeating: 1, count: 40_000)),
            ])
            save("BESLES-50001DUO", [
                ("icon.sys", iconSys("SAMPLE SAVE", "SLOT 2", icon: "list.icn",
                                     background: [(70, 30, 0), (60, 10, 10), (40, 20, 0), (20, 0, 20)],
                                     lightColor: (0.6, 0.45, 0.3))),
                ("list.icn", icon), ("DATA", Data(repeating: 2, count: 120_000)),
            ])
            save("BASCUS-97100SYS", [
                ("icon.sys", iconSys("SYSTEM", "CONFIG", icon: "list.icn",
                                     background: [(0, 50, 40), (0, 30, 60), (0, 20, 20), (0, 10, 30)])),
                ("list.icn", icon), ("CFG", Data(repeating: 3, count: 8_000)),
            ])
        }
        save("BISLPM-65000MISS", [
            ("icon.sys", iconSys("MISSING ICON", "", icon: "none.ico",
                                 background: [(20, 20, 20), (20, 20, 20), (10, 10, 10), (10, 10, 10)])),
            ("DATA", Data(repeating: 4, count: 2_000)),
        ])
        save("BASLUS-99999NOSYS", [("DATA", Data(repeating: 5, count: 3_000))])
        return card
    }

    /// Minimal 964-byte `icon.sys` (layout in PS2IconSys.swift).
    nonisolated static func iconSys(_ line1: String, _ line2: String, icon: String,
                        background: [(UInt32, UInt32, UInt32)],
                        lightColor: (Float, Float, Float) = (0.5, 0.5, 0.55)) -> Data {
        var d = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func f32(_ v: Float) { u32(v.bitPattern) }
        func fixed(_ s: String, _ n: Int) { var b = Array(s.utf8.prefix(n - 1)); b += Array(repeating: 0, count: n - b.count); d.append(contentsOf: b) }
        d.append(contentsOf: Array("PS2D".utf8))
        u16(0); u16(UInt16(line1.utf8.count)); u32(0); u32(0x80)
        for c in background { u32(c.0); u32(c.1); u32(c.2); u32(0) }
        for v in [(0.5, -0.4, 0.8), (-0.6, -0.2, 0.3), (0.0, 0.8, 0.2)] as [(Float, Float, Float)] {
            f32(v.0); f32(v.1); f32(v.2); f32(0)
        }
        for c in [lightColor, (0.3, 0.3, 0.35), (0.15, 0.15, 0.2)] as [(Float, Float, Float)] {
            f32(c.0); f32(c.1); f32(c.2); f32(0)
        }
        f32(0.35); f32(0.35); f32(0.38); f32(0)
        fixed(line1 + line2, 68)
        for _ in 0..<3 { fixed(icon, 64) }
        d.append(Data(count: PS2IconSys.size - d.count))
        return d
    }
}

#Preview {
    PS2SaveBrowserPreviewHost()
}
#endif
