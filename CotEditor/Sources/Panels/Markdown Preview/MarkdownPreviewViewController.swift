//
//  MarkdownPreviewViewController.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by 1024jp on 2026-09-13.
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
import WebKit

@MainActor final class MarkdownPreviewViewController: NSViewController {
    
    // MARK: Private Properties
    
    @ViewLoading private(set) var webView: WKWebView
    
    private let templateHTML: String
    private(set) var currentBaseURL: URL?
    private(set) var lastMarkdown: String?
    
    var isReady: Bool = false
    private var needsFullRender: Bool = true
    var pendingUpdate: (content: String, baseURL: URL?, resetScroll: Bool)?
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    
    
    // MARK: Lifecycle
    
    init() {
        
        self.templateHTML = Self.loadTemplateHTML()
        
        super.init(nibName: nil, bundle: nil)
    }
    
    
    required init?(coder: NSCoder) {
        
        fatalError("init(coder:) has not been implemented")
    }
    
    
    override func loadView() {
        
        let view = NSView()
        
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif
        
        view.addSubview(webView)
        
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            view.topAnchor.constraint(equalTo: webView.topAnchor),
            view.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
        ])
        
        self.webView = webView
        self.view = view
    }
    
    
    override func viewDidLoad() {
        
        super.viewDidLoad()
        
        self.loadTemplate(baseURL: self.currentBaseURL)
    }
    
    
    // MARK: Public Methods
    
    /// Updates the displayed Markdown content.
    ///
    /// - Parameters:
    ///   - markdown: The raw Markdown text to render.
    ///   - baseURL: The directory URL of the active document for relative asset resolution.
    ///   - resetScroll: Whether to reset the scroll position to top (e.g. when switching files).
    func updateMarkdown(_ markdown: String, baseURL: URL? = nil, resetScroll: Bool = false) {
        
        // If directory changed, reload template to establish new security origin
        if baseURL != self.currentBaseURL {
            self.currentBaseURL = baseURL
            self.lastMarkdown = markdown
            self.pendingUpdate = (markdown, baseURL, true)
            if self.isViewLoaded {
                self.loadTemplate(baseURL: baseURL)
            }
            return
        }
        
        let isContentUnchanged = (self.lastMarkdown == markdown)
        self.lastMarkdown = markdown
        
        // If webView is not yet finished loading initial template, queue the update
        guard self.isReady else {
            self.pendingUpdate = (markdown, baseURL, resetScroll)
            return
        }
        
        // Skip identical re-renders if content hasn't changed and scroll reset wasn't requested
        if !self.needsFullRender, !resetScroll, isContentUnchanged {
            return
        }
        self.needsFullRender = false
        
        self.performInPlaceUpdate(content: markdown, baseURL: baseURL, resetScroll: resetScroll)
    }
    
    
    /// Sets the base URL for relative asset resolution, reloading the template if needed.
    ///
    /// - Parameter url: The new base directory URL.
    func setBaseURL(_ url: URL?) {
        
        guard url != self.currentBaseURL else { return }
        
        self.currentBaseURL = url
        self.isReady = false
        
        if let markdown = self.lastMarkdown {
            self.pendingUpdate = (markdown, url, false)
        }
        
        if self.isViewLoaded {
            self.loadTemplate(baseURL: url)
        }
    }
    
    
    // MARK: Internal Methods
    
    /// Loads the HTML template into the web view with the specified base URL.
    func loadTemplate(baseURL: URL?) {
        
        self.isReady = false
        self.needsFullRender = true
        let effectiveBaseURL = baseURL ?? Bundle.main.resourceURL
        self.webView.loadHTMLString(self.templateHTML, baseURL: effectiveBaseURL)
    }
    
    
    /// Flushes any pending update queued during template loading.
    func flushPendingUpdate() {
        
        guard let pending = self.pendingUpdate else { return }
        self.pendingUpdate = nil
        self.updateMarkdown(pending.content, baseURL: pending.baseURL, resetScroll: pending.resetScroll)
    }
    
    
    // MARK: Private Methods
    
    /// Invokes `window.updateMarkdown` via `callAsyncJavaScript`.
    private func performInPlaceUpdate(content: String, baseURL: URL?, resetScroll: Bool) {
        
        self.needsFullRender = false
        
        var baseURIString: String? = nil
        if let url = baseURL {
            let string = url.absoluteString
            baseURIString = string.hasSuffix("/") ? string : string + "/"
        }
        
        let script = "window.updateMarkdown(content, baseURI, resetScroll); return true;"
        let arguments: [String: Any] = [
            "content": content,
            "baseURI": (baseURIString as Any?) ?? NSNull(),
            "resetScroll": resetScroll,
        ]
        
        self.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
            if case .failure(let error) = result {
                assertionFailure("Failed to execute in-place markdown update: \(error)")
            }
        }
    }
    
    
    /// Loads and inlines the bundled preview assets.
    private static func loadTemplateHTML() -> String {
        
        let htmlURL = Self.url(forResource: "preview", withExtension: "html", subdirectory: "Preview")
        let cssURL = Self.url(forResource: "preview", withExtension: "css", subdirectory: "Preview")
        let jsURL = Self.url(forResource: "marked.min", withExtension: "js", subdirectory: "Preview")
        
        guard let htmlURL, let cssURL, let jsURL,
              let rawHTML = try? String(contentsOf: htmlURL, encoding: .utf8),
              let css = try? String(contentsOf: cssURL, encoding: .utf8),
              let js = try? String(contentsOf: jsURL, encoding: .utf8)
        else {
            assertionFailure("Failed to load bundled preview assets.")
            return ""
        }
        
        var html = rawHTML
        
        if html.contains("/* PREVIEW_CSS */") {
            html = html.replacingOccurrences(of: "/* PREVIEW_CSS */", with: css)
        } else if html.contains("<link rel=\"stylesheet\" href=\"preview.css\">") {
            html = html.replacingOccurrences(of: "<link rel=\"stylesheet\" href=\"preview.css\">", with: "<style>\n\(css)\n</style>")
        }
        
        if html.contains("/* MARKED_JS */") {
            html = html.replacingOccurrences(of: "/* MARKED_JS */", with: js)
        } else if html.contains("<script src=\"marked.min.js\"></script>") {
            html = html.replacingOccurrences(of: "<script src=\"marked.min.js\"></script>", with: "<script>\n\(js)\n</script>")
        }
        
        return html
    }
    
    
    /// Locates a resource across known bundles and subdirectories.
    private static func url(forResource name: String, withExtension ext: String, subdirectory: String?) -> URL? {
        
        let bundles = [Bundle(for: MarkdownPreviewViewController.self), Bundle.main]
        for bundle in bundles {
            if let sub = subdirectory, let url = bundle.url(forResource: name, withExtension: ext, subdirectory: sub) {
                return url
            }
            if let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }
}
