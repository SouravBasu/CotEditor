//
//  MarkdownPreviewChallengerTests.swift
//  Tests
//
//  Empirical adversarial challenge suite for Milestone 1.
//

import AppKit
import Foundation
import Testing
import WebKit
import JavaScriptCore
@testable import CotEditor

// MARK: - Test Helpers

@MainActor
private final class DummyValidatedItem: NSValidatedUserInterfaceItem {
    let action: Selector?
    let tag: Int
    
    init(action: Selector?, tag: Int = 0) {
        self.action = action
        self.tag = tag
    }
}

// MARK: - Milestone 1 Challenger Test Suite

@Suite("Milestone 1 Challenger Empirical Suite")
@MainActor struct MarkdownPreviewChallengerTests {
    
    @MainActor
    private static func waitFor(timeout: Duration = .seconds(3), interval: Duration = .milliseconds(20), _ condition: @escaping () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: interval)
        }
        return condition()
    }
    
    private static func loadBundledMarkedContext() throws -> JSContext {
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
    
    // MARK: - 1. Extreme Markdown Inputs & Edge Cases
    
    @Test func test_extremeDeeplyNestedLists_rendersWithoutCrashing() throws {
        let jsContext = try Self.loadBundledMarkedContext()
        
        // Generate 300 levels of nested lists
        var nestedMarkdown = ""
        for i in 0..<300 {
            nestedMarkdown += String(repeating: "  ", count: i) + "- Item \(i)\n"
        }
        
        let start = ContinuousClock.now
        let result = jsContext.evaluateScript("marked.parse(\(String(reflecting: nestedMarkdown)))")?.toString()
        let elapsed = ContinuousClock.now - start
        
        #expect(result != nil)
        #expect(result?.contains("<li>Item 299</li>") == true)
        #expect(elapsed < .seconds(2), "Deeply nested lists (300 levels) must parse within 2 seconds")
    }
    
    @Test func test_giantTableRendering_performance() throws {
        let jsContext = try Self.loadBundledMarkedContext()
        
        // Generate a 2,000-row table
        var table = "| Col 1 | Col 2 | Col 3 | Col 4 | Col 5 |\n|---|---|---|---|---|\n"
        for i in 0..<2000 {
            table += "| R\(i)C1 | R\(i)C2 | R\(i)C3 | R\(i)C4 | R\(i)C5 |\n"
        }
        
        let start = ContinuousClock.now
        let result = jsContext.evaluateScript("marked.parse(\(String(reflecting: table)))")?.toString()
        let elapsed = ContinuousClock.now - start
        
        #expect(result != nil)
        #expect(result?.contains("<td>R1999C5</td>") == true)
        #expect(elapsed < .seconds(1), "2,000-row table must parse in under 1 second")
    }
    
    @Test func test_unicodeAndEmojiResilience() throws {
        let jsContext = try Self.loadBundledMarkedContext()
        
        let unicodePayload = """
        # Emoji and Complex Unicode 🌍🚀
        
        - ZWJ Family: 👨‍👩‍👧‍👦
        - Flags: 🏳️‍🌈 🇯🇵 🇺🇸
        - RTL Hebrew: שָׁלוֹם עוֹלָם
        - RTL Arabic: مَرحَبًا بِالعَالَم
        - CJK Japanese: こんにちは世界、青空文庫
        - CJK Chinese: 简体中文与繁體中文
        - CJK Korean: 안녕하세요 세계
        - Math & Diacritics: ∀x ∈ ℝ, ∑_{i=1}^n x_i ≈ ∫_0^∞ f(t)dt ≠ 0 ≤ 1, c⃗ = a⃗ × b⃗
        - Control Characters: \u{200B}\u{200C}\u{200D}\u{FEFF}
        """
        
        let result = jsContext.evaluateScript("marked.parse(\(String(reflecting: unicodePayload)))")?.toString()
        #expect(result != nil)
        #expect(result?.contains("👨‍👩‍👧‍👦") == true)
        #expect(result?.contains("שָׁלוֹם") == true)
        #expect(result?.contains("مَرحَبًا") == true)
        #expect(result?.contains("こんにちは世界") == true)
        #expect(result?.contains("∀x ∈ ℝ") == true)
    }
    
    @Test func test_maliciousScriptAndEventHandlers_behavior() throws {
        let jsContext = try Self.loadBundledMarkedContext()
        
        // Test script injection: marked passes raw HTML through without sanitization
        let scriptInput = "<script>alert('xss')</script>"
        let scriptParsed = jsContext.evaluateScript("marked.parse(\(String(reflecting: scriptInput)))")?.toString()
        #expect(scriptParsed?.contains("<script>alert('xss')</script>") == true, "Marked preserves raw script tags")
        
        // Test onerror handler injection: passed raw
        let imgInput = "<img src=x onerror=alert(1)>"
        let imgParsed = jsContext.evaluateScript("marked.parse(\(String(reflecting: imgInput)))")?.toString()
        #expect(imgParsed?.contains("onerror=alert(1)") == true, "Marked passes raw event handler attributes")
        
        // Test style override: passed raw
        let styleInput = "<style>body { display: none !important; }</style>"
        let styleParsed = jsContext.evaluateScript("marked.parse(\(String(reflecting: styleInput)))")?.toString()
        #expect(styleParsed?.contains("<style>body { display: none !important; }</style>") == true, "Marked passes raw style tags")
    }
    
    @Test func test_nonASCIIHeadingSlugify_preservesUnicodeIDs() throws {
        let jsContext = try Self.loadBundledMarkedContext()
        
        let md = """
        # はじめに
        # インストール
        # Über uns
        """
        let result = jsContext.evaluateScript("marked.parse(\(String(reflecting: md)))")?.toString() ?? ""
        
        #expect(result.contains("<h1 id=\"はじめに\">はじめに</h1>"), "Japanese heading gets preserved Unicode ID")
        #expect(result.contains("<h1 id=\"インストール\">インストール</h1>"), "Second Japanese heading gets unique preserved ID")
        #expect(result.contains("<h1 id=\"über-uns\">Über uns</h1>"), "Umlauts are preserved in lowercased form")
    }
    
    // MARK: - 2. Zoom Boundary Conditions
    
    @Test func test_zoomBigger_repeatedInvocations_clampedAt3() {
        let vc = MarkdownPreviewViewController()
        _ = vc.view
        #expect(vc.webView.pageZoom == 1.0)
        
        // Zoom in 50 times
        for _ in 0..<50 {
            vc.biggerFont(nil)
        }
        
        #expect(vc.webView.pageZoom == 3.0, "Page zoom must clamp strictly at 3.0")
        
        // Verify UI validation at maximum zoom
        let biggerItem = DummyValidatedItem(action: #selector(MarkdownPreviewViewController.biggerFont))
        let smallerItem = DummyValidatedItem(action: #selector(MarkdownPreviewViewController.smallerFont))
        let resetItem = DummyValidatedItem(action: #selector(MarkdownPreviewViewController.resetFont))
        
        #expect(vc.validateUserInterfaceItem(biggerItem) == false, "biggerFont must be disabled at maximum zoom (3.0)")
        #expect(vc.validateUserInterfaceItem(smallerItem) == true, "smallerFont must remain enabled at maximum zoom")
        #expect(vc.validateUserInterfaceItem(resetItem) == true, "resetFont must remain enabled when zoomed in")
    }
    
    @Test func test_zoomSmaller_repeatedInvocations_clampedAtHalf() {
        let vc = MarkdownPreviewViewController()
        _ = vc.view
        #expect(vc.webView.pageZoom == 1.0)
        
        // Zoom out 50 times
        for _ in 0..<50 {
            vc.smallerFont(nil)
        }
        
        #expect(vc.webView.pageZoom == 0.5, "Page zoom must clamp strictly at 0.5")
        
        // Verify UI validation at minimum zoom
        let biggerItem = DummyValidatedItem(action: #selector(MarkdownPreviewViewController.biggerFont))
        let smallerItem = DummyValidatedItem(action: #selector(MarkdownPreviewViewController.smallerFont))
        let resetItem = DummyValidatedItem(action: #selector(MarkdownPreviewViewController.resetFont))
        
        #expect(vc.validateUserInterfaceItem(smallerItem) == false, "smallerFont must be disabled at minimum zoom (0.5)")
        #expect(vc.validateUserInterfaceItem(biggerItem) == true, "biggerFont must remain enabled at minimum zoom")
        #expect(vc.validateUserInterfaceItem(resetItem) == true, "resetFont must remain enabled when zoomed out")
    }
    
    @Test func test_zoomReset_restores1Point0AndValidations() {
        let vc = MarkdownPreviewViewController()
        _ = vc.view
        
        let resetItem = DummyValidatedItem(action: #selector(MarkdownPreviewViewController.resetFont))
        
        // Default state (1.0) -> reset is disabled
        #expect(vc.validateUserInterfaceItem(resetItem) == false, "resetFont must be disabled when already at 1.0")
        
        // Change zoom to 1.5
        for _ in 0..<5 {
            vc.biggerFont(nil)
        }
        #expect(vc.webView.pageZoom == 1.5)
        #expect(vc.validateUserInterfaceItem(resetItem) == true)
        
        // Reset zoom
        vc.resetFont(nil)
        #expect(vc.webView.pageZoom == 1.0)
        #expect(vc.validateUserInterfaceItem(resetItem) == false, "resetFont must become disabled after reset")
    }
    
    @Test func test_zoomStepPrecision_noFloatingPointDrift() {
        let vc = MarkdownPreviewViewController()
        _ = vc.view
        
        // Reset to minimum (0.5)
        for _ in 0..<50 { vc.smallerFont(nil) }
        #expect(vc.webView.pageZoom == 0.5)
        
        // Step up from 0.5 to 3.0 (25 steps of 0.1)
        var expectedZoom: CGFloat = 0.5
        for _ in 0..<25 {
            vc.biggerFont(nil)
            expectedZoom += 0.1
            expectedZoom = round(expectedZoom * 10) / 10
            #expect(abs(vc.webView.pageZoom - expectedZoom) < 0.0001, "Zoom at step \(expectedZoom) must not suffer from floating point drift")
        }
        #expect(vc.webView.pageZoom == 3.0)
        
        // Step down from 3.0 to 0.5 (25 steps of 0.1)
        for _ in 0..<25 {
            vc.smallerFont(nil)
            expectedZoom -= 0.1
            expectedZoom = round(expectedZoom * 10) / 10
            #expect(abs(vc.webView.pageZoom - expectedZoom) < 0.0001, "Zoom at step \(expectedZoom) must not suffer from floating point drift")
        }
        #expect(vc.webView.pageZoom == 0.5)
    }
    
    // MARK: - 3. Navigation Decisions
    
    @Test func test_isAnchorNavigation_sameDocumentAnchors() {
        let vc = MarkdownPreviewViewController()
        _ = vc.view
        
        // 1. Relative fragment URL (always true)
        let relAnchor = URL(string: "#features")!
        #expect(vc.isAnchorNavigation(relAnchor, in: vc.webView) == true)
        
        // 2. Relative fragment URL with slash path
        let slashAnchor = URL(string: "/#features")!
        #expect(vc.isAnchorNavigation(slashAnchor, in: vc.webView) == true)
        
        // 3. Document base directory URL matching anchor with trailing slash
        let baseDir = URL(fileURLWithPath: "/Users/tester/Documents")
        vc.setBaseURL(baseDir)
        let anchorWithTrailingSlash = URL(string: "file:///Users/tester/Documents/#features")!
        #expect(vc.isAnchorNavigation(anchorWithTrailingSlash, in: vc.webView) == true, "Anchor with trailing slash must match base directory URL")
    }
    
    @Test func test_isAnchorNavigation_externalOrDifferentFile_isFalse() {
        let vc = MarkdownPreviewViewController()
        _ = vc.view
        
        let baseURL = URL(fileURLWithPath: "/Users/tester/Documents")
        vc.setBaseURL(baseURL)
        
        // 1. External HTTP URL with fragment
        let httpAnchor = URL(string: "http://example.com/#section")!
        #expect(vc.isAnchorNavigation(httpAnchor, in: vc.webView) == false, "HTTP anchor must not be treated as intra-document")
        
        // 2. External HTTPS URL with fragment
        let httpsAnchor = URL(string: "https://coteditor.com/#features")!
        #expect(vc.isAnchorNavigation(httpsAnchor, in: vc.webView) == false, "HTTPS anchor must not be treated as intra-document")
        
        // 3. Mailto URL
        let mailto = URL(string: "mailto:support@coteditor.com")!
        #expect(vc.isAnchorNavigation(mailto, in: vc.webView) == false)
        
        // 4. Different local file with fragment
        let otherFileAnchor = URL(string: "file:///Users/tester/Documents/other.md#intro")!
        #expect(vc.isAnchorNavigation(otherFileAnchor, in: vc.webView) == false, "Anchor to a different file must not be treated as same-document anchor")
        
        // 5. File URL without fragment
        let fileNoFragment = URL(string: "file:///Users/tester/Documents/readme.md")!
        #expect(vc.isAnchorNavigation(fileNoFragment, in: vc.webView) == false)
    }
    
    @Test func test_uiDelegate_targetBlankIntercepted() {
        let vc = MarkdownPreviewViewController()
        _ = vc.view
        
        final class SafeFakeAction: NSObject {
            @objc let request = URLRequest(url: URL(string: "about:blank")!)
        }
        final class SafeFakeFeatures: NSObject {}
        
        let config = WKWebViewConfiguration()
        let fakeAction: WKNavigationAction = unsafeBitCast(SafeFakeAction(), to: WKNavigationAction.self)
        let fakeFeatures: WKWindowFeatures = unsafeBitCast(SafeFakeFeatures(), to: WKWindowFeatures.self)
        let action = vc.webView(
            vc.webView,
            createWebViewWith: config,
            for: fakeAction,
            windowFeatures: fakeFeatures
        )
        #expect(action == nil, "createWebViewWith must return nil to suppress secondary webview creation")
    }
    
    @Test func test_schemePermitting_rejectsDangerousSchemes() {
        let vc = MarkdownPreviewViewController()
        _ = vc.view
        
        let dangerousURLs = [
            URL(string: "javascript:alert(1)")!,
            URL(string: "data:text/html,<h1>bad</h1>")!,
            URL(string: "applescript:do%20something")!,
            URL(string: "terminal:run")!,
            URL(string: "coteditor:open")!
        ]
        
        for url in dangerousURLs {
            #expect(vc.isAnchorNavigation(url, in: vc.webView) == false)
        }
    }
    
    // MARK: - 4. Process Recovery
    
    @Test func test_webContentProcessDidTerminate_reloadsTemplate() {
        let vc = MarkdownPreviewViewController()
        _ = vc.view
        
        let docURL = URL(fileURLWithPath: "/tmp/test.md")
        vc.setBaseURL(docURL)
        
        // Simulate WebKit WebContent process crash
        vc.webViewWebContentProcessDidTerminate(vc.webView)
        
        #expect(vc.isReady == false, "isReady must be reset to false after web content process termination")
        #expect(vc.currentBaseURL == docURL, "currentBaseURL must be preserved across termination reload")
    }
}
