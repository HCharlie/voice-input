# Transcription History Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent 7-day transcription history to VoiceInput with a searchable dedicated window, per-entry copy and re-inject actions.

**Architecture:** A new `TranscriptionStore` singleton persists entries to a JSON file in Application Support and serves an in-memory array. A new `HistoryWindow` NSPanel displays entries in a searchable table. `AppDelegate.finishTranscription()` is updated to save each completed transcription to the store.

**Tech Stack:** Swift 5.9, macOS 14+, AppKit (NSPanel, NSTableView, NSSearchField), Foundation (FileManager, JSONEncoder/JSONDecoder), Swift Package Manager.

**Spec:** `docs/superpowers/specs/2026-04-12-transcription-history-design.md`

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `Sources/VoiceInput/TranscriptionEntry.swift` | Codable data model struct |
| Create | `Sources/VoiceInput/TranscriptionStore.swift` | Singleton: in-memory array + JSON persistence |
| Create | `Sources/VoiceInput/HistoryWindow.swift` | NSPanel with search field, table, re-inject logic |
| Modify | `Sources/VoiceInput/AppDelegate.swift` | Add store appends in all 4 branches of `finishTranscription()`; add History menu item and lazy window property |

---

## Chunk 1: Data Model and Store

### Task 1: Create `TranscriptionEntry`

**Files:**
- Create: `Sources/VoiceInput/TranscriptionEntry.swift`

- [ ] **Step 1: Create the file**

```swift
// Sources/VoiceInput/TranscriptionEntry.swift
import Foundation

struct TranscriptionEntry: Codable, Identifiable {
    let id: UUID
    let text: String       // final injected text (post-refinement if refined)
    let date: Date
    var wasRefined: Bool   // true only if LLM refinement succeeded AND changed the text
}
```

- [ ] **Step 2: Verify it builds**

```bash
cd /Users/changlihan/src/github.com/HCharlie/voice-input && swift build 2>&1
```
Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/VoiceInput/TranscriptionEntry.swift
git commit -m "feat: add TranscriptionEntry data model"
```

---

### Task 2: Create `TranscriptionStore`

**Files:**
- Create: `Sources/VoiceInput/TranscriptionStore.swift`

- [ ] **Step 1: Create the file**

```swift
// Sources/VoiceInput/TranscriptionStore.swift
import Foundation

final class TranscriptionStore {
    static let shared = TranscriptionStore()

    private(set) var entries: [TranscriptionEntry] = []

    private let fileURL: URL? = {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let dir = appSupport.appendingPathComponent("VoiceInput", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[TranscriptionStore] Could not create directory: %@", error.localizedDescription)
            return nil
        }
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        load()
    }

    // MARK: - Public API

    func append(_ entry: TranscriptionEntry) {
        entries.insert(entry, at: 0)
        purge()
        save()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            entries = []
            return
        }
        do {
            entries = try JSONDecoder().decode([TranscriptionEntry].self, from: data)
            purge()
        } catch {
            NSLog("[TranscriptionStore] Corrupt history.json, resetting: %@", error.localizedDescription)
            entries = []
            save()
        }
    }

    private func save() {
        guard let url = fileURL else { return }
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[TranscriptionStore] Failed to save: %@", error.localizedDescription)
        }
    }

    private func purge() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        entries = entries.filter { $0.date > cutoff }
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
cd /Users/changlihan/src/github.com/HCharlie/voice-input && swift build 2>&1
```
Expected: Build succeeds with no errors.

- [ ] **Step 3: Manual smoke test — verify the file path**

After building, run the app briefly (`make run`), open Activity Monitor or check `~/Library/Application Support/VoiceInput/`. The directory will be created on first launch even before any transcriptions are saved.

- [ ] **Step 4: Commit**

```bash
git add Sources/VoiceInput/TranscriptionStore.swift
git commit -m "feat: add TranscriptionStore with JSON persistence"
```

---

## Chunk 2: History Window

### Task 3: Create `HistoryWindow`

**Files:**
- Create: `Sources/VoiceInput/HistoryWindow.swift`

This is the largest task. Build it in sub-steps.

- [ ] **Step 1: Create the skeleton with search field, table, and toolbar**

```swift
// Sources/VoiceInput/HistoryWindow.swift
import AppKit

final class HistoryWindow: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusTimer: Timer?

    private var allEntries: [TranscriptionEntry] = []
    private var filteredEntries: [TranscriptionEntry] = []

    private let textInjector = TextInjector()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Transcription History"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 400, height: 300)
        setupUI()
        center()
    }

    // Called each time the window is shown
    override func makeKeyAndOrderFront(_ sender: Any?) {
        reload()
        super.makeKeyAndOrderFront(sender)
    }

    // MARK: - Data

    private func reload() {
        allEntries = TranscriptionStore.shared.entries
        searchField.stringValue = ""
        applyFilter("")
        tableView.scrollToBeginningOfDocument(nil)
    }

    private func applyFilter(_ query: String) {
        if query.isEmpty {
            filteredEntries = allEntries
        } else {
            filteredEntries = allEntries.filter {
                $0.text.range(of: query, options: [.caseInsensitive]) != nil
            }
        }
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        // handled in tableView numberOfRows — see Step 2
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredEntries.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Implemented in Step 3
        return nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        // Implemented in Step 3
        return 60
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }
}
```

- [ ] **Step 2: Verify skeleton builds**

```bash
cd /Users/changlihan/src/github.com/HCharlie/voice-input && swift build 2>&1
```
Expected: Build succeeds.

- [ ] **Step 3: Add `setupUI()`**

Add the following method inside `HistoryWindow`:

```swift
private func setupUI() {
    guard let cv = contentView else { return }

    // Search field
    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.placeholderString = "Search transcriptions..."
    searchField.delegate = self
    cv.addSubview(searchField)

    // Table column
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
    column.title = ""
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.delegate = self
    tableView.dataSource = self
    tableView.rowHeight = 60
    tableView.selectionHighlightStyle = .regular
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.doubleAction = #selector(doubleClickRow)
    tableView.target = self

    // Right-click menu
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Copy", action: #selector(copySelected), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Re-inject", action: #selector(reinjectSelected), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Delete", action: #selector(deleteSelected), keyEquivalent: ""))
    tableView.menu = menu

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    cv.addSubview(scrollView)

    // Bottom toolbar
    let clearButton = NSButton(title: "Clear All", target: self, action: #selector(clearAll))
    clearButton.bezelStyle = .rounded
    clearButton.translatesAutoresizingMaskIntoConstraints = false

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.alignment = .right
    statusLabel.isHidden = true

    let toolbar = NSStackView(views: [clearButton, statusLabel])
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    toolbar.orientation = .horizontal
    toolbar.spacing = 8
    cv.addSubview(toolbar)

    NSLayoutConstraint.activate([
        searchField.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
        searchField.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
        searchField.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),

        scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
        scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
        scrollView.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -8),

        toolbar.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
        toolbar.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
        toolbar.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -12),
    ])

    statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    clearButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
}
```

- [ ] **Step 4: Implement table cell view**

Replace the `tableView(_:viewFor:row:)` stub and add the cell view class at the bottom of the file:

```swift
func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let entry = filteredEntries[row]
    let id = NSUserInterfaceItemIdentifier("HistoryCell")
    let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HistoryCellView
               ?? HistoryCellView(identifier: id)
    cell.configure(with: entry)
    return cell
}

func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    let entry = filteredEntries[row]
    // Estimate height: ~18pt per line, 16pt top+bottom padding
    let font = NSFont.systemFont(ofSize: 13)
    let maxWidth = tableView.bounds.width - 32  // account for padding
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let rect = (entry.text as NSString).boundingRect(
        with: NSSize(width: max(maxWidth, 100), height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: attrs
    )
    return max(56, ceil(rect.height) + 32)
}
```

Then add after the `HistoryWindow` closing brace:

```swift
// MARK: - Cell View

private final class HistoryCellView: NSTableCellView {
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let refinedIcon = NSImageView()

    convenience init(identifier: NSUserInterfaceItemIdentifier) {
        self.init(frame: .zero)
        self.identifier = identifier
        setup()
    }

    private func setup() {
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .systemFont(ofSize: 13)
        textLabel.textColor = .labelColor
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.maximumNumberOfLines = 0
        addSubview(textLabel)

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor
        addSubview(metaLabel)

        refinedIcon.translatesAutoresizingMaskIntoConstraints = false
        refinedIcon.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Refined")
        refinedIcon.contentTintColor = .systemPurple
        refinedIcon.imageScaling = .scaleProportionallyDown
        addSubview(refinedIcon)

        NSLayoutConstraint.activate([
            textLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(equalTo: refinedIcon.leadingAnchor, constant: -4),

            metaLabel.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 2),
            metaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            metaLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),

            refinedIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            refinedIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            refinedIcon.widthAnchor.constraint(equalToConstant: 16),
            refinedIcon.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    func configure(with entry: TranscriptionEntry) {
        textLabel.stringValue = entry.text
        metaLabel.stringValue = Self.formatDate(entry.date)
        refinedIcon.isHidden = !entry.wasRefined
    }

    private static func formatDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            return "Today \(f.string(from: date))"
        } else {
            let f = DateFormatter()
            f.dateFormat = "MMM d, h:mm a"
            return f.string(from: date)
        }
    }
}
```

- [ ] **Step 5: Implement actions**

Add the following methods to `HistoryWindow`:

```swift
// MARK: - Actions

@objc private func doubleClickRow() {
    let row = tableView.clickedRow
    guard row >= 0, row < filteredEntries.count else { return }
    copyText(filteredEntries[row].text)
}

@objc private func copySelected() {
    let row = tableView.clickedRow
    guard row >= 0, row < filteredEntries.count else { return }
    copyText(filteredEntries[row].text)
}

@objc private func reinjectSelected() {
    let row = tableView.clickedRow
    guard row >= 0, row < filteredEntries.count else { return }
    let text = filteredEntries[row].text
    orderOut(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
        self?.textInjector.inject(text)
        NSSound(named: .init("Pop"))?.play()
    }
}

@objc private func deleteSelected() {
    let row = tableView.clickedRow
    guard row >= 0, row < filteredEntries.count else { return }
    let id = filteredEntries[row].id
    TranscriptionStore.shared.delete(id: id)
    allEntries = TranscriptionStore.shared.entries
    applyFilter(searchField.stringValue)
}

@objc private func clearAll() {
    let alert = NSAlert()
    alert.messageText = "Clear All History"
    alert.informativeText = "This will permanently delete all transcription history. Are you sure?"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Clear All")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    TranscriptionStore.shared.clear()
    allEntries = []
    applyFilter(searchField.stringValue)
}

// MARK: - Helpers

private func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    showStatus("Copied!")
}

private func showStatus(_ message: String) {
    statusTimer?.invalidate()
    statusLabel.stringValue = message
    statusLabel.isHidden = false
    statusTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
        self?.statusLabel.isHidden = true
    }
}
```

- [ ] **Step 6: Add empty state overlay**

Add a `emptyLabel` property and update `updateEmptyState()`:

Add to `HistoryWindow` properties:
```swift
private let emptyLabel = NSTextField(labelWithString: "")
```

Update `setupUI()` — add after the `scrollView` setup, before the toolbar:
```swift
emptyLabel.translatesAutoresizingMaskIntoConstraints = false
emptyLabel.font = .systemFont(ofSize: 13)
emptyLabel.textColor = .secondaryLabelColor
emptyLabel.alignment = .center
emptyLabel.isHidden = true
cv.addSubview(emptyLabel)

NSLayoutConstraint.activate([
    emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
    emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
    emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: cv.leadingAnchor, constant: 24),
    emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -24),
])
```

Replace `updateEmptyState()` body:
```swift
private func updateEmptyState() {
    let isEmpty = filteredEntries.isEmpty
    emptyLabel.isHidden = !isEmpty
    scrollView.isHidden = isEmpty
    if isEmpty {
        let query = searchField.stringValue
        emptyLabel.stringValue = query.isEmpty
            ? "No transcription history yet.\nHold Fn and speak to get started."
            : "No results for \"\(query)\""
    }
}
```

- [ ] **Step 7: Verify full build**

```bash
cd /Users/changlihan/src/github.com/HCharlie/voice-input && swift build 2>&1
```
Expected: Build succeeds with no errors.

- [ ] **Step 8: Commit**

```bash
git add Sources/VoiceInput/HistoryWindow.swift
git commit -m "feat: add HistoryWindow with search, copy, re-inject, and clear actions"
```

---

## Chunk 3: AppDelegate Integration

### Task 4: Wire up AppDelegate

**Files:**
- Modify: `Sources/VoiceInput/AppDelegate.swift`

- [ ] **Step 1: Add the lazy history window property**

In `AppDelegate`, after the existing `private lazy var settingsWindow = SettingsWindow()` line (line 18), add:

```swift
private lazy var historyWindow = HistoryWindow()
```

- [ ] **Step 2: Add "History..." menu item in `setupStatusBar()`**

In `setupStatusBar()`, there is one `menu.addItem(.separator())` call at line 250, right before `quitItem`. Insert the History item and a new separator **between that existing separator and `quitItem`** — do not add a second separator before it.

Find this block (lines 250–254 of `AppDelegate.swift`):
```swift
menu.addItem(.separator())   // ← existing, keep this

let quitItem = NSMenuItem(title: "Quit VoiceInput", action: #selector(quit), keyEquivalent: "q")
quitItem.target = self
menu.addItem(quitItem)
```

Change it to:
```swift
menu.addItem(.separator())   // ← existing, keep this

let historyItem = NSMenuItem(title: "History...", action: #selector(openHistory), keyEquivalent: "")
historyItem.target = self
menu.addItem(historyItem)

menu.addItem(.separator())   // ← new separator before Quit

let quitItem = NSMenuItem(title: "Quit VoiceInput", action: #selector(quit), keyEquivalent: "q")
quitItem.target = self
menu.addItem(quitItem)
```

Result:
```
Enabled
──────
Language ▶
LLM Refinement ▶
──────
History...
──────
Quit VoiceInput
```

- [ ] **Step 3: Add the `openHistory` action**

After the existing `@objc private func openLLMSettings()` method, add:

```swift
@objc private func openHistory() {
    historyWindow.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}
```

- [ ] **Step 4: Add store appends in `finishTranscription()`**

Open `finishTranscription()`. There are 4 branches to update.

**Branch A — LLM refined and changed the text** (inside `.success` case, inside the `if wasRefined` block, after `self.overlayPanel.dismiss()` inside the 1.0s async block):

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    self.overlayPanel.dismiss()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.textInjector.inject(finalText)
        NSSound(named: .init("Pop"))?.play()
        // NEW:
        TranscriptionStore.shared.append(
            TranscriptionEntry(id: UUID(), text: finalText, date: Date(), wasRefined: true)
        )
    }
}
```

**Branch B — LLM succeeded but text unchanged** (inside `.success` case, the `else` branch of `if wasRefined`):

```swift
self.overlayPanel.dismiss()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
    self.textInjector.inject(finalText)
    NSSound(named: .init("Pop"))?.play()
    // NEW:
    TranscriptionStore.shared.append(
        TranscriptionEntry(id: UUID(), text: finalText, date: Date(), wasRefined: false)
    )
}
```

**Branch C — LLM failed** (inside `.failure` case, inside the 1.5s async block):

> **Important:** `self.lastPartialResult = ""` lives at line 184 of `AppDelegate.swift`, **outside** the `switch result` block but inside the `refiner.refine(text)` completion closure. Do NOT move it — only add the `append` call inside the inner 0.1s closure.

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    self.overlayPanel.dismiss()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.textInjector.inject(finalText)
        NSSound(named: .init("Pop"))?.play()
        // NEW:
        TranscriptionStore.shared.append(
            TranscriptionEntry(id: UUID(), text: finalText, date: Date(), wasRefined: false)
        )
    }
}
// self.lastPartialResult = ""  ← EXISTING line 184, outside switch, do not move
```

**Branch D — LLM disabled** (the `else` block after the `if refiner.isEnabled && refiner.isConfigured` check):

```swift
overlayPanel.dismiss()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
    self?.textInjector.inject(text)
    NSSound(named: .init("Pop"))?.play()
    // NEW:
    TranscriptionStore.shared.append(
        TranscriptionEntry(id: UUID(), text: text, date: Date(), wasRefined: false)
    )
}
lastPartialResult = ""
```

- [ ] **Step 5: Verify full build**

```bash
cd /Users/changlihan/src/github.com/HCharlie/voice-input && swift build 2>&1
```
Expected: Build succeeds with no errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/VoiceInput/AppDelegate.swift
git commit -m "feat: integrate TranscriptionStore and History menu into AppDelegate"
```

---

## Chunk 4: Manual Integration Test

### Task 5: End-to-end verification

- [ ] **Step 1: Install and launch**

```bash
make install && /Applications/VoiceInput.app/Contents/MacOS/VoiceInput &
```

- [ ] **Step 2: Record a transcription**

Hold Fn, say a sentence, release Fn. Confirm the text is injected into a focused text field as normal.

- [ ] **Step 3: Open History window**

Click the mic icon in the menu bar → "History...". Confirm:
- The window opens
- The transcription just recorded appears in the list
- The timestamp shows "Today HH:MM AM/PM"
- No `wand.and.stars` icon (LLM not enabled)

- [ ] **Step 4: Test search**

Type a word from the transcription into the search field. Confirm the list filters live. Clear the field — confirm all entries return.

- [ ] **Step 5: Test Copy**

Right-click an entry → "Copy". Open a text editor and Cmd+V. Confirm the text pastes correctly.
Also double-click an entry — confirm "Copied!" appears in the bottom status bar for ~1.5 seconds.

- [ ] **Step 6: Test Re-inject**

Click on another app (e.g. Notes or a browser address bar) to give it focus. Switch back to VoiceInput menu, open History. Right-click an entry → "Re-inject". Confirm:
- The History window closes
- After ~150ms the text is typed into the previously focused app

- [ ] **Step 7: Test Delete**

Right-click an entry → "Delete". Confirm the row disappears from the table without closing the window.

- [ ] **Step 8: Test Clear All**

Click "Clear All". Confirm the confirmation alert appears. Click "Clear All" in the alert. Confirm the table empties and the empty-state label appears.

- [ ] **Step 9: Test 7-day purge (fast verification)**

In `TranscriptionStore.init()`, temporarily change the cutoff to 1 minute:
```swift
let cutoff = Calendar.current.date(byAdding: .minute, value: -1, to: Date())!
```
Rebuild, launch, record, wait 70 seconds, re-open History — entry should be gone. Revert the change and rebuild.

- [ ] **Step 10: Test persistence across launches**

Record a transcription. Quit the app (`Cmd+Q` from the menu or kill the process). Relaunch. Open History. Confirm the previous transcription is still there.

- [ ] **Step 11: Commit final state**

```bash
git add -A
git commit -m "feat: transcription history — complete implementation"
```
