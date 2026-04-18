import AppKit
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let keyMonitor = KeyMonitor()
    private let speechEngine = SpeechEngine()
    private let textInjector = TextInjector()
    private lazy var overlayPanel = OverlayPanel()

    private var isEnabled = true
    private var isRecording = false
    private var lastPartialResult = ""
    private var finalResultTimer: Timer?

    private var enableMenuItem: NSMenuItem!
    private var llmMenuItem: NSMenuItem!
    private lazy var settingsWindow = SettingsWindow()
    private lazy var historyWindow = HistoryWindow()
    private var languageItems: [NSMenuItem] = []
    private let languages: [(name: String, code: String)] = [
        (name: "System Default", code: ""),
        (name: "English (US)",   code: "en-US"),
        (name: "中文 (简体)",     code: "zh-CN"),
        (name: "中文 (繁體)",     code: "zh-TW"),
        (name: "日本語",          code: "ja-JP"),
        (name: "한국어",          code: "ko-KR"),
    ]
    private var selectedLocaleCode: String {
        get { UserDefaults.standard.string(forKey: "selectedLocaleCode") ?? "en-US" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedLocaleCode") }
    }

    private var cycleLocaleCodes: [String] {
        get {
            (UserDefaults.standard.array(forKey: "cycleLocaleCodes") as? [String])
                ?? ["en-US", "zh-CN"]
        }
        set { UserDefaults.standard.set(newValue, forKey: "cycleLocaleCodes") }
    }

    private var languageSwitchDismissTimer: Timer?
    private var cycleMenuItems: [NSMenuItem] = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedCode = selectedLocaleCode
        if !savedCode.isEmpty {
            speechEngine.locale = Locale(identifier: savedCode)
        }

        setupStatusBar()
        setupSpeechCallbacks()

        keyMonitor.onFnDown = { [weak self] in self?.fnDown() }
        keyMonitor.onFnUp = { [weak self] in self?.fnUp() }
        keyMonitor.onFnDoubleTap = { [weak self] in self?.fnDoubleTap() }

        requestAccessibilityAndStart()

        // Request speech permissions after a delay to avoid interfering with status bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            SpeechEngine.requestPermissions { [weak self] granted, errorMsg in
                if !granted, let msg = errorMsg {
                    DispatchQueue.main.async {
                        self?.showAlert(title: "Permission Required", message: msg)
                    }
                }
            }
        }
    }

    private var accessibilityTimer: Timer?

    private func requestAccessibilityAndStart() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            _ = keyMonitor.start()
            return
        }

        // Poll every 2 seconds until the user grants permission
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.accessibilityTimer = nil
                _ = self.keyMonitor.start()
            }
        }
    }

    // MARK: - Key events

    private func fnDown() {
        // Cancel any pending language-switch overlay dismiss — the recording overlay
        // will replace it via overlayPanel.show(text: "Listening...") below.
        languageSwitchDismissTimer?.invalidate()
        languageSwitchDismissTimer = nil

        guard isEnabled, !isRecording else { return }
        LLMRefiner.shared.cancel()
        isRecording = true
        lastPartialResult = ""

        updateStatusIcon(recording: true)
        overlayPanel.show(text: "Listening...")
        NSSound(named: .init("Tink"))?.play()

        speechEngine.startRecording()
    }

    private func fnUp() {
        guard isRecording else { return }
        isRecording = false

        updateStatusIcon(recording: false)
        speechEngine.stopRecording()

        finalResultTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.finishTranscription()
        }
    }

    private func fnDoubleTap() {
        guard isEnabled, !isRecording else { return }

        // Ordering guarantee: the CGEvent tap runs on CFRunLoopGetMain(), so all three
        // DispatchQueue.main.async dispatches (onFnDown, onFnUp, onFnDoubleTap) execute
        // in FIFO order. fnUp() always completes before fnDoubleTap() runs, so
        // finalResultTimer is already set by the time we cancel it here.
        //
        // speechEngine is MultiLangSpeechEngine. cancel() is safe when idle:
        // removeTap() is a no-op if no tap installed; audioEngine.stop() is guarded by
        // isRunning check (MultiLangSpeechEngine.swift:124-130).
        finalResultTimer?.invalidate()
        finalResultTimer = nil
        speechEngine.cancel()
        lastPartialResult = ""

        guard !cycleLocaleCodes.isEmpty else { return }

        let currentIndex = cycleLocaleCodes.firstIndex(of: selectedLocaleCode)
        let nextIndex = currentIndex.map { ($0 + 1) % cycleLocaleCodes.count } ?? 0
        let nextCode = cycleLocaleCodes[nextIndex]

        setLanguage(code: nextCode)
        updateCycleMenuItems()

        // Race note: onFinalResult from the speech framework can be dispatched to the main
        // queue between fnUp() and fnDoubleTap() (both FIFO on main queue). If onFinalResult
        // fires before fnDoubleTap(), finishTranscription() runs first. In practice this is
        // self-healing: the first tap is < 300ms of audio (user not yet speaking), so the
        // transcription is empty and finishTranscription() bails at its `guard !text.isEmpty`
        // check — no text is injected. The subsequent speechEngine.cancel() above then cleans up.
        //
        // The first tap of the double-tap will have shown "Listening..." in the overlay.
        // overlayPanel.show(text:) re-runs the appear animation (alpha 0 → 1), which causes
        // a brief fade-reset. This is intentional and acceptable — the user just double-tapped.
        overlayPanel.show(text: "Language: \(languageName(for: nextCode))")
        // Note: the user will hear two Tink sounds in quick succession — one from fnDown()
        // on the first tap and one here. This is the intended feedback for a double-tap.
        NSSound(named: .init("Tink"))?.play()

        languageSwitchDismissTimer?.invalidate()
        languageSwitchDismissTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.overlayPanel.dismiss()
            self?.languageSwitchDismissTimer = nil
        }
    }

    // MARK: - Speech callbacks

    private func setupSpeechCallbacks() {
        speechEngine.onPartialResult = { [weak self] text in
            guard let self else { return }
            self.lastPartialResult = text
            self.overlayPanel.updateText(text)
        }

        speechEngine.onFinalResult = { [weak self] text in
            guard let self else { return }
            self.lastPartialResult = text
            self.finalResultTimer?.invalidate()
            self.finalResultTimer = nil
            self.finishTranscription()
        }

        speechEngine.onError = { [weak self] msg in
            guard let self else { return }
            self.overlayPanel.updateText("Error: \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.overlayPanel.dismiss()
            }
        }

        speechEngine.onAudioLevel = { [weak self] level in
            self?.overlayPanel.updateAudioLevel(level)
        }

        speechEngine.onLocaleUnavailable = { [weak self] msg in
            self?.showAlert(title: "Language Unavailable", message: msg)
        }
    }

    private func finishTranscription() {
        finalResultTimer?.invalidate()
        finalResultTimer = nil

        let text = lastPartialResult.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            overlayPanel.dismiss()
            lastPartialResult = ""
            return
        }

        let refiner = LLMRefiner.shared
        if refiner.isEnabled && refiner.isConfigured {
            overlayPanel.showRefining()
            refiner.refine(text) { [weak self] result in
                guard let self else { return }
                let finalText: String
                switch result {
                case .success(let refined):
                    finalText = refined.isEmpty ? text : refined
                    let wasRefined = finalText != text
                    if wasRefined {
                        self.overlayPanel.updateText("✨ \(finalText)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.overlayPanel.dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                self.textInjector.inject(finalText)
                                NSSound(named: .init("Pop"))?.play()
                                TranscriptionStore.shared.append(
                                    TranscriptionEntry(id: UUID(), text: finalText, date: Date(), wasRefined: true)
                                )
                            }
                        }
                    } else {
                        self.overlayPanel.dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.textInjector.inject(finalText)
                            NSSound(named: .init("Pop"))?.play()
                            TranscriptionStore.shared.append(
                                TranscriptionEntry(id: UUID(), text: finalText, date: Date(), wasRefined: false)
                            )
                        }
                    }
                case .failure(let error):
                    NSLog("[LLMRefiner] Refine failed: %@", error.localizedDescription)
                    finalText = text
                    self.overlayPanel.updateText("Refine failed: \(error.localizedDescription)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.overlayPanel.dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.textInjector.inject(finalText)
                            NSSound(named: .init("Pop"))?.play()
                            TranscriptionStore.shared.append(
                                TranscriptionEntry(id: UUID(), text: finalText, date: Date(), wasRefined: false)
                            )
                        }
                    }
                }
                self.lastPartialResult = ""
            }
        } else {
            overlayPanel.dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.textInjector.inject(text)
                NSSound(named: .init("Pop"))?.play()
                TranscriptionStore.shared.append(
                    TranscriptionEntry(id: UUID(), text: text, date: Date(), wasRefined: false)
                )
            }
            lastPartialResult = ""
        }
    }

    // MARK: - Status bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(recording: false)

        let menu = NSMenu()

        enableMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enableMenuItem.target = self
        enableMenuItem.state = .on
        menu.addItem(enableMenuItem)

        menu.addItem(.separator())

        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for (name, code) in languages {
            let item = NSMenuItem(title: name, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = code == selectedLocaleCode ? .on : .off
            languageItems.append(item)
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // LLM Refinement submenu
        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        let llmMenu = NSMenu()

        llmMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleLLM), keyEquivalent: "")
        llmMenuItem.target = self
        llmMenuItem.state = LLMRefiner.shared.isEnabled ? .on : .off
        llmMenu.addItem(llmMenuItem)

        llmMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openLLMSettings), keyEquivalent: "")
        settingsItem.target = self
        llmMenu.addItem(settingsItem)

        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        menu.addItem(.separator())

        let historyItem = NSMenuItem(title: "History...", action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit VoiceInput", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        let name = recording ? "mic.fill" : "mic"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Voice Input")
        button.contentTintColor = recording ? .systemRed : nil
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        enableMenuItem.state = isEnabled ? .on : .off

        if isEnabled {
            if !keyMonitor.start() {
                showAccessibilityAlert()
            }
        } else {
            keyMonitor.stop()
            if isRecording {
                speechEngine.cancel()
                overlayPanel.dismiss()
                isRecording = false
                updateStatusIcon(recording: false)
            }
        }
    }

    private func setLanguage(code: String) {
        selectedLocaleCode = code
        speechEngine.locale = code.isEmpty ? .current : Locale(identifier: code)
        for item in languageItems {
            item.state = (item.representedObject as? String) == code ? .on : .off
        }
    }

    private func languageName(for code: String) -> String {
        languages.first(where: { $0.code == code })?.name ?? code
    }

    private func updateCycleMenuItems() {
        for item in cycleMenuItems {
            guard let code = item.representedObject as? String else { continue }
            item.state = cycleLocaleCodes.contains(code) ? .on : .off
        }
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        setLanguage(code: code)
    }

    @objc private func toggleLLM() {
        let refiner = LLMRefiner.shared
        refiner.isEnabled.toggle()
        llmMenuItem.state = refiner.isEnabled ? .on : .off
    }

    @objc private func openLLMSettings() {
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openHistory() {
        historyWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        keyMonitor.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
            VoiceInput needs Accessibility permission to monitor the Fn key.

            1. Open System Settings → Privacy & Security → Accessibility
            2. Add and enable VoiceInput
            3. Restart the app
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
