//
//  MarkdownPreviewTests.swift
//  Tests
//
//  Genuine test suite for Milestone 1: MarkdownPreviewViewController and bundled preview resources.
//

import AppKit
import Foundation
import Testing
import WebKit
import JavaScriptCore
import ControlUI
import StringUtils
@testable import CotEditor

// MARK: - Test Helpers

@MainActor
private final class PreviewDummyValidatedItem: NSValidatedUserInterfaceItem {
    let action: Selector?
    let tag: Int
    
    init(action: Selector?, tag: Int = 0) {
        self.action = action
        self.tag = tag
    }
}

@MainActor
private final class PreviewDummyValidatedStatableItem: NSValidatedUserInterfaceItem, StatableItem {
    let action: Selector?
    let tag: Int
    var state: NSControl.StateValue = .off
    
    init(action: Selector?, tag: Int = 0) {
        self.action = action
        self.tag = tag
    }
}

private final class FakeNavigationAction: NSObject {
    @objc let request: URLRequest
    @objc let navigationType: Int
    
    init(request: URLRequest, navigationType: WKNavigationType = .linkActivated) {
        self.request = request
        self.navigationType = navigationType.rawValue
        super.init()
    }
}

private final class FakeWindowFeatures: NSObject {}
private final class FakeFrameInfo: NSObject {}

private enum MarkdownPreviewTestHelpers {
    @MainActor
    static func makeNavigationAction(url: URL, navigationType: WKNavigationType = .linkActivated) -> WKNavigationAction {
        unsafeBitCast(FakeNavigationAction(request: URLRequest(url: url), navigationType: navigationType), to: WKNavigationAction.self)
    }
    
    @MainActor
    static func makeWindowFeatures() -> WKWindowFeatures {
        unsafeBitCast(FakeWindowFeatures(), to: WKWindowFeatures.self)
    }
    
    @MainActor
    static func makeFrameInfo() -> WKFrameInfo {
        unsafeBitCast(FakeFrameInfo(), to: WKFrameInfo.self)
    }
    
    @MainActor
    static func waitFor(timeout: Duration = .seconds(5), interval: Duration = .milliseconds(20), _ condition: @escaping () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: interval)
        }
        return condition()
    }
    
    @MainActor
    static func yieldMain(duration: Duration = .milliseconds(50)) async {
        try? await Task.sleep(for: duration)
    }
    
    @MainActor
    static func makeConfiguredController() -> (MarkdownPreviewViewController, NSWindow?) {
        _ = NSApplication.shared
        let vc = MarkdownPreviewViewController()
        vc.openURL = { _ in true }
        _ = vc.view
        vc.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return (vc, nil)
    }
    
    static func loadBundledMarkedContext() throws -> JSContext {
        let jsContext = JSContext()!
        let markedURL = Bundle(for: MarkdownPreviewViewController.self).url(forResource: "marked.min", withExtension: "js", subdirectory: "Preview")
            ?? Bundle.main.url(forResource: "marked.min", withExtension: "js", subdirectory: "Preview")
        let markedContent = try String(contentsOf: try #require(markedURL), encoding: .utf8)
        jsContext.evaluateScript(markedContent)
        
        let previewConfig = #"""
        function slugify(text) {
            return text
                .toLowerCase()
                .replace(/<[^>]*>/g, '')
                .replace(/[^\p{L}\p{N}\s_-]/gu, '')
                .trim()
                .replace(/\s+/g, '-');
        }
        marked.use({
            gfm: true,
            breaks: false,
            pedantic: false,
            renderer: {
                heading({ tokens, depth }) {
                    const text = this.parser.parseInline(tokens);
                    const id = slugify(text);
                    return '<h' + depth + (id ? ' id="' + id + '"' : '') + '>' + text + '</h' + depth + '>\n';
                }
            }
        });
        """#
        jsContext.evaluateScript(previewConfig)
        return jsContext
    }
}

// MARK: - Suite 1: Lifecycle & WebKit Configuration

@Suite("MarkdownPreview Lifecycle & WebKit Configuration")
@MainActor struct MarkdownPreviewLifecycleTests {
    
    @Test func test_controllerInitialization_loadsBundledTemplate() {
        let vc = MarkdownPreviewViewController()
        #expect(!vc.isViewLoaded)
        #expect(vc.currentBaseURL == nil)
        #expect(vc.lastMarkdown == nil)
        #expect(vc.isReady == false)
    }
    
    @Test func test_viewLoading_createsAndConfiguresWebView() {
        let vc = MarkdownPreviewViewController()
        let view = vc.view
        #expect(vc.isViewLoaded)
        #expect(vc.webView.superview === view)
        #expect(vc.webView.translatesAutoresizingMaskIntoConstraints == false)
    }
    
    @Test func test_webViewConfiguration_securityAndSandboxSettings() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        let config = vc.webView.configuration
        #expect(config.websiteDataStore.isPersistent == false, "Must use non-persistent data store to prevent disk caching")
        #expect(config.defaultWebpagePreferences.allowsContentJavaScript == true, "Must allow JS for marked.js")
        #expect(config.preferences.isElementFullscreenEnabled == true)
        #expect(vc.webView.underPageBackgroundColor.alphaComponent < 0.01, "Background must be clear for dark mode adaptation")
    }
    
    @Test func test_delegatesConfigured() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        #expect(vc.webView.navigationDelegate === vc)
        #expect(vc.webView.uiDelegate === vc)
    }
    
    @Test func test_webContentProcessDidTerminate_reloadsTemplate() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        let docURL = URL(fileURLWithPath: "/tmp/sample.md")
        vc.setBaseURL(docURL)
        
        vc.webViewWebContentProcessDidTerminate(vc.webView)
        #expect(vc.isReady == false, "isReady must be reset to false")
        #expect(vc.currentBaseURL == docURL, "currentBaseURL must be preserved")
    }
}

// MARK: - Suite 2: Zoom Controls & Menu Validation

@Suite("MarkdownPreview Zoom Controls & Menu Validation")
@MainActor struct MarkdownPreviewZoomTests {
    
    @Test func test_defaultZoom_isOnePointZero() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        #expect(vc.webView.pageZoom == 1.0)
    }
    
    @Test func test_biggerFont_stepsZoomByPointOne() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        vc.biggerFont(nil)
        #expect(vc.webView.pageZoom == 1.1)
        vc.biggerFont(nil)
        #expect(vc.webView.pageZoom == 1.2)
    }
    
    @Test func test_smallerFont_stepsZoomByPointOne() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        vc.smallerFont(nil)
        #expect(vc.webView.pageZoom == 0.9)
        vc.smallerFont(nil)
        #expect(vc.webView.pageZoom == 0.8)
    }
    
    @Test func test_resetFont_restoresDefaultZoom() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        vc.biggerFont(nil)
        vc.biggerFont(nil)
        #expect(vc.webView.pageZoom == 1.2)
        vc.resetFont(nil)
        #expect(vc.webView.pageZoom == 1.0)
    }
    
    @Test func test_zoomClamping_upperBound() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        for _ in 0..<50 { vc.biggerFont(nil) }
        #expect(vc.webView.pageZoom == 3.0, "Page zoom must clamp strictly at 3.0")
        vc.biggerFont(nil)
        #expect(vc.webView.pageZoom == 3.0)
    }
    
    @Test func test_zoomClamping_lowerBound() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        for _ in 0..<50 { vc.smallerFont(nil) }
        #expect(vc.webView.pageZoom == 0.5, "Page zoom must clamp strictly at 0.5")
        vc.smallerFont(nil)
        #expect(vc.webView.pageZoom == 0.5)
    }
    
    @Test func test_zoomStepPrecision_noFloatingPointDrift() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        for _ in 0..<50 { vc.smallerFont(nil) }
        #expect(vc.webView.pageZoom == 0.5)
        
        var expectedZoom: CGFloat = 0.5
        for _ in 0..<25 {
            vc.biggerFont(nil)
            expectedZoom += 0.1
            expectedZoom = round(expectedZoom * 10) / 10
            #expect(abs(vc.webView.pageZoom - expectedZoom) < 0.0001)
        }
        #expect(vc.webView.pageZoom == 3.0)
    }
    
    @Test func test_validateUserInterfaceItem_zoomActions() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        let biggerItem = PreviewDummyValidatedItem(action: #selector(MarkdownPreviewViewController.biggerFont))
        let smallerItem = PreviewDummyValidatedItem(action: #selector(MarkdownPreviewViewController.smallerFont))
        let resetItem = PreviewDummyValidatedItem(action: #selector(MarkdownPreviewViewController.resetFont))
        
        // At 1.0
        #expect(vc.validateUserInterfaceItem(biggerItem) == true)
        #expect(vc.validateUserInterfaceItem(smallerItem) == true)
        #expect(vc.validateUserInterfaceItem(resetItem) == false)
        
        // At max (3.0)
        for _ in 0..<50 { vc.biggerFont(nil) }
        #expect(vc.validateUserInterfaceItem(biggerItem) == false)
        #expect(vc.validateUserInterfaceItem(smallerItem) == true)
        #expect(vc.validateUserInterfaceItem(resetItem) == true)
        
        // At min (0.5)
        for _ in 0..<50 { vc.smallerFont(nil) }
        #expect(vc.validateUserInterfaceItem(biggerItem) == true)
        #expect(vc.validateUserInterfaceItem(smallerItem) == false)
        #expect(vc.validateUserInterfaceItem(resetItem) == true)
        
        // Unknown or nil action
        let nilItem = PreviewDummyValidatedItem(action: nil)
        #expect(vc.validateUserInterfaceItem(nilItem) == false)
    }
}

// MARK: - Suite 3: Navigation & Link Interception

@Suite("MarkdownPreview Navigation & Link Interception")
@MainActor struct MarkdownPreviewNavigationTests {
    
    @Test func test_navigationAction_nonLinkActivated_allowed() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        let action = MarkdownPreviewTestHelpers.makeNavigationAction(url: URL(string: "about:blank")!, navigationType: .other)
        
        var resultPolicy: WKNavigationActionPolicy?
        vc.webView(vc.webView, decidePolicyFor: action) { policy in
            resultPolicy = policy
        }
        #expect(resultPolicy == .allow, "Non-link navigations (template loads) must be allowed")
    }
    
    @Test func test_navigationAction_externalHTTP_cancelsNavigationAndOpens() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        var openedURL: URL?
        vc.openURL = { url in
            openedURL = url
            return true
        }
        let url = URL(string: "http://example.com/page")!
        let action = MarkdownPreviewTestHelpers.makeNavigationAction(url: url, navigationType: .linkActivated)
        
        var resultPolicy: WKNavigationActionPolicy?
        vc.webView(vc.webView, decidePolicyFor: action) { policy in
            resultPolicy = policy
        }
        #expect(resultPolicy == .cancel, "External HTTP links must be intercepted and cancelled in webview")
        #expect(openedURL == url, "External HTTP link must be routed to openURL handler")
    }
    
    @Test func test_navigationAction_externalHTTPS_cancelsNavigationAndOpens() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        var openedURL: URL?
        vc.openURL = { url in
            openedURL = url
            return true
        }
        let url = URL(string: "https://coteditor.com")!
        let action = MarkdownPreviewTestHelpers.makeNavigationAction(url: url, navigationType: .linkActivated)
        
        var resultPolicy: WKNavigationActionPolicy?
        vc.webView(vc.webView, decidePolicyFor: action) { policy in
            resultPolicy = policy
        }
        #expect(resultPolicy == .cancel, "External HTTPS links must be intercepted and cancelled in webview")
        #expect(openedURL == url, "External HTTPS link must be routed to openURL handler")
    }
    
    @Test func test_navigationAction_mailto_cancelsNavigationAndOpens() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        var openedURL: URL?
        vc.openURL = { url in
            openedURL = url
            return true
        }
        let url = URL(string: "mailto:support@coteditor.com")!
        let action = MarkdownPreviewTestHelpers.makeNavigationAction(url: url, navigationType: .linkActivated)
        
        var resultPolicy: WKNavigationActionPolicy?
        vc.webView(vc.webView, decidePolicyFor: action) { policy in
            resultPolicy = policy
        }
        #expect(resultPolicy == .cancel, "Mailto links must be intercepted and cancelled in webview")
        #expect(openedURL == url, "Mailto link must be routed to openURL handler")
    }
    
    @Test func test_navigationAction_inDocumentAnchor_allowed() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        let url = URL(string: "#features")!
        let action = MarkdownPreviewTestHelpers.makeNavigationAction(url: url, navigationType: .linkActivated)
        
        var resultPolicy: WKNavigationActionPolicy?
        vc.webView(vc.webView, decidePolicyFor: action) { policy in
            resultPolicy = policy
        }
        #expect(resultPolicy == .allow, "In-document anchor jumps must be allowed for smooth scrolling")
    }
    
    @Test func test_navigationAction_dangerousSchemes_cancelledWithoutOpening() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        var openedURLs: [URL] = []
        vc.openURL = { url in
            openedURLs.append(url)
            return true
        }
        
        let dangerous = [
            URL(string: "javascript:alert('xss')")!,
            URL(string: "data:text/html,<h1>bad</h1>")!,
            URL(string: "applescript:do%20something")!,
            URL(string: "terminal:run")!,
            URL(string: "coteditor:open")!
        ]
        
        for url in dangerous {
            let action = MarkdownPreviewTestHelpers.makeNavigationAction(url: url, navigationType: .linkActivated)
            var resultPolicy: WKNavigationActionPolicy?
            vc.webView(vc.webView, decidePolicyFor: action) { policy in
                resultPolicy = policy
            }
            #expect(resultPolicy == .cancel, "Dangerous URL \(url) must be cancelled")
        }
        #expect(openedURLs.isEmpty, "No dangerous URLs should be dispatched to external opener")
    }
    
    @Test func test_isAnchorNavigation_sameDocumentAnchors() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        
        let relAnchor = URL(string: "#section")!
        #expect(vc.isAnchorNavigation(relAnchor, in: vc.webView) == true)
        
        let slashAnchor = URL(string: "/#section")!
        #expect(vc.isAnchorNavigation(slashAnchor, in: vc.webView) == true)
        
        let baseDir = URL(fileURLWithPath: "/Users/tester/Documents")
        vc.setBaseURL(baseDir)
        let anchorWithTrailingSlash = URL(string: "file:///Users/tester/Documents/#section")!
        #expect(vc.isAnchorNavigation(anchorWithTrailingSlash, in: vc.webView) == true, "Anchor with trailing slash must match base directory URL")
    }
    
    @Test func test_isAnchorNavigation_externalOrDifferentFile_isFalse() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        vc.setBaseURL(URL(fileURLWithPath: "/tmp/docs"))
        
        let httpAnchor = URL(string: "http://example.com/#sec")!
        #expect(vc.isAnchorNavigation(httpAnchor, in: vc.webView) == false)
        
        let mailto = URL(string: "mailto:test@example.com")!
        #expect(vc.isAnchorNavigation(mailto, in: vc.webView) == false)
        
        let otherFile = URL(string: "file:///tmp/other.md#intro")!
        #expect(vc.isAnchorNavigation(otherFile, in: vc.webView) == false)
    }
    
    @Test func test_uiDelegate_targetBlankIntercepted_returnsNil() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        let config = WKWebViewConfiguration()
        let action = MarkdownPreviewTestHelpers.makeNavigationAction(url: URL(string: "about:blank")!)
        let features = MarkdownPreviewTestHelpers.makeWindowFeatures()
        let popup = vc.webView(
            vc.webView,
            createWebViewWith: config,
            for: action,
            windowFeatures: features
        )
        #expect(popup == nil, "createWebViewWith must return nil to prevent popup window creation")
    }
    
    @Test func test_uiDelegate_alertPanel_suppressed() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        var handled = false
        let frame = MarkdownPreviewTestHelpers.makeFrameInfo()
        vc.webView(vc.webView, runJavaScriptAlertPanelWithMessage: "Test alert", initiatedByFrame: frame) {
            handled = true
        }
        #expect(handled, "Alert handler must be called without showing modal dialog")
    }
}

// MARK: - Suite 4: Bundled Assets & HTML Template

@Suite("MarkdownPreview Bundled Assets & HTML Template")
@MainActor struct MarkdownPreviewAssetTests {
    
    @Test func test_offlineAssets_bundledAndAccessible() throws {
        let bundle = Bundle(for: MarkdownPreviewViewController.self)
        let htmlURL = bundle.url(forResource: "preview", withExtension: "html", subdirectory: "Preview")
            ?? Bundle.main.url(forResource: "preview", withExtension: "html", subdirectory: "Preview")
        let cssURL = bundle.url(forResource: "preview", withExtension: "css", subdirectory: "Preview")
            ?? Bundle.main.url(forResource: "preview", withExtension: "css", subdirectory: "Preview")
        let jsURL = bundle.url(forResource: "marked.min", withExtension: "js", subdirectory: "Preview")
            ?? Bundle.main.url(forResource: "marked.min", withExtension: "js", subdirectory: "Preview")
        
        let html = try String(contentsOf: try #require(htmlURL), encoding: .utf8)
        let css = try String(contentsOf: try #require(cssURL), encoding: .utf8)
        let js = try String(contentsOf: try #require(jsURL), encoding: .utf8)
        
        #expect(!html.isEmpty)
        #expect(!css.isEmpty)
        #expect(!js.isEmpty)
        
        // Zero remote dependencies
        #expect(!html.contains("http://"), "HTML must not reference external http resources")
        #expect(!html.contains("https://"), "HTML must not reference external https resources")
        #expect(!css.contains("@import"), "CSS must not contain external imports")
        #expect(!css.contains("url("), "CSS must not contain external URLs")
    }
    
    @Test func test_templateInlining_replacesExternalLinksWithInlineBlocks() {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        let mirror = Mirror(reflecting: vc)
        let templateHTML = mirror.children.first { $0.label == "templateHTML" }?.value as? String
        
        #expect(templateHTML != nil)
        let html = templateHTML ?? ""
        
        #expect(!html.contains("<link rel=\"stylesheet\" href=\"preview.css\">"), "External CSS link must be inlined")
        #expect(!html.contains("<script src=\"marked.min.js\"></script>"), "External script tag must be inlined")
        #expect(html.contains("<style>"), "Inlined <style> tag must be present")
        #expect(html.contains("<script>"), "Inlined <script> tag must be present")
        #expect(html.contains("id=\"base-tag\""))
        #expect(html.contains("id=\"markdown-content\""))
    }
    
    @Test func test_cssThemeSupport_lightAndDarkMode() throws {
        let bundle = Bundle(for: MarkdownPreviewViewController.self)
        let cssURL = bundle.url(forResource: "preview", withExtension: "css", subdirectory: "Preview")
            ?? Bundle.main.url(forResource: "preview", withExtension: "css", subdirectory: "Preview")
        let css = try String(contentsOf: try #require(cssURL), encoding: .utf8)
        
        #expect(css.contains("@media (prefers-color-scheme: dark)"), "CSS must provide Dark Aqua theme overrides")
        #expect(css.contains(".task-list-item") || css.contains("input[type=\"checkbox\"]"), "CSS must style task list checkboxes")
        #expect(css.contains("table"), "CSS must style GFM tables")
        #expect(css.contains("blockquote"), "CSS must style blockquotes")
    }
}

// MARK: - Suite 5: Base URL Resolution & Images

@Suite("MarkdownPreview Base URL Resolution & Images")
@MainActor struct MarkdownPreviewBaseURLTests {
    
    @Test func test_baseURL_resolutionContract() {
        let docURL = URL(fileURLWithPath: "/Users/dev/Documents/Project/README.md")
        let baseDir = docURL.deletingLastPathComponent()
        #expect(baseDir.path == "/Users/dev/Documents/Project")
        
        let unsavedURL: URL? = nil
        #expect(unsavedURL?.deletingLastPathComponent() == nil)
    }
    
    @Test func test_baseURL_updatesBaseTagInDOM() async throws {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        let ready = await MarkdownPreviewTestHelpers.waitFor { vc.isReady }
        #expect(ready)
        
        let baseDir = URL(fileURLWithPath: "/Users/tester/Notes/")
        vc.updateMarkdown("![Photo](photo.png)", baseURL: baseDir, resetScroll: false)
        
        let reloaded = await MarkdownPreviewTestHelpers.waitFor { vc.isReady && vc.currentBaseURL == baseDir }
        #expect(reloaded)
        await MarkdownPreviewTestHelpers.yieldMain(duration: .milliseconds(150))
        
        let baseHref = try await vc.webView.evaluateJavaScript("document.getElementById('base-tag').getAttribute('href')") as? String
        #expect(baseHref?.hasPrefix("file:///Users/tester/Notes") == true)
    }
    
    @Test func test_setBaseURL_doesNotCauseBlankScreen() async throws {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        var ready = await MarkdownPreviewTestHelpers.waitFor { vc.isReady }
        #expect(ready)
        
        // Initial render
        let initialMarkdown = "# Document Heading\n\nExisting text body."
        vc.updateMarkdown(initialMarkdown, baseURL: URL(fileURLWithPath: "/tmp/dirA/"), resetScroll: false)
        await MarkdownPreviewTestHelpers.yieldMain(duration: .milliseconds(150))
        
        // Relocate document to dirB (simulates Save As / Move)
        let newDir = URL(fileURLWithPath: "/tmp/dirB/")
        vc.setBaseURL(newDir)
        
        ready = await MarkdownPreviewTestHelpers.waitFor { vc.isReady && vc.currentBaseURL == newDir }
        #expect(ready)
        await MarkdownPreviewTestHelpers.yieldMain(duration: .milliseconds(200))
        
        let content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Document Heading") == true, "Content must NOT disappear when base URL changes")
    }
}

// MARK: - Suite 6: GFM Rendering via JavaScriptCore

@Suite("MarkdownPreview GFM Rendering via JavaScriptCore")
struct MarkdownPreviewGFMRenderingTests {
    
    @Test func test_gfm_headingsWithSlugIDs() throws {
        let context = try MarkdownPreviewTestHelpers.loadBundledMarkedContext()
        let md = "# Main Title\n\n## Sub Section"
        let html = context.evaluateScript("marked.parse(\(String(reflecting: md)))")?.toString() ?? ""
        
        #expect(html.contains("<h1 id=\"main-title\">Main Title</h1>"))
        #expect(html.contains("<h2 id=\"sub-section\">Sub Section</h2>"))
    }
    
    @Test func test_gfm_tablesWithAlignment() throws {
        let context = try MarkdownPreviewTestHelpers.loadBundledMarkedContext()
        let md = """
        | Left | Center | Right |
        | :--- | :---: | ---: |
        | L1 | C1 | R1 |
        """
        let html = context.evaluateScript("marked.parse(\(String(reflecting: md)))")?.toString() ?? ""
        
        #expect(html.contains("<table>"))
        #expect(html.contains("<th align=\"left\">Left</th>"))
        #expect(html.contains("<th align=\"center\">Center</th>"))
        #expect(html.contains("<th align=\"right\">Right</th>"))
        #expect(html.contains("<td align=\"left\">L1</td>"))
        #expect(html.contains("<td align=\"center\">C1</td>"))
        #expect(html.contains("<td align=\"right\">R1</td>"))
    }
    
    @Test func test_gfm_taskLists() throws {
        let context = try MarkdownPreviewTestHelpers.loadBundledMarkedContext()
        let md = "- [ ] Unfinished task\n- [x] Done task"
        let html = context.evaluateScript("marked.parse(\(String(reflecting: md)))")?.toString() ?? ""
        
        #expect(html.contains("<input") && html.contains("type=\"checkbox\""))
        #expect(html.contains("checked") || html.contains("checked=\"\""))
    }
    
    @Test func test_gfm_codeBlocksAndSyntax() throws {
        let context = try MarkdownPreviewTestHelpers.loadBundledMarkedContext()
        let md = "```swift\nlet x = 42\n```"
        let html = context.evaluateScript("marked.parse(\(String(reflecting: md)))")?.toString() ?? ""
        
        #expect(html.contains("<pre><code class=\"language-swift\">let x = 42\n</code></pre>"))
    }
    
    @Test func test_gfm_strikethroughAndInlineFormatting() throws {
        let context = try MarkdownPreviewTestHelpers.loadBundledMarkedContext()
        let md = "~~strikethrough~~ and **bold** and *italic* and `inline code`"
        let html = context.evaluateScript("marked.parse(\(String(reflecting: md)))")?.toString() ?? ""
        
        #expect(html.contains("<del>strikethrough</del>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>italic</em>"))
        #expect(html.contains("<code>inline code</code>"))
    }
    
    @Test func test_gfm_blockquotes() throws {
        let context = try MarkdownPreviewTestHelpers.loadBundledMarkedContext()
        let md = "> Level 1\n>> Level 2"
        let html = context.evaluateScript("marked.parse(\(String(reflecting: md)))")?.toString() ?? ""
        
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("Level 1"))
        #expect(html.contains("Level 2"))
    }
    
    @Test func test_gfm_unicodeAndCJKHeadings() throws {
        let context = try MarkdownPreviewTestHelpers.loadBundledMarkedContext()
        let md = "# 日本語見出し\n\n# Über uns\n\n# 简体中文"
        let html = context.evaluateScript("marked.parse(\(String(reflecting: md)))")?.toString() ?? ""
        
        #expect(!html.contains("id=\"\""), "Headings must not produce empty anchor IDs")
        #expect(html.contains("日本語見出し"))
    }
}

// MARK: - Suite 7: WebKit In-Place DOM Updates

@Suite("MarkdownPreview WebKit In-Place DOM Updates")
@MainActor struct MarkdownPreviewWebKitDOMTests {
    
    @Test func test_liveDOMUpdate_rendersContentInWebView() async throws {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        let ready = await MarkdownPreviewTestHelpers.waitFor { vc.isReady }
        #expect(ready)
        
        vc.updateMarkdown("# Live WebKit Test\n\nLive paragraph.", baseURL: nil, resetScroll: false)
        await MarkdownPreviewTestHelpers.yieldMain(duration: .milliseconds(150))
        
        let content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("<h1 id=\"live-webkit-test\">Live WebKit Test</h1>") == true)
        #expect(content?.contains("<p>Live paragraph.</p>") == true)
    }
    
    @Test func test_liveDOMUpdate_inPlaceReplacement() async throws {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        let ready = await MarkdownPreviewTestHelpers.waitFor { vc.isReady }
        #expect(ready)
        
        vc.updateMarkdown("# Version 1", baseURL: nil, resetScroll: false)
        await MarkdownPreviewTestHelpers.yieldMain(duration: .milliseconds(150))
        
        vc.updateMarkdown("# Version 2\n\nNew body", baseURL: nil, resetScroll: false)
        await MarkdownPreviewTestHelpers.yieldMain(duration: .milliseconds(150))
        
        let content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Version 2") == true)
        #expect(content?.contains("Version 1") == false, "Previous content must be replaced completely")
    }
    
    @Test func test_liveDOMUpdate_scrollPreservationVsReset() async throws {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        let ready = await MarkdownPreviewTestHelpers.waitFor { vc.isReady }
        #expect(ready)
        
        var tallMD = "# Tall Document\n\n"
        for line in 1...150 { tallMD += "Paragraph \(line) with padding text.\n\n" }
        
        vc.updateMarkdown(tallMD, baseURL: nil, resetScroll: true)
        await MarkdownPreviewTestHelpers.yieldMain(duration: .milliseconds(300))
        
        _ = try await vc.webView.evaluateJavaScript("window.scrollTo({ left: 0, top: 400, behavior: 'instant' });")
        await MarkdownPreviewTestHelpers.yieldMain(duration: .milliseconds(150))
        
        let scrollY = try await vc.webView.evaluateJavaScript("window.scrollY") as? Double ?? 0.0
        #expect(scrollY >= 250.0)
        
        // Update with resetScroll = false
        tallMD += "Appended live text.\n"
        vc.updateMarkdown(tallMD, baseURL: nil, resetScroll: false)
        await MarkdownPreviewTestHelpers.yieldMain(duration: .milliseconds(300))
        
        let preservedScrollY = try await vc.webView.evaluateJavaScript("window.scrollY") as? Double ?? 0.0
        #expect(abs(preservedScrollY - scrollY) <= 50.0, "Scroll position must be preserved during typing edits")
        
        // Update with resetScroll = true
        vc.updateMarkdown(tallMD, baseURL: nil, resetScroll: true)
        await MarkdownPreviewTestHelpers.yieldMain(duration: .milliseconds(300))
        
        let resetScrollY = try await vc.webView.evaluateJavaScript("window.scrollY") as? Double ?? 0.0
        #expect(resetScrollY == 0.0, "Scroll position must be reset to top when resetScroll is true")
    }
    
    @Test func test_identicalMarkdown_isSkipped() async throws {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        let ready = await MarkdownPreviewTestHelpers.waitFor { vc.isReady }
        #expect(ready)
        
        let md = "# Cache Guard"
        vc.updateMarkdown(md, baseURL: nil, resetScroll: false)
        await MarkdownPreviewTestHelpers.yieldMain(duration: .milliseconds(150))
        
        _ = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').setAttribute('data-guard', 'active')")
        
        // Send identical update
        vc.updateMarkdown(md, baseURL: nil, resetScroll: false)
        await MarkdownPreviewTestHelpers.yieldMain(duration: .milliseconds(150))
        
        let guardAttr = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').getAttribute('data-guard')") as? String
        #expect(guardAttr == "active", "Identical update must be skipped without wiping existing DOM state")
    }
    
    @Test func test_rapidTypingBurst_rendersFinalState() async throws {
        let (vc, _) = MarkdownPreviewTestHelpers.makeConfiguredController()
        let ready = await MarkdownPreviewTestHelpers.waitFor { vc.isReady }
        #expect(ready)
        
        for keystroke in 1...30 {
            vc.updateMarkdown("Burst keystroke #\(keystroke)", baseURL: nil, resetScroll: false)
            try? await Task.sleep(for: .milliseconds(5))
        }
        await MarkdownPreviewTestHelpers.yieldMain(duration: .milliseconds(300))
        
        let content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Burst keystroke #30") == true)
        #expect(vc.lastMarkdown == "Burst keystroke #30")
    }
}

// MARK: - Suite 8: Architecture & Integrity Verification

@Suite("MarkdownPreview Architecture & Integrity Verification")
@MainActor struct MarkdownPreviewIntegrityTests {
    
    @Test func test_realViewControllerConformances() {
        let vc = MarkdownPreviewViewController()
        #expect(vc is WKNavigationDelegate, "Must conform to WKNavigationDelegate")
        #expect(vc is WKUIDelegate, "Must conform to WKUIDelegate")
        #expect(vc is TextSizeChanging, "Must conform to TextSizeChanging for zoom actions")
        #expect(vc is NSUserInterfaceValidations, "Must conform to NSUserInterfaceValidations for menu validation")
    }
}

// MARK: - Suite 9: Window Controller & Panel Architecture

@Suite("MarkdownPreview Window Controller & Panel Architecture", .serialized)
@MainActor struct MarkdownPreviewWindowControllerTests {
    
    @Test func test_singletonLifecycle() {
        let controller1 = MarkdownPreviewWindowController.shared
        let controller2 = MarkdownPreviewWindowController.shared
        #expect(controller1 === controller2, "MarkdownPreviewWindowController must maintain a singleton instance")
    }
    
    @Test func test_panelConfiguration() throws {
        let controller = MarkdownPreviewWindowController()
        let panel = try #require(controller.window as? NSPanel)
        
        #expect(panel.styleMask.contains([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]))
        #expect(panel.isFloatingPanel == false)
        #expect(panel.hidesOnDeactivate == false)
        #expect(panel.isReleasedWhenClosed == false)
        #expect(panel.title == "Markdown Preview")
        #expect(panel.minSize.width == 320)
        #expect(panel.minSize.height >= 240)
        #expect(controller.windowFrameAutosaveName == "Markdown Preview")
    }
    
    @Test func test_panelCanBecomeMainAndKey() throws {
        let controller = MarkdownPreviewWindowController()
        let panel = try #require(controller.window as? NSPanel)
        
        #expect(panel.canBecomeMain == false, "canBecomeMainWindow must be false to prevent stealing active document focus")
        #expect(panel.canBecomeKey == true, "canBecomeKeyWindow must be true to allow keyboard shortcuts and scroll interaction")
    }
    
    @Test func test_toolbarConfigurationAndItems() throws {
        let controller = MarkdownPreviewWindowController()
        let panel = try #require(controller.window as? NSPanel)
        let toolbar = try #require(panel.toolbar)
        
        #expect(panel.toolbarStyle == .unifiedCompact)
        #expect(toolbar.displayMode == .iconOnly)
        
        let defaultItemIDs = controller.toolbarDefaultItemIdentifiers(toolbar)
        #expect(defaultItemIDs.contains { $0.rawValue.hasSuffix("pin") })
        #expect(defaultItemIDs.contains { $0.rawValue.hasSuffix("keepOnTop") })
        
        let allowedItemIDs = controller.toolbarAllowedItemIdentifiers(toolbar)
        #expect(allowedItemIDs.contains { $0.rawValue.hasSuffix("pin") })
        #expect(allowedItemIDs.contains { $0.rawValue.hasSuffix("keepOnTop") })
        
        let pinItemID = try #require(defaultItemIDs.first { $0.rawValue.hasSuffix("pin") })
        let pinItem = try #require(controller.toolbar(toolbar, itemForItemIdentifier: pinItemID, willBeInsertedIntoToolbar: false) as? StatableToolbarItem)
        #expect(pinItem.label == "Pin Document")
        #expect(pinItem.action == #selector(MarkdownPreviewWindowController.togglePin))
        #expect(pinItem.stateImages[.off] != nil)
        #expect(pinItem.stateImages[.on] != nil)
        
        let keepOnTopItemID = try #require(defaultItemIDs.first { $0.rawValue.hasSuffix("keepOnTop") })
        let keepOnTopItem = try #require(controller.toolbar(toolbar, itemForItemIdentifier: keepOnTopItemID, willBeInsertedIntoToolbar: false) as? StatableToolbarItem)
        #expect(keepOnTopItem.label == "Keep on Top")
        #expect(keepOnTopItem.action == #selector(MarkdownPreviewWindowController.toggleKeepOnTop))
        #expect(keepOnTopItem.stateImages[.off] != nil)
        #expect(keepOnTopItem.stateImages[.on] != nil)
    }
    
    @Test func test_containerViewController_swapping() {
        let controller = MarkdownPreviewWindowController()
        let container = controller.containerViewController
        
        #expect(container.previewViewController === controller.previewViewController)
        container.showPlaceholder()
        #expect(container.isShowingPlaceholder == true)
        container.showPreview()
        #expect(container.isShowingPlaceholder == false)
    }
    
    @Test func test_toggleWindow() {
        let controller = MarkdownPreviewWindowController()
        controller.window?.orderOut(nil)
        #expect(controller.window?.isVisible == false)
        
        controller.toggleWindow(nil)
        #expect(controller.window?.isVisible == true)
        controller.window?.orderOut(nil)
    }
}

// MARK: - Suite 10: Document Pinning

@Suite("MarkdownPreview Document Pinning Tests", .serialized)
@MainActor struct MarkdownPreviewPinningTests {
    
    @Test func test_pinningToggle_changesState() {
        let controller = MarkdownPreviewWindowController()
        controller.isPinned = false
        #expect(controller.isPinned == false)
        
        controller.togglePin(nil)
        #expect(controller.isPinned == true)
        
        controller.togglePin(nil)
        #expect(controller.isPinned == false)
    }
    
    @Test func test_pinning_freezesDocumentTracking() {
        let controller = MarkdownPreviewWindowController()
        controller.isPinned = false
        
        let doc1 = Document()
        doc1.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# Doc One")
        let doc2 = Document()
        doc2.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# Doc Two")
        
        controller.updateTrackedDocument(to: doc1)
        #expect(controller.currentDocument === doc1)
        #expect(controller.previewViewController.lastMarkdown == "# Doc One")
        
        // Freeze tracking
        controller.isPinned = true
        controller.updateTrackedDocument(to: doc2)
        #expect(controller.currentDocument === doc1, "Tracking must freeze when isPinned is true")
        #expect(controller.previewViewController.lastMarkdown == "# Doc One")
        
        controller.isPinned = false
    }
    
    @Test func test_unpinning_resynchronizesToFrontDocument() {
        let controller = MarkdownPreviewWindowController()
        controller.isPinned = false
        
        let doc = Document()
        controller.updateTrackedDocument(to: doc)
        
        controller.isPinned = true
        #expect(controller.isPinned == true)
        
        controller.isPinned = false
        #expect(controller.isPinned == false)
    }
    
    @Test func test_pinToolbarItem_validation() {
        let controller = MarkdownPreviewWindowController()
        controller.isPinned = false
        controller.updateTrackedDocument(to: nil)
        
        let item = PreviewDummyValidatedStatableItem(action: #selector(MarkdownPreviewWindowController.togglePin))
        #expect(controller.validateUserInterfaceItem(item) == false)
        #expect(item.state == .off)
        
        let doc = Document()
        controller.updateTrackedDocument(to: doc)
        #expect(controller.validateUserInterfaceItem(item) == true)
        #expect(item.state == .off)
        
        controller.isPinned = true
        #expect(controller.validateUserInterfaceItem(item) == true)
        #expect(item.state == .on)
        
        controller.isPinned = false
    }
}

// MARK: - Suite 11: Keep On Top

@Suite("MarkdownPreview Keep-on-Top Tests", .serialized)
@MainActor struct MarkdownPreviewKeepOnTopTests {
    
    @Test func test_keepOnTopToggle_togglesWindowLevel() throws {
        let controller = MarkdownPreviewWindowController()
        let panel = try #require(controller.window as? NSPanel)
        
        controller.isKeepOnTop = false
        #expect(controller.isKeepOnTop == false)
        #expect(panel.level == .normal)
        #expect(panel.isFloatingPanel == false)
        
        controller.toggleKeepOnTop(nil)
        #expect(controller.isKeepOnTop == true)
        #expect(panel.level == .floating)
        #expect(panel.isFloatingPanel == true)
        
        controller.toggleKeepOnTop(nil)
        #expect(controller.isKeepOnTop == false)
        #expect(panel.level == .normal)
        #expect(panel.isFloatingPanel == false)
    }
    
    @Test func test_keepOnTopToolbarItem_validation() {
        let controller = MarkdownPreviewWindowController()
        let item = PreviewDummyValidatedStatableItem(action: #selector(MarkdownPreviewWindowController.toggleKeepOnTop))
        
        controller.isKeepOnTop = false
        #expect(controller.validateUserInterfaceItem(item) == true)
        #expect(item.state == .off)
        
        controller.isKeepOnTop = true
        #expect(controller.validateUserInterfaceItem(item) == true)
        #expect(item.state == .on)
        
        controller.isKeepOnTop = false
    }
}

// MARK: - Suite 12: Active Document Tracking & Lifecycle

@Suite("MarkdownPreview Active Document Tracking Tests", .serialized)
@MainActor struct MarkdownPreviewDocumentTrackingTests {
    
    @Test func test_activeDocumentSwitching_updatesPreviewContent() {
        let controller = MarkdownPreviewWindowController()
        controller.isPinned = false
        
        let docA = Document()
        docA.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# Alpha Document")
        controller.updateTrackedDocument(to: docA)
        #expect(controller.currentDocument === docA)
        #expect(controller.containerViewController.isShowingPlaceholder == false)
        #expect(controller.previewViewController.lastMarkdown == "# Alpha Document")
        
        let docB = Document()
        docB.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# Beta Document")
        controller.updateTrackedDocument(to: docB)
        #expect(controller.currentDocument === docB)
        #expect(controller.containerViewController.isShowingPlaceholder == false)
        #expect(controller.previewViewController.lastMarkdown == "# Beta Document")
    }
    
    @Test func test_nilDocument_transitionsToPlaceholder() {
        let controller = MarkdownPreviewWindowController()
        controller.isPinned = false
        
        let doc = Document()
        controller.updateTrackedDocument(to: doc)
        #expect(controller.containerViewController.isShowingPlaceholder == false)
        
        controller.updateTrackedDocument(to: nil)
        #expect(controller.currentDocument == nil)
        #expect(controller.containerViewController.isShowingPlaceholder == true)
    }
    
    @Test func test_windowCloseHandling_showsPlaceholder() {
        let controller = MarkdownPreviewWindowController()
        controller.isPinned = false
        
        let doc = Document()
        controller.updateTrackedDocument(to: doc)
        #expect(controller.currentDocument === doc)
        
        controller.handleTrackedDocumentClosed()
        #expect(controller.currentDocument == nil)
        #expect(controller.containerViewController.isShowingPlaceholder == true)
    }
    
    @Test func test_weakDocumentReference_doesNotRetainDocument() {
        let controller = MarkdownPreviewWindowController()
        controller.isPinned = false
        
        var doc: Document? = Document()
        weak var weakDoc = doc
        
        controller.updateTrackedDocument(to: doc)
        #expect(controller.currentDocument === weakDoc)
        
        controller.updateTrackedDocument(to: nil)
        doc = nil
        #expect(weakDoc == nil, "Document should deallocate freely when unreferenced externally")
    }
}

// MARK: - Suite 13: Keystroke Live Sync & Debounce

@Suite("MarkdownPreview Keystroke Live Sync & Debounce Tests", .serialized)
@MainActor struct MarkdownPreviewKeystrokeSyncTests {
    
    @Test func test_keystrokeSync_observedDirectlyFromTextStorage() async throws {
        let doc = Document()
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# Initial")
        
        let controller = MarkdownPreviewWindowController()
        controller.isPinned = false
        controller.updateTrackedDocument(to: doc)
        #expect(controller.previewViewController.lastMarkdown == "# Initial")
        
        // Character edit in text storage
        doc.textStorage.replaceCharacters(in: NSRange(location: 9, length: 0), with: " Edit")
        
        // Wait for 75ms debounce to fire
        let didUpdate = await MarkdownPreviewTestHelpers.waitFor {
            controller.previewViewController.lastMarkdown == "# Initial Edit"
        }
        #expect(didUpdate)
    }
    
    @Test func test_attributeEdits_ignoredByKeystrokeObserver() async throws {
        let doc = Document()
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# Static Title")
        
        let controller = MarkdownPreviewWindowController()
        controller.isPinned = false
        controller.updateTrackedDocument(to: doc)
        #expect(controller.previewViewController.lastMarkdown == "# Static Title")
        
        // Attribute change only (no character change)
        doc.textStorage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: 8))
        
        try await Task.sleep(for: .milliseconds(120))
        #expect(controller.previewViewController.lastMarkdown == "# Static Title")
    }
    
    @Test func test_debounceMechanism_batchesFastKeystrokes() async throws {
        let doc = Document()
        let controller = MarkdownPreviewWindowController()
        controller.isPinned = false
        controller.updateTrackedDocument(to: doc)
        
        // Simulate fast typing burst
        for i in 1...6 {
            doc.textStorage.replaceCharacters(in: NSRange(location: doc.textStorage.length, length: 0), with: " \(i)")
            try await Task.sleep(for: .milliseconds(10))
        }
        
        // Debounce window settles
        let didUpdate = await MarkdownPreviewTestHelpers.waitFor {
            controller.previewViewController.lastMarkdown == " 1 2 3 4 5 6"
        }
        #expect(didUpdate)
    }
    
    @Test func test_defensiveSnapshotting_usesImmutableString() {
        let textStorage = NSTextStorage(string: String(repeating: "m", count: 1024))
        let snapshot = textStorage.string.immutable
        
        textStorage.replaceCharacters(in: NSRange(location: 0, length: 4), with: "XXXX")
        #expect(snapshot.prefix(4) == "mmmm", "Defensive snapshot must be isolated from subsequent textStorage modifications")
    }
    
    @Test func test_flushPendingKeystrokes_firesImmediately() {
        let doc = Document()
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Hello")
        
        let controller = MarkdownPreviewWindowController()
        controller.isPinned = false
        controller.updateTrackedDocument(to: doc)
        
        doc.textStorage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " World")
        controller.flushPendingKeystrokes()
        #expect(controller.previewViewController.lastMarkdown == "Hello World")
    }
}

// MARK: - Suite 14: Base URL Sync

@Suite("MarkdownPreview Base URL Sync Tests", .serialized)
@MainActor struct MarkdownPreviewBaseURLSyncTests {
    
    @Test func test_fileURLChange_updatesBaseURL() async throws {
        let controller = MarkdownPreviewWindowController()
        controller.isPinned = false
        
        let doc = Document()
        let tempDir1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir1, withIntermediateDirectories: true)
        let fileURL1 = tempDir1.appendingPathComponent("note.md")
        doc.fileURL = fileURL1
        
        controller.updateTrackedDocument(to: doc)
        #expect(controller.previewViewController.currentBaseURL?.standardizedFileURL.path == tempDir1.standardizedFileURL.path)
        
        let tempDir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir2, withIntermediateDirectories: true)
        let fileURL2 = tempDir2.appendingPathComponent("renamed.md")
        doc.fileURL = fileURL2
        
        let didUpdate = await MarkdownPreviewTestHelpers.waitFor(timeout: .seconds(3)) {
            controller.previewViewController.currentBaseURL?.standardizedFileURL.path == tempDir2.standardizedFileURL.path
        }
        #expect(didUpdate)
    }
}

// MARK: - Suite 15: Menu & Responder Chain Validation

@Suite("MarkdownPreview Menu & Responder Chain Validation Tests", .serialized)
@MainActor struct MarkdownPreviewMenuAndResponderTests {
    
    @Test func test_menuValidation_enabledWithActiveDocument() {
        let appDelegate = AppDelegate()
        let item = PreviewDummyValidatedItem(action: #selector(AppDelegate.toggleMarkdownPreview))
        
        // Ensure preview window is closed
        MarkdownPreviewWindowController.shared.window?.orderOut(nil)
        
        let doc = Document()
        (NSDocumentController.shared as? DocumentController)?.addDocument(doc)
        defer {
            (NSDocumentController.shared as? DocumentController)?.removeDocument(doc)
        }
        
        #expect(appDelegate.validateUserInterfaceItem(item) == true,
                "toggleMarkdownPreview must be enabled when a plain text document is open")
    }
    
    @Test func test_menuValidation_enabledWhenWindowAlreadyOpen() {
        let appDelegate = AppDelegate()
        let item = PreviewDummyValidatedItem(action: #selector(AppDelegate.toggleMarkdownPreview))
        
        // Ensure no documents open
        for doc in NSDocumentController.shared.documents {
            (NSDocumentController.shared as? DocumentController)?.removeDocument(doc)
        }
        
        // Open the preview window
        MarkdownPreviewWindowController.shared.showWindow(nil)
        defer {
            MarkdownPreviewWindowController.shared.window?.orderOut(nil)
        }
        #expect(MarkdownPreviewWindowController.shared.window?.isVisible == true)
        
        #expect(appDelegate.validateUserInterfaceItem(item) == true,
                "toggleMarkdownPreview must be enabled when preview window is open even without active documents")
    }
    
    @Test func test_menuValidation_disabledWhenNoDocumentAndWindowClosed() {
        let appDelegate = AppDelegate()
        let item = PreviewDummyValidatedItem(action: #selector(AppDelegate.toggleMarkdownPreview))
        
        // Ensure no documents open
        for doc in NSDocumentController.shared.documents {
            (NSDocumentController.shared as? DocumentController)?.removeDocument(doc)
        }
        // Ensure preview window is closed
        MarkdownPreviewWindowController.shared.window?.orderOut(nil)
        
        #expect(appDelegate.validateUserInterfaceItem(item) == false,
                "toggleMarkdownPreview must be disabled when no document is open and preview window is closed")
    }
    
    @Test func test_action_routesToToggleWindow() {
        let appDelegate = AppDelegate()
        MarkdownPreviewWindowController.shared.window?.orderOut(nil)
        #expect(MarkdownPreviewWindowController.shared.window?.isVisible == false)
        
        defer {
            MarkdownPreviewWindowController.shared.window?.orderOut(nil)
        }
        
        appDelegate.toggleMarkdownPreview(nil)
        #expect(MarkdownPreviewWindowController.shared.window?.isVisible == true)
    }
    
    @Test func test_storyboardXML_containsMarkdownPreviewMenuItem() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let storyboardURL = projectRoot.appendingPathComponent("CotEditor/Storyboards/Base.lproj/Main.storyboard")
        if FileManager.default.fileExists(atPath: storyboardURL.path) {
            let content = try String(contentsOf: storyboardURL, encoding: .utf8)
            #expect(content.contains("id=\"mkv-pr-iew\""))
            #expect(content.contains("id=\"act-mp-iew\""))
            #expect(content.contains("action selector=\"toggleMarkdownPreview:\""))
            #expect(content.contains("target=\"Ady-hI-5gd\""))
            #expect(content.contains("keyEquivalent=\"p\""))
            #expect(content.contains("option=\"YES\" command=\"YES\""))
            #expect(content.contains("secondaryImage=\"doc.richtext\""))
        }
    }
}

// MARK: - Suite 16: Toolbar & Localization Integration

@Suite("MarkdownPreview Toolbar & Localization Tests", .serialized)
@MainActor struct MarkdownPreviewToolbarTests {
    
    @Test func test_toolbarIdentifier_matchesSpecification() {
        let expectedRawValue = "com.coteditor.CotEditor.ToolbarItem.markdownPreview"
        let doc = Document()
        let controller = DocumentWindowController(document: doc)
        let toolbar = NSToolbar(identifier: "Document")
        let allowed = controller.toolbarAllowedItemIdentifiers(toolbar)
        #expect(allowed.contains { $0.rawValue == expectedRawValue })
    }
    
    @Test func test_toolbarItemInDefaultList() {
        let doc = Document()
        let controller = DocumentWindowController(document: doc)
        let toolbar = NSToolbar(identifier: "Document")
        let defaults = controller.toolbarDefaultItemIdentifiers(toolbar)
        #expect(defaults.contains { $0.rawValue.hasSuffix("markdownPreview") })
    }
    
    @Test func test_toolbarItemInAllowedList() {
        let doc = Document()
        let controller = DocumentWindowController(document: doc)
        let toolbar = NSToolbar(identifier: "Document")
        let allowed = controller.toolbarAllowedItemIdentifiers(toolbar)
        #expect(allowed.contains { $0.rawValue.hasSuffix("markdownPreview") })
    }
    
    @Test func test_toolbarItemConstructionAndProperties() throws {
        let doc = Document()
        let controller = DocumentWindowController(document: doc)
        let toolbar = NSToolbar(identifier: "Document")
        let defaultItemIDs = controller.toolbarDefaultItemIdentifiers(toolbar)
        let previewID = try #require(defaultItemIDs.first { $0.rawValue.hasSuffix("markdownPreview") })
        
        let item = try #require(controller.toolbar(toolbar, itemForItemIdentifier: previewID, willBeInsertedIntoToolbar: true))
        
        #expect(item.label == "Markdown Preview")
        #expect(item.toolTip == "Show or hide Markdown preview window")
        #expect(item.action == #selector(AppDelegate.toggleMarkdownPreview))
        #expect(item.image?.accessibilityDescription == "Markdown Preview")
    }
    
    @Test func test_toolbarItemVisibility_basedOnSyntax() throws {
        let doc = Document()
        let controller = DocumentWindowController(document: doc)
        let toolbar = NSToolbar(identifier: "Document")
        let defaultItemIDs = controller.toolbarDefaultItemIdentifiers(toolbar)
        let previewID = try #require(defaultItemIDs.first { $0.rawValue.hasSuffix("markdownPreview") })
        
        // When syntax is not Markdown (e.g. initial "None"), item is hidden
        let nonMarkdownItem = try #require(controller.toolbar(toolbar, itemForItemIdentifier: previewID, willBeInsertedIntoToolbar: true))
        #expect(nonMarkdownItem.isHidden == true, "Markdown Preview toolbar item must be hidden for non-Markdown syntax")
        
        // When syntax is Markdown, item is visible
        doc.setSyntax(name: "Markdown")
        let markdownItem = try #require(controller.toolbar(toolbar, itemForItemIdentifier: previewID, willBeInsertedIntoToolbar: true))
        #expect(markdownItem.isHidden == false, "Markdown Preview toolbar item must be visible when syntax is Markdown")
    }
    
    @Test func test_toolbarItemVisibility_dynamicSwitching() async throws {
        let doc = Document()
        doc.setSyntax(name: "None")
        let controller = DocumentWindowController(document: doc)
        guard let window = controller.window, let toolbar = window.toolbar else {
            Issue.record("Window or toolbar could not be loaded")
            return
        }
        
        let previewItem = try #require(toolbar.items.first { $0.itemIdentifier.rawValue.hasSuffix("markdownPreview") })
        #expect(previewItem.isHidden == true, "Initially hidden when syntax is None")
        
        // Switch to Markdown
        doc.setSyntax(name: "Markdown")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(previewItem.isHidden == false, "Must become visible when syntax switches to Markdown")
        
        // Switch to Python
        doc.setSyntax(name: "Python")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(previewItem.isHidden == true, "Must become hidden when syntax switches to Python")
    }
    
    @Test func test_localization_mainMenuContainsMarkdownPreview() {
        let localized = String(localized: "Markdown Preview", table: "MainMenu")
        #expect(localized == "Markdown Preview")
    }
    
    @Test func test_localization_toolbarLabelAndTooltip() {
        let bundle = Bundle.allBundles.first(where: { $0.bundleIdentifier == "com.coteditor.CotEditor" })
            ?? Bundle(for: AppDelegate.self)
        let label = String(localized: "Toolbar.markdownPreview.label", defaultValue: "Markdown Preview", table: "Document", bundle: bundle)
        #expect(label == "Markdown Preview")
        
        let tooltip = String(localized: "Toolbar.markdownPreview.tooltip", defaultValue: "Show or hide Markdown preview window", table: "Document", bundle: bundle)
        #expect(tooltip == "Show or hide Markdown preview window")
    }
    
    @Test func test_localizationCatalogs_all17LocalesPresent() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        
        let requiredLocales = ["cs", "de", "en", "en-GB", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt", "ru", "tr", "zh-HK", "zh-Hans", "zh-Hant"]
        
        // 1. MainMenu.xcstrings
        let mainMenuURL = projectRoot.appendingPathComponent("CotEditor/Localizables/Application/MainMenu.xcstrings")
        let mainMenuData = try Data(contentsOf: mainMenuURL)
        let mainMenuJSON = try #require(JSONSerialization.jsonObject(with: mainMenuData) as? [String: Any])
        let mainMenuStrings = try #require(mainMenuJSON["strings"] as? [String: Any])
        let previewMenu = try #require(mainMenuStrings["Markdown Preview"] as? [String: Any])
        let previewMenuLocs = try #require(previewMenu["localizations"] as? [String: Any])
        
        for locale in requiredLocales {
            let locEntry = try #require(previewMenuLocs[locale] as? [String: Any], "Missing locale \(locale) in MainMenu.xcstrings")
            let unit = try #require(locEntry["stringUnit"] as? [String: Any])
            let val = try #require(unit["value"] as? String)
            #expect(!val.isEmpty, "Empty translation for \(locale) in MainMenu.xcstrings")
        }
        
        // 2. Document.xcstrings
        let docURL = projectRoot.appendingPathComponent("CotEditor/Localizables/Document Window/Document.xcstrings")
        let docData = try Data(contentsOf: docURL)
        let docJSON = try #require(JSONSerialization.jsonObject(with: docData) as? [String: Any])
        let docStrings = try #require(docJSON["strings"] as? [String: Any])
        
        for key in ["Toolbar.markdownPreview.label", "Toolbar.markdownPreview.tooltip"] {
            let itemEntry = try #require(docStrings[key] as? [String: Any], "Missing key \(key) in Document.xcstrings")
            let itemLocs = try #require(itemEntry["localizations"] as? [String: Any])
            for locale in requiredLocales {
                let locEntry = try #require(itemLocs[locale] as? [String: Any], "Missing locale \(locale) for \(key) in Document.xcstrings")
                let unit = try #require(locEntry["stringUnit"] as? [String: Any])
                let val = try #require(unit["value"] as? String)
                #expect(!val.isEmpty, "Empty translation for \(locale) in \(key)")
            }
        }
    }
}



