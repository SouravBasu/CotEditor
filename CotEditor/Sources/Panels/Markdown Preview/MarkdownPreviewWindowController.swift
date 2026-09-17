//
//  MarkdownPreviewWindowController.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by 1024jp on 2026-09-14.
//
//  ---------------------------------------------------------------------------
//
//  © 2026 1024jp
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import AppKit
import Combine
import SwiftUI
import ControlUI
import StringUtils

final class MarkdownPreviewWindowController: NSWindowController, NSWindowDelegate, @unchecked Sendable {
    
    // MARK: Public Properties
    
    static let shared = MarkdownPreviewWindowController()
    
    private(set) weak var currentDocument: Document?
    
    var isPinned: Bool = false {
        didSet {
            guard self.isPinned != oldValue else { return }
            if !self.isPinned {
                let frontDocument = (NSDocumentController.shared as? DocumentController)?.currentPlainTextDocument
                self.updateTrackedDocument(to: frontDocument)
            }
            self.window?.toolbar?.validateVisibleItems()
        }
    }
    
    var isKeepOnTop: Bool = false {
        didSet {
            guard self.isKeepOnTop != oldValue else { return }
            guard let panel = self.window as? NSPanel else { return }
            panel.level = self.isKeepOnTop ? .floating : .normal
            panel.isFloatingPanel = self.isKeepOnTop
            self.window?.toolbar?.validateVisibleItems()
        }
    }
    
    // MARK: Internal Properties
    
    let containerViewController: MarkdownPreviewContainerViewController
    let previewViewController: MarkdownPreviewViewController
    
    // MARK: Private Properties
    
    private var trackingCancellables: Set<AnyCancellable> = []
    private var documentCancellables: Set<AnyCancellable> = []
    private var fileDocumentObserver: AnyCancellable?
    private var fileURLObserver: NotificationCenter.ObservationToken?
    
    private lazy var debouncer = Debouncer(delay: .milliseconds(75)) { [weak self] in
        self?.flushLiveKeystrokeUpdate()
    }
    
    // MARK: Lifecycle
    
    init() {
        let previewViewController = MarkdownPreviewViewController()
        let containerViewController = MarkdownPreviewContainerViewController(previewViewController: previewViewController)
        let panel = MarkdownPreviewPanel(contentViewController: containerViewController)
        
        panel.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.title = String(localized: "Markdown Preview", table: "MarkdownPreview", comment: "window title")
        panel.setContentSize(NSSize(width: 500, height: 600))
        panel.minSize = NSSize(width: 320, height: 240)
        
        self.previewViewController = previewViewController
        self.containerViewController = containerViewController
        
        super.init(window: panel)
        
        panel.delegate = self
        self.windowFrameAutosaveName = "Markdown Preview"
        
        let toolbar = NSToolbar()
        toolbar.delegate = self
        toolbar.isVisible = true
        toolbar.displayMode = .iconOnly
        panel.toolbar = toolbar
        panel.toolbarStyle = .unifiedCompact
        
        self.startTrackingActiveDocument()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func showWindow(_ sender: Any?) {
        if self.currentDocument == nil, !self.isPinned {
            let frontDocument = (NSDocumentController.shared as? DocumentController)?.currentPlainTextDocument
                ?? (NSDocumentController.shared.documents.first as? Document)
            if let frontDocument {
                self.updateTrackedDocument(to: frontDocument)
            }
        }
        super.showWindow(sender)
    }
    
    // MARK: Public Methods
    
    /// Shows the preview window and brings it to the front, or closes it if already visible and key.
    func toggleWindow(_ sender: Any?) {
        guard let window = self.window else { return }
        
        if window.isVisible, window.isKeyWindow {
            window.performClose(sender)
            if window.isVisible {
                window.close()
            }
        } else {
            self.showWindow(sender)
        }
    }
    
    // MARK: Actions
    
    @IBAction func togglePin(_ sender: Any?) {
        self.isPinned.toggle()
    }
    
    @IBAction func toggleKeepOnTop(_ sender: Any?) {
        self.isKeepOnTop.toggle()
    }
    
    // MARK: Document Tracking & Live Sync
    
    /// Connects observation pipelines to automatically follow the active document across windows and tabs.
    private func startTrackingActiveDocument() {
        // Synchronous initial resolution to avoid initial 100ms debounce lag
        if let initialDocument = (NSDocumentController.shared as? DocumentController)?.currentPlainTextDocument {
            self.updateTrackedDocument(to: initialDocument)
        }
        
        // Two-tier observation: window -> document
        NSApp.publisher(for: \.mainWindow, options: .new)
            .debounce(for: .seconds(0.1), scheduler: RunLoop.main)
            .compactMap { $0?.windowController as? DocumentWindowController }
            .sink { [weak self] windowController in
                guard let self, !self.isPinned else { return }
                
                self.fileDocumentObserver = windowController.publisher(for: \.fileDocument, options: .initial)
                    .debounce(for: .seconds(0.1), scheduler: RunLoop.main)
                    .sink { [weak self] fileDocument in
                        guard let self, !self.isPinned else { return }
                        self.updateTrackedDocument(to: fileDocument as? Document)
                    }
            }
            .store(in: &self.trackingCancellables)
    }
    
    /// Updates document tracking to a new document or displays placeholder if nil.
    func updateTrackedDocument(to document: Document?) {
        guard !self.isPinned else { return }
        guard document !== self.currentDocument else { return }
        
        self.documentCancellables.removeAll()
        self.fileURLObserver = nil
        self.debouncer.cancel()
        self.currentDocument = document
        
        guard let document else {
            self.containerViewController.showPlaceholder()
            self.window?.toolbar?.validateVisibleItems()
            return
        }
        
        self.containerViewController.showPreview()
        self.window?.toolbar?.validateVisibleItems()
        
        // 1. Observe in-memory keystroke edits
        NotificationCenter.default.publisher(for: NSTextStorage.didProcessEditingNotification, object: document.textStorage)
            .compactMap { $0.object as? NSTextStorage }
            .filter { $0.editedMask.contains(.editedCharacters) }
            .sink { [weak self] _ in
                self?.debouncer.schedule()
            }
            .store(in: &self.documentCancellables)
        
        // 2. Observe fileURL changes (Save As, Move, Rename)
        document.publisher(for: \.fileURL)
            .map { $0?.deletingLastPathComponent() }
            .removeDuplicates()
            .sink { [weak self] directoryURL in
                self?.previewViewController.setBaseURL(directoryURL)
            }
            .store(in: &self.documentCancellables)
        
        self.fileURLObserver = NotificationCenter.default.addObserver(for: NSDocument.DidChangeFileURLMessage.self) { [weak self, weak document] _ in
            self?.previewViewController.setBaseURL(document?.fileURL?.deletingLastPathComponent())
        }
        
        // 3. Observe window closing
        if let window = document.windowControllers.first?.window {
            NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
                .sink { [weak self] _ in
                    self?.handleTrackedDocumentClosed()
                }
                .store(in: &self.documentCancellables)
        }
        
        // 4. Initial render for new document (with scroll reset)
        let markdown = document.textStorage.string.immutable
        let baseURL = document.fileURL?.deletingLastPathComponent()
        self.previewViewController.updateMarkdown(markdown, baseURL: baseURL, resetScroll: true)
    }
    
    /// Handles when the tracked document's window closes.
    func handleTrackedDocumentClosed() {
        self.documentCancellables.removeAll()
        self.fileURLObserver = nil
        self.debouncer.cancel()
        self.currentDocument = nil
        
        if !self.isPinned {
            let nextDocument = (NSDocumentController.shared as? DocumentController)?.currentPlainTextDocument
                ?? (NSDocumentController.shared.documents.first as? Document)
            if let nextDocument {
                self.updateTrackedDocument(to: nextDocument)
                return
            }
        }
        
        self.containerViewController.showPlaceholder()
        self.window?.toolbar?.validateVisibleItems()
    }
    
    /// Flushes any pending live keystrokes immediately.
    func flushPendingKeystrokes() {
        self.debouncer.fire()
    }
    
    /// Synchronously takes a defensive snapshot and updates preview without resetting scroll.
    private func flushLiveKeystrokeUpdate() {
        guard let document = self.currentDocument else { return }
        let markdown = document.textStorage.string.immutable
        let baseURL = document.fileURL?.deletingLastPathComponent()
        self.previewViewController.updateMarkdown(markdown, baseURL: baseURL, resetScroll: false)
    }
}

// MARK: - Toolbar Delegate

private extension NSToolbarItem.Identifier {
    
    private static let prefix = "com.coteditor.CotEditor.MarkdownPreview.ToolbarItem."
    
    static let pin = Self(Self.prefix + "pin")
    static let keepOnTop = Self(Self.prefix + "keepOnTop")
}

extension MarkdownPreviewWindowController: NSToolbarDelegate {
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.pin, .keepOnTop]
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.pin, .keepOnTop]
    }
    
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
            case .pin:
                let item = StatableToolbarItem(itemIdentifier: itemIdentifier)
                item.isBordered = true
                item.label = String(localized: "Toolbar.pin.label", defaultValue: "Pin Document", table: "MarkdownPreview")
                item.toolTip = String(localized: "Toolbar.pin.tooltip", defaultValue: "Lock preview to current document", table: "MarkdownPreview")
                item.stateImages[.off] = NSImage(systemSymbolName: "pin", accessibilityDescription: item.label)
                item.stateImages[.on] = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: item.label)
                item.target = self
                item.action = #selector(togglePin)
                item.state = self.isPinned ? .on : .off
                return item
                
            case .keepOnTop:
                let item = StatableToolbarItem(itemIdentifier: itemIdentifier)
                item.isBordered = true
                item.label = String(localized: "Toolbar.keepOnTop.label", defaultValue: "Keep on Top", table: "MarkdownPreview")
                item.toolTip = String(localized: "Toolbar.keepOnTop.tooltip", defaultValue: "Keep preview window always on top", table: "MarkdownPreview")
                item.stateImages[.off] = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: item.label)
                item.stateImages[.on] = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: item.label)
                item.target = self
                item.action = #selector(toggleKeepOnTop)
                item.state = self.isKeepOnTop ? .on : .off
                return item
                
            default:
                return nil
        }
    }
}

// MARK: - User Interface Validations

extension MarkdownPreviewWindowController: NSUserInterfaceValidations {
    
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
            case #selector(togglePin):
                (item as? any StatableItem)?.state = self.isPinned ? .on : .off
                (item as? NSToolbarItem)?.toolTip = self.isPinned
                    ? String(localized: "Toolbar.pin.tooltip.pinned", defaultValue: "Unlock preview to follow active document", table: "MarkdownPreview")
                    : String(localized: "Toolbar.pin.tooltip.unpinned", defaultValue: "Lock preview to current document", table: "MarkdownPreview")
                return self.currentDocument != nil || self.isPinned
                
            case #selector(toggleKeepOnTop):
                (item as? any StatableItem)?.state = self.isKeepOnTop ? .on : .off
                (item as? NSToolbarItem)?.toolTip = self.isKeepOnTop
                    ? String(localized: "Toolbar.keepOnTop.tooltip.floating", defaultValue: "Restore normal window level", table: "MarkdownPreview")
                    : String(localized: "Toolbar.keepOnTop.tooltip.normal", defaultValue: "Keep preview window always on top", table: "MarkdownPreview")
                return true
                
            default:
                return true
        }
    }
}

// MARK: - Panel Subclass

final class MarkdownPreviewPanel: NSPanel {
    
    override var canBecomeMain: Bool {
        false
    }
    
    override var canBecomeKey: Bool {
        true
    }
}

// MARK: - Container View Controller

final class MarkdownPreviewContainerViewController: NSViewController, TextSizeChanging, NSUserInterfaceValidations {
    
    let previewViewController: MarkdownPreviewViewController
    private lazy var placeholderController: NSViewController = {
        let controller = NSHostingController(rootView: MarkdownPreviewPlaceholderView())
        controller.sizingOptions = []
        return controller
    }()
    
    private(set) var isShowingPlaceholder: Bool = true
    
    init(previewViewController: MarkdownPreviewViewController) {
        self.previewViewController = previewViewController
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        let view = NSView()
        self.view = view
        
        let activeChild = self.isShowingPlaceholder ? self.placeholderController : self.previewViewController
        self.addChild(activeChild)
        view.embedSubview(activeChild.view)
    }
    
    func showPreview() {
        guard self.isShowingPlaceholder else { return }
        self.isShowingPlaceholder = false
        
        guard self.isViewLoaded else { return }
        
        self.placeholderController.viewIfLoaded?.removeFromSuperview()
        self.placeholderController.removeFromParent()
        
        self.addChild(self.previewViewController)
        self.view.embedSubview(self.previewViewController.view)
    }
    
    func showPlaceholder() {
        guard !self.isShowingPlaceholder else { return }
        self.isShowingPlaceholder = true
        
        guard self.isViewLoaded else { return }
        
        self.previewViewController.viewIfLoaded?.removeFromSuperview()
        self.previewViewController.removeFromParent()
        
        self.addChild(self.placeholderController)
        self.view.embedSubview(self.placeholderController.view)
    }
    
    // MARK: Zoom Forwarding (TextSizeChanging)
    
    @IBAction func biggerFont(_ sender: Any?) {
        self.previewViewController.biggerFont(sender)
    }
    
    @IBAction func smallerFont(_ sender: Any?) {
        self.previewViewController.smallerFont(sender)
    }
    
    @IBAction func resetFont(_ sender: Any?) {
        self.previewViewController.resetFont(sender)
    }
    
    // MARK: NSUserInterfaceValidations
    
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if !self.isShowingPlaceholder {
            return self.previewViewController.validateUserInterfaceItem(item)
        }
        return false
    }
}

// MARK: - Auto Layout Helper

private extension NSView {
    
    func embedSubview(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            subview.topAnchor.constraint(equalTo: self.topAnchor),
            subview.bottomAnchor.constraint(equalTo: self.bottomAnchor),
        ])
    }
}
