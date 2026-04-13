// Sources/VoiceInput/HistoryWindow.swift
import AppKit

final class HistoryWindow: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private var statusTimer: Timer?

    private var allEntries: [TranscriptionEntry] = []
    private var filteredEntries: [TranscriptionEntry] = []

    private let textInjector = TextInjector()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable],
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

    // MARK: - UI Setup

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

        // Fix 2B: Recalculate row heights when the scroll view is resized
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentViewFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsFrameChangedNotifications = true
    }

    // Fix 2B: Handler for scroll view resize
    @objc private func contentViewFrameChanged() {
        guard !filteredEntries.isEmpty else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<filteredEntries.count))
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredEntries.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Fix 1: Guard against out-of-range row
        guard row < filteredEntries.count else { return nil }
        let entry = filteredEntries[row]
        let id = NSUserInterfaceItemIdentifier("HistoryCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HistoryCellView
                   ?? HistoryCellView(identifier: id)
        cell.configure(with: entry)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        // Fix 1: Guard against out-of-range row
        guard row < filteredEntries.count else { return 56 }
        let entry = filteredEntries[row]
        // Fix 2A: Fall back to a reasonable default when bounds.width is 0 during first layout pass
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : 540
        let maxWidth = width - 32  // account for padding
        let font = NSFont.systemFont(ofSize: 13)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let rect = (entry.text as NSString).boundingRect(
            with: NSSize(width: max(maxWidth, 100), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return max(56, ceil(rect.height) + 32)
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

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

    // Fix 4: Capture textInjector and text directly instead of [weak self]
    @objc private func reinjectSelected() {
        let row = tableView.clickedRow
        guard row >= 0, row < filteredEntries.count else { return }
        let text = filteredEntries[row].text
        let injector = textInjector
        orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            injector.inject(text)
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

    // Fix 6: Call reload() to also reset the search field after clearing
    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear All History"
        alert.informativeText = "This will permanently delete all transcription history. Are you sure?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        TranscriptionStore.shared.clear()
        reload()
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
}

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

    // Fix 3: Cache DateFormatter instances as static properties to avoid repeated allocations
    private static let todayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let pastFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    private static func formatDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today \(todayFormatter.string(from: date))"
        } else {
            return pastFormatter.string(from: date)
        }
    }
}
