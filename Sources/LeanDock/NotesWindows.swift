import AppKit
import Foundation
import LeanDockCore

@MainActor
final class NotesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var notes: [Note]
    var selected: Int = -1
    let table = NSTableView()
    let titleField = NSTextField()
    let editor = NSTextView()
    var onSave: (([Note]) throws -> Void)?
    var onClose: (() -> Void)?
    private var loading = false
    init(notes: [Note]) {
        self.notes = notes
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "LeanDock · 备忘录"; window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSStackView(); root.orientation = .horizontal; root.spacing = 16; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 18), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -18),
                                     root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18)])
        let left = NSStackView(); left.orientation = .vertical; left.spacing = 8; left.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let column = NSTableColumn(identifier: .init("title")); table.addTableColumn(column); table.headerView = nil; table.delegate = self; table.dataSource = self; table.rowHeight = 34
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.borderType = .bezelBorder
        left.addArrangedSubview(list)
        let buttons = NSStackView(views: [NSButton(title: "新增", target: self, action: #selector(addNote)), NSButton(title: "删除", target: self, action: #selector(deleteNote))]); left.addArrangedSubview(buttons)
        let right = NSStackView(); right.orientation = .vertical; right.spacing = 10
        titleField.placeholderString = "标题"; right.addArrangedSubview(titleField)
        editor.isRichText = false; editor.font = .systemFont(ofSize: 14); editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        let textScroll = NSScrollView(); textScroll.documentView = editor; textScroll.hasVerticalScroller = true; textScroll.borderType = .bezelBorder
        right.addArrangedSubview(textScroll)
        right.addArrangedSubview(NSStackView(views: [NSButton(title: "保存", target: self, action: #selector(saveNote)),
                                                   NSButton(title: "关闭", target: self, action: #selector(closeNotes))]))
        root.addArrangedSubview(left); root.addArrangedSubview(right)
        NSLayoutConstraint.activate([left.heightAnchor.constraint(equalTo: root.heightAnchor), right.heightAnchor.constraint(equalTo: root.heightAnchor),
                                     list.widthAnchor.constraint(equalTo: left.widthAnchor), titleField.widthAnchor.constraint(equalTo: right.widthAnchor),
                                     textScroll.widthAnchor.constraint(equalTo: right.widthAnchor)])
        if !notes.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { loadSelection(-1) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func numberOfRows(in tableView: NSTableView) -> Int { notes.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: notes[row].title.isEmpty ? "未命名" : notes[row].title)
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { loading || flush() }
    func tableViewSelectionDidChange(_ notification: Notification) { if !loading { loadSelection(table.selectedRow) } }
    func loadSelection(_ row: Int) {
        selected = row; let valid = notes.indices.contains(row)
        titleField.stringValue = valid ? notes[row].title : ""; editor.string = valid ? notes[row].content : ""
        titleField.isEnabled = valid; editor.isEditable = valid
    }
    func flush() -> Bool {
        if notes.indices.contains(selected) {
            var note = notes[selected]
            if note.title != titleField.stringValue || note.content != editor.string {
                note.title = titleField.stringValue; note.content = editor.string; note.modifiedAt = Date(); notes[selected] = note
            }
        }
        do { try onSave?(notes); return true } catch { showError(error); return false }
    }
    @objc func saveNote() { if flush() { table.reloadData() } }
    @objc func closeNotes() { window?.performClose(nil) }
    @objc func addNote() {
        guard flush() else { return }; notes.append(.init(title: "新备忘录")); loading = true; table.reloadData()
        table.selectRowIndexes(IndexSet(integer: notes.count - 1), byExtendingSelection: false); loading = false
        loadSelection(notes.count - 1); _ = flush(); window?.makeFirstResponder(titleField)
    }
    @objc func deleteNote() {
        guard notes.indices.contains(selected) else { return }
        let alert = NSAlert(); alert.messageText = "删除这条备忘录？"; alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        notes.remove(at: selected); selected = -1; _ = flush(); loading = true; table.reloadData()
        if !notes.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        loading = false; loadSelection(notes.isEmpty ? -1 : 0)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { flush() }
    func windowWillClose(_ notification: Notification) { DispatchQueue.main.async { [weak self] in self?.onClose?() } }
    private func showError(_ error: Error) { let alert = NSAlert(); alert.messageText = "备忘录未保存"; alert.informativeText = error.localizedDescription; alert.runModal() }
}

@MainActor
final class TodoWindowController: NSWindowController, NSWindowDelegate {
    let titleField = NSTextField()
    let editor = NSTextView()
    let datePicker = NSDatePicker()
    let deadlineCheck = NSButton(checkboxWithTitle: "设置截止时间", target: nil, action: nil)
    let completedCheck = NSButton(checkboxWithTitle: "已完成", target: nil, action: nil)
    let remaining = NSTextField(labelWithString: "")
    var onSave: ((Todo) throws -> Void)?
    var onClose: (() -> Void)?
    var timer: Timer?
    init(todo: Todo) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "LeanDock · 待办事项"; window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
                                     root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24)])
        titleField.placeholderString = "待办标题"; titleField.stringValue = todo.title; root.addArrangedSubview(titleField)
        editor.isRichText = false; editor.font = .systemFont(ofSize: 14); editor.string = todo.content
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; root.addArrangedSubview(scroll)
        deadlineCheck.state = todo.deadline == nil ? .off : .on; deadlineCheck.target = self; deadlineCheck.action = #selector(updateCountdown); root.addArrangedSubview(deadlineCheck)
        datePicker.datePickerStyle = .textFieldAndStepper; datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.dateValue = todo.deadline ?? Date().addingTimeInterval(3600); datePicker.target = self; datePicker.action = #selector(updateCountdown); root.addArrangedSubview(datePicker)
        completedCheck.state = todo.completed ? .on : .off; completedCheck.target = self; completedCheck.action = #selector(updateCountdown); root.addArrangedSubview(completedCheck)
        root.addArrangedSubview(remaining); root.addArrangedSubview(NSButton(title: "保存并关闭", target: self, action: #selector(saveTodo)))
        titleField.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true; scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        updateCountdown()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateCountdown() } }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func value() -> Todo {
        var todo = Todo(); todo.title = titleField.stringValue; todo.content = editor.string
        todo.deadline = deadlineCheck.state == .on ? datePicker.dateValue : nil; todo.completed = completedCheck.state == .on; return todo
    }
    @objc func updateCountdown() { datePicker.isEnabled = deadlineCheck.state == .on; remaining.stringValue = "剩余时间：\(value().remaining(at: Date()))" }
    func flush() -> Bool {
        do { try onSave?(value()); return true }
        catch { let alert = NSAlert(); alert.messageText = "待办未保存"; alert.informativeText = error.localizedDescription; alert.runModal(); return false }
    }
    @objc func saveTodo() { window?.performClose(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { flush() }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil; DispatchQueue.main.async { [weak self] in self?.onClose?() } }
}
