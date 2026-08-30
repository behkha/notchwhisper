import AppKit
import SwiftUI
import Combine

/// Geometry of the MacBook notch / menu-bar band on a given screen.
struct NotchInfo {
    let width: CGFloat          // physical notch width
    let bandHeight: CGFloat     // menu-bar band height (where the pill lives)
    let hasNotch: Bool

    static func detect(from screen: NSScreen?) -> NotchInfo {
        guard let screen else {
            return NotchInfo(width: 200, bandHeight: 24, hasNotch: false)
        }
        let safeTop = screen.safeAreaInsets.top
        if safeTop > 0 {
            let leftW = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightW = screen.auxiliaryTopRightArea?.width ?? 0
            let width: CGFloat = (leftW > 0 && rightW > 0)
                ? max(180, screen.frame.width - leftW - rightW)
                : 220
            // Menu-bar band = top of screen down to the menu bar's bottom.
            let band = (screen.frame.maxY - screen.visibleFrame.maxY) - 1
            return NotchInfo(width: width, bandHeight: max(band, safeTop), hasNotch: true)
        }
        return NotchInfo(width: 200, bandHeight: 24, hasNotch: false)
    }
}

/// A borderless, top-most panel that sits in the MacBook notch band.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        // Above the menu bar so it is NOT hidden behind it.
        self.level = .popUpMenu
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isMovable = false
        self.ignoresMouseEvents = true
        // The pill must survive the app losing focus — recording happens while
        // the user works in OTHER apps, so the panel may never hide on deactivate.
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
    }
}

/// Owns the notch panel, positions it inside the notch band, and hosts the
/// SwiftUI pill.
///
/// Visibility is state driven (per ChatGPT consult): the panel is HIDDEN while
/// idle — a permanent empty panel feels like a system modification, not a
/// native utility. It appears when recording, stays through transcribing,
/// lingers ~2s on done/error to communicate the result, then retires.
///
/// Also owns the WaveformModel lifecycle: mic levels from AppState are fed in
/// via Combine and smoothed at 60 Hz for the notch waveform.
///
/// The panel is a LARGE transparent canvas (Codex-Island style) anchored
/// top-center; the SwiftUI island morphs inside it, so the shape can expand
/// downward from the physical notch without resizing the window.
@MainActor
final class NotchController: ObservableObject {
    let panel = NotchPanel()
    private var hostingView: NSHostingView<AnyView>
    let waveform = WaveformModel()

    /// Geometry of the notch on the current target screen. Published so the
    /// SwiftUI island can size its compact state to the physical notch.
    @Published private(set) var notchInfo = NotchInfo(width: 200, bandHeight: 32, hasNotch: false)

    private let state: AppState
    private var cancellables = Set<AnyCancellable>()
    private var hideWorkItem: DispatchWorkItem?
    private var currentNotch: NotchInfo?

    /// Fixed transparent canvas the island morphs inside. Wide/tall enough for
    /// the expanded recording rectangle + halo, so window resizes never clip it.
    private static let canvasSize = CGSize(width: 560, height: 220)

    init(state: AppState, settings: Settings) {
        self.state = state
        // Build the hosting view in two steps: create it with a placeholder
        // first so all stored properties are initialized, then set the real
        // root (which needs `self` as an environment object).
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        let root = NotchView()
            .environmentObject(state)
            .environmentObject(settings)
            .environmentObject(waveform)
            .environmentObject(self)
        hostingView.rootView = AnyView(root)
        panel.contentView = hostingView
        reposition()
        observe()
        wire(state)
    }

    // MARK: - State wiring
    private func wire(_ state: AppState) {
        // Drive panel visibility + waveform lifecycle from the app mode.
        state.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                Task { @MainActor in self?.modeChanged(mode) }
            }
            .store(in: &cancellables)
        // Feed live mic levels into the smoothing model (60 Hz animation source).
        state.$levels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] levels in
                Task { @MainActor in self?.waveform.setLevels(levels) }
            }
            .store(in: &cancellables)
        // Feed raw 16 kHz chunks into the spectrum analyzer (pitch → bars).
        state.$audioChunk
            .receive(on: DispatchQueue.main)
            .sink { [weak self] chunk in
                Task { @MainActor in self?.waveform.appendSamples(chunk) }
            }
            .store(in: &cancellables)

        // Show the pill for a model download / load even while idle, so first
        // run and model switches get a visible progress bar in the notch
        // (req 3). Publisher.merge keeps a single sink.
        state.$isDownloading.map { _ in () }
            .merge(with: state.$isLoadingModel.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor in self?.refreshBootLoadingVisibility() }
            }
            .store(in: &cancellables)
    }

    /// Panel visibility for the idle-time "downloading / loading model" state.
    private func refreshBootLoadingVisibility() {
        guard state.mode == .idle else { return }
        if state.isDownloading || state.isLoadingModel {
            hideWorkItem?.cancel(); hideWorkItem = nil
            show()
        } else {
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.state.mode == .idle,
                          !self.state.isDownloading, !self.state.isLoadingModel else { return }
                    self.hide()
                }
            }
            hideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
        }
    }

    private func modeChanged(_ mode: NotchMode) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        switch mode {
        case .recording, .dictating:
            waveform.start()
            show()
        case .transcribing, .improving:
            waveform.setLevels([])   // let the bars decay smoothly to the floor
            show()
        case .done, .error:
            show()
            // Communicate the result briefly, then return to idle (which plays
            // the close morph and retires the panel).
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.state.mode == mode else { return }
                    self.state.mode = .idle
                }
            }
            hideWorkItem = item
            // Errors carry a message worth reading; "Done" is a glance.
            DispatchQueue.main.asyncAfter(deadline: .now() + (mode == .error ? 4.5 : 2.2), execute: item)
        case .idle:
            waveform.stop()
            // Let the SwiftUI close morph (~0.3s) play before the panel retires
            // — unless a model download / load is in progress, which keeps its
            // own progress pill visible.
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if self.state.isDownloading || self.state.isLoadingModel { return }
                    self.hide()
                }
            }
            hideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
        }
    }

    // MARK: - Screen observation
    private func observe() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    /// Recompute the target screen and place the panel.
    ///
    /// Screen choice follows the USER, not the hardware: the pill appears on
    /// the screen that currently has the mouse pointer (i.e. the display the
    /// user is working on), top-center. On the built-in notched display it
    /// sits inside the notch band; on notch-less external displays it renders
    /// as the same capsule flush with the top edge. Falls back to the notched
    /// display when the pointer can't be determined.
    @MainActor func reposition() {
        let pointer = NSEvent.mouseLocation
        let atPointer = NSScreen.screens.first { NSPointInRect(pointer, $0.frame) }
        let notched = NSScreen.screens.max(by: { $0.safeAreaInsets.top < $1.safeAreaInsets.top })
        let screen = atPointer
            ?? ((notched?.safeAreaInsets.top ?? 0) > 0
                ? notched!
                : (NSScreen.main ?? NSScreen.screens.first!))
        let info = NotchInfo.detect(from: screen)
        currentNotch = info
        notchInfo = info

        // The panel is a fixed transparent canvas anchored top-center on the
        // screen; the SwiftUI island morphs inside it (compact = the physical
        // notch, active = a rectangle expanding down from it).
        let w = Self.canvasSize.width
        let h = Self.canvasSize.height
        let x = screen.frame.midX - w / 2
        let y = screen.frame.maxY - h
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        hostingView.frame = NSRect(x: 0, y: 0, width: w, height: h)
        fputs("NotchWhisper: notch panel frame x=\(x) y=\(y) w=\(w) h=\(h) notchW=\(info.width) band=\(info.bandHeight) screen=\(screen.localizedName)\n", stderr)
    }

    func show() {
        // Follow the user: re-aim at the display holding the pointer right
        // before appearing, so the pill always shows where they're working.
        reposition()
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}
