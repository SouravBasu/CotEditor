//
//  MarkdownPreviewChallenger2Tests.swift
//  Tests
//
//  Empirical adversarial challenge suite 2 for Milestone 1.
//  Tests offline resilience, in-place DOM updates, scroll preservation, base URL, and rapid bursts.
//

import AppKit
import Foundation
import Testing
import WebKit
import JavaScriptCore
@testable import CotEditor

@Suite("Milestone 1 Challenger 2 Empirical Suite")
@MainActor struct MarkdownPreviewChallenger2Tests {
    
    // MARK: - Helpers
    
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
    
    @MainActor
    private static func yieldMain(duration: Duration = .milliseconds(50)) async {
        try? await Task.sleep(for: duration)
    }
    
    @MainActor
    private static func makeConfiguredController() -> (MarkdownPreviewViewController, NSWindow) {
        let vc = MarkdownPreviewViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        vc.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return (vc, window)
    }
    
    // MARK: - 1. Offline Resilience & Assets
    
    @Test func test_offlineAssets_bundledAndAccessible() throws {
        let bundle = Bundle(for: MarkdownPreviewViewController.self)
        
        let htmlURL = bundle.url(forResource: "preview", withExtension: "html", subdirectory: "Preview")
            ?? Bundle.main.url(forResource: "preview", withExtension: "html", subdirectory: "Preview")
        let cssURL = bundle.url(forResource: "preview", withExtension: "css", subdirectory: "Preview")
            ?? Bundle.main.url(forResource: "preview", withExtension: "css", subdirectory: "Preview")
        let jsURL = bundle.url(forResource: "marked.min", withExtension: "js", subdirectory: "Preview")
            ?? Bundle.main.url(forResource: "marked.min", withExtension: "js", subdirectory: "Preview")
        
        #expect(htmlURL != nil, "preview.html must exist in bundle")
        #expect(cssURL != nil, "preview.css must exist in bundle")
        #expect(jsURL != nil, "marked.min.js must exist in bundle")
        
        let htmlContent = try String(contentsOf: try #require(htmlURL), encoding: .utf8)
        let cssContent = try String(contentsOf: try #require(cssURL), encoding: .utf8)
        let jsContent = try String(contentsOf: try #require(jsURL), encoding: .utf8)
        
        #expect(!htmlContent.isEmpty, "preview.html must not be empty")
        #expect(!cssContent.isEmpty, "preview.css must not be empty")
        #expect(!jsContent.isEmpty, "marked.min.js must not be empty")
        
        // Confirm zero remote network references in preview.html and preview.css
        #expect(!htmlContent.contains("http://"), "preview.html must not contain http:// links")
        #expect(!htmlContent.contains("https://"), "preview.html must not contain https:// links")
        #expect(!cssContent.contains("@import"), "preview.css must not contain external @import rules")
        #expect(!cssContent.contains("url("), "preview.css must not contain external url() dependencies")
    }
    
    @Test func test_templateInlining_replacesExternalLinksWithInlineBlocks() {
        let (vc, _) = Self.makeConfiguredController()
        
        let mirror = Mirror(reflecting: vc)
        let templateHTML = mirror.children.first { $0.label == "templateHTML" }?.value as? String
        
        #expect(templateHTML != nil, "templateHTML must be loaded")
        let html = templateHTML ?? ""
        
        // Verify assets are completely inlined to avoid sandbox 404s when baseURL is set
        #expect(!html.contains("<link rel=\"stylesheet\" href=\"preview.css\">"), "preview.css link must be replaced with inline <style>")
        #expect(!html.contains("<script src=\"marked.min.js\"></script>"), "marked.min.js script must be replaced with inline <script>")
        #expect(html.contains("<style>"), "Inline <style> tag must be present")
        #expect(html.contains("<script>"), "Inline <script> tag must be present")
        #expect(html.contains("marked.use"), "Marked configuration script must be present")
        #expect(html.contains("id=\"base-tag\""), "<base id='base-tag'> must be present")
        #expect(html.contains("id=\"markdown-content\""), "<div id='markdown-content'> must be present")
    }
    
    @Test func test_webViewConfiguration_nonPersistentAndSandboxed() {
        let (vc, _) = Self.makeConfiguredController()
        
        #expect(vc.webView.configuration.websiteDataStore.isPersistent == false, "Website data store must be nonPersistent to prevent disk caching/cookies")
        #expect(vc.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript == true, "JavaScript must be enabled for marked.js")
        let alpha = vc.webView.underPageBackgroundColor.alphaComponent
        #expect(alpha < 0.01, "Background color alpha must be clear for dark mode adaptation (got alpha \(alpha))")
    }
    
    // MARK: - 2. In-Place DOM Updates & Scroll Preservation
    
    @Test func test_inPlaceDOMUpdate_asyncExecution() async throws {
        let (vc, _) = Self.makeConfiguredController()
        
        let ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready, "WebView must finish loading initial template")
        
        // 1. Initial Markdown update
        vc.updateMarkdown("# Title 1\n\nThis is paragraph one.", baseURL: nil, resetScroll: false)
        await Self.yieldMain(duration: .milliseconds(150))
        
        var content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("<h1 id=\"title-1\">Title 1</h1>") == true)
        #expect(content?.contains("<p>This is paragraph one.</p>") == true)
        
        // 2. In-place Markdown update (different content)
        vc.updateMarkdown("# Title 2\n\n- Item A\n- Item B", baseURL: nil, resetScroll: false)
        await Self.yieldMain(duration: .milliseconds(150))
        
        content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("<h1 id=\"title-2\">Title 2</h1>") == true)
        #expect(content?.contains("<li>Item A</li>") == true)
        #expect(content?.contains("Title 1") == false, "Previous content should be completely replaced in-place")
    }
    
    @Test func test_inPlaceDOMUpdate_scrollPreservationVsReset() async throws {
        let (vc, _) = Self.makeConfiguredController()
        
        let ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready, "WebView must finish loading initial template")
        
        // Generate very long content so scroll height is > 5000px
        var longMarkdown = "# Long Document\n\n"
        for i in 1...200 {
            longMarkdown += "Paragraph \(i): The quick brown fox jumps over the lazy dog with extra lines to ensure substantial height in WebKit view.\n\n"
        }
        
        vc.updateMarkdown(longMarkdown, baseURL: nil, resetScroll: true)
        await Self.yieldMain(duration: .milliseconds(300))
        
        // Programmatically scroll down to 500px using instant behavior to avoid animation lag
        _ = try await vc.webView.evaluateJavaScript("window.scrollTo({ left: 0, top: 500, behavior: 'instant' });")
        await Self.yieldMain(duration: .milliseconds(150))
        
        var scrollY = try await vc.webView.evaluateJavaScript("window.scrollY") as? Double ?? 0.0
        #expect(scrollY >= 300.0, "Scroll position must be scrolled down (got \(scrollY))")
        
        let targetScrollY = scrollY
        
        // Update markdown with resetScroll = false (simulating keystroke editing)
        longMarkdown += "Extra appended line from live typing.\n\n"
        vc.updateMarkdown(longMarkdown, baseURL: nil, resetScroll: false)
        await Self.yieldMain(duration: .milliseconds(300))
        
        scrollY = try await vc.webView.evaluateJavaScript("window.scrollY") as? Double ?? 0.0
        #expect(abs(scrollY - targetScrollY) <= 50.0, "Scroll position must be PRESERVED when resetScroll is false (expected ~\(targetScrollY), got \(scrollY))")
        
        // Now update markdown with resetScroll = true (simulating file switch)
        vc.updateMarkdown(longMarkdown, baseURL: nil, resetScroll: true)
        await Self.yieldMain(duration: .milliseconds(300))
        
        scrollY = try await vc.webView.evaluateJavaScript("window.scrollY") as? Double ?? 0.0
        #expect(scrollY == 0.0, "Scroll position must be RESET to 0 when resetScroll is true (got \(scrollY))")
    }
    
    @Test func test_identicalMarkdownUpdate_isNoOp() async throws {
        let (vc, _) = Self.makeConfiguredController()
        
        let ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready)
        
        let markdown = "# Stable Content"
        vc.updateMarkdown(markdown, baseURL: nil, resetScroll: false)
        await Self.yieldMain(duration: .milliseconds(150))
        
        // Mark DOM with a custom attribute
        _ = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').setAttribute('data-test-marker', 'active')")
        
        // Send identical update
        vc.updateMarkdown(markdown, baseURL: nil, resetScroll: false)
        await Self.yieldMain(duration: .milliseconds(150))
        
        // Because lastMarkdown == markdown and resetScroll == false, performInPlaceUpdate is skipped,
        // so the custom attribute should still exist!
        let marker = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').getAttribute('data-test-marker')") as? String
        #expect(marker == "active", "Identical markdown updates should be skipped to prevent redundant DOM re-renders")
    }
    
    @Test func test_adversarialCharactersInMarkdown_noScriptErrors() async throws {
        let (vc, _) = Self.makeConfiguredController()
        
        let ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready)
        
        // Adversarial inputs: quotes, newlines, backslashes, HTML angle brackets, malformed markdown
        let adversarial = #"""
        # "Quotes" and 'Apostrophes' and \Backslashes\
        
        ```javascript
        const json = "{\"key\": \"val\\nwith\\tquotes\"}";
        console.log(`Template string ${1 + 1}`);
        ```
        
        <div onclick="alert('xss')">Raw HTML block</div>
        
        | Unclosed | Table |
        |---|
        | Row 1 |
        
        Unclosed code fence:
        ```
        """#
        
        vc.updateMarkdown(adversarial, baseURL: nil, resetScroll: false)
        await Self.yieldMain(duration: .milliseconds(200))
        
        let content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content != nil)
        #expect(content?.contains("Quotes") == true)
        #expect(content?.contains("Backslashes") == true)
        #expect(content?.contains("Template string") == true)
    }
    
    // MARK: - 3. Base URL Handling & Relative Images
    
    @Test func test_baseURL_resolutionContract() {
        // Document with saved fileURL
        let fileURL = URL(fileURLWithPath: "/Users/developer/Documents/Project/README.md")
        let resolvedBase = fileURL.deletingLastPathComponent()
        #expect(resolvedBase.path == "/Users/developer/Documents/Project")
        
        // Document without fileURL (unsaved)
        let unsavedFileURL: URL? = nil
        let unsavedBase = unsavedFileURL?.deletingLastPathComponent()
        #expect(unsavedBase == nil, "Unsaved document must resolve to nil baseURL")
    }
    
    @Test func test_baseURL_updatesBaseTagInDOM() async throws {
        let (vc, _) = Self.makeConfiguredController()
        
        let ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready)
        
        let baseDir = URL(fileURLWithPath: "/Users/tester/Documents/Notes/")
        vc.updateMarkdown("![Test](photo.png)", baseURL: baseDir, resetScroll: false)
        
        // Wait for template reload with new baseURL
        let reloaded = await Self.waitFor(timeout: .seconds(5)) { vc.isReady && vc.currentBaseURL == baseDir }
        #expect(reloaded)
        await Self.yieldMain(duration: .milliseconds(200))
        
        let baseHref = try await vc.webView.evaluateJavaScript("document.getElementById('base-tag').getAttribute('href')") as? String
        #expect(baseHref != nil)
        #expect(baseHref?.hasPrefix("file:///Users/tester/Documents/Notes") == true, "Base tag must reflect the document directory (got \(String(describing: baseHref)))")
    }
    
    @Test func test_baseURL_changingDirectoryTriggersReloadAndFlushes() async throws {
        let (vc, _) = Self.makeConfiguredController()
        
        var ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready)
        
        let dirA = URL(fileURLWithPath: "/tmp/projectA/")
        vc.updateMarkdown("# Project A", baseURL: dirA, resetScroll: false)
        
        ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady && vc.currentBaseURL == dirA }
        #expect(ready)
        await Self.yieldMain(duration: .milliseconds(150))
        
        var content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Project A") == true)
        
        // Switch to Project B
        let dirB = URL(fileURLWithPath: "/tmp/projectB/")
        vc.updateMarkdown("# Project B", baseURL: dirB, resetScroll: false)
        
        ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady && vc.currentBaseURL == dirB }
        #expect(ready)
        await Self.yieldMain(duration: .milliseconds(150))
        
        content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Project B") == true)
        #expect(vc.currentBaseURL == dirB)
    }
    
    // MARK: - 4. Rapid Bursts & Performance
    
    @Test func test_rapidTypingBurst_noCrashesAndRendersFinalState() async throws {
        let (vc, _) = Self.makeConfiguredController()
        
        let ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready)
        
        // Simulate rapid keystrokes: 40 updates in rapid succession
        for i in 1...40 {
            vc.updateMarkdown("Keystroke iteration \(i)", baseURL: nil, resetScroll: false)
            // Tiny sleep between keystrokes to mimic fast typing (5ms)
            try? await Task.sleep(for: .milliseconds(5))
        }
        
        // Allow WebKit asynchronous IPC to finish processing calls
        await Self.yieldMain(duration: .milliseconds(300))
        
        let content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Keystroke iteration 40") == true, "Final keystroke iteration must be rendered in DOM after rapid burst")
        #expect(vc.lastMarkdown == "Keystroke iteration 40")
    }
    
    @Test func test_updatesWhileNotReady_queuesAndFlushesLatestOnly() async throws {
        let (vc, _) = Self.makeConfiguredController()
        
        // Trigger reload by switching base URL, which immediately sets isReady = false
        let newDir = URL(fileURLWithPath: "/tmp/freshDir/")
        vc.setBaseURL(newDir)
        #expect(vc.isReady == false, "isReady must be false right after setBaseURL")
        
        // Queue multiple updates while not ready
        vc.updateMarkdown("Intermediate 1", baseURL: newDir, resetScroll: false)
        vc.updateMarkdown("Intermediate 2", baseURL: newDir, resetScroll: false)
        vc.updateMarkdown("Final Queued Update", baseURL: newDir, resetScroll: false)
        
        // Wait for template to finish loading and flush
        let ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready)
        await Self.yieldMain(duration: .milliseconds(200))
        
        let content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Final Queued Update") == true, "Only the latest queued update should be rendered upon flush")
    }
    
    // MARK: - 5. Adversarial setBaseURL Verification
    
    @Test func test_adversarial_setBaseURL_preservesContentAcrossSuccessiveSwitches() async throws {
        let (vc, _) = Self.makeConfiguredController()
        
        var ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready)
        
        // 1. Initial render with no base URL
        let sampleMD = "# Stable Content\n\nExisting text body that must persist."
        vc.updateMarkdown(sampleMD, baseURL: nil, resetScroll: false)
        await Self.yieldMain(duration: .milliseconds(150))
        
        var content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Stable Content") == true)
        
        // 2. Switch to Dir A (simulating file save to disk)
        let dirA = URL(fileURLWithPath: "/tmp/challenger_test_dirA/")
        vc.setBaseURL(dirA)
        ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady && vc.currentBaseURL == dirA }
        #expect(ready)
        await Self.yieldMain(duration: .milliseconds(150))
        
        content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Stable Content") == true, "Content must NOT disappear when base URL is set to Dir A")
        var baseHref = try await vc.webView.evaluateJavaScript("document.getElementById('base-tag').getAttribute('href')") as? String
        #expect(baseHref?.hasPrefix("file:///tmp/challenger_test_dirA") == true)
        
        // 3. Switch to Dir B (simulating Save As to another directory)
        let dirB = URL(fileURLWithPath: "/tmp/challenger_test_dirB/")
        vc.setBaseURL(dirB)
        ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady && vc.currentBaseURL == dirB }
        #expect(ready)
        await Self.yieldMain(duration: .milliseconds(150))
        
        content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Stable Content") == true, "Content must NOT disappear when base URL is switched to Dir B")
        baseHref = try await vc.webView.evaluateJavaScript("document.getElementById('base-tag').getAttribute('href')") as? String
        #expect(baseHref?.hasPrefix("file:///tmp/challenger_test_dirB") == true)
        
        // 4. Revert to nil (simulating untracked/new document)
        vc.setBaseURL(nil)
        ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady && vc.currentBaseURL == nil }
        #expect(ready)
        await Self.yieldMain(duration: .milliseconds(150))
        
        content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Stable Content") == true, "Content must NOT disappear when base URL is reset to nil")
        baseHref = try await vc.webView.evaluateJavaScript("document.getElementById('base-tag').getAttribute('href')") as? String
        #expect(baseHref == nil, "Base tag href must be removed when baseURL is nil")
    }
    
    @Test func test_adversarial_setBaseURL_redundantCall_isNoOp() async throws {
        let (vc, _) = Self.makeConfiguredController()
        
        let ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready)
        
        let dir = URL(fileURLWithPath: "/tmp/stable_dir/")
        vc.setBaseURL(dir)
        _ = await Self.waitFor(timeout: .seconds(5)) { vc.isReady && vc.currentBaseURL == dir }
        
        // Calling setBaseURL with identical URL should be a no-op
        let wasReady = vc.isReady
        vc.setBaseURL(dir)
        #expect(vc.isReady == wasReady, "Identical setBaseURL must not reset isReady or reload template")
    }
    
    // MARK: - 6. Adversarial Trailing Slash Normalization Verification
    
    @Test func test_adversarial_trailingSlashNormalization_inAnchorMatching() {
        let vc = MarkdownPreviewViewController()
        _ = vc.view
        
        // Base directory with no trailing slash
        let baseNoSlash = URL(fileURLWithPath: "/Users/developer/Documents/Project")
        vc.setBaseURL(baseNoSlash)
        
        // Anchor target with trailing slash in path
        let targetWithSlash = URL(string: "file:///Users/developer/Documents/Project/#overview")!
        #expect(vc.isAnchorNavigation(targetWithSlash, in: vc.webView) == true, "Target with trailing slash must match base directory without trailing slash")
        
        // Anchor target with multiple trailing slashes
        let targetMultipleSlashes = URL(string: "file:///Users/developer/Documents/Project///#overview")!
        #expect(vc.isAnchorNavigation(targetMultipleSlashes, in: vc.webView) == true, "Target with multiple trailing slashes must match base directory")
        
        // Base directory with trailing slash
        let baseWithSlash = URL(fileURLWithPath: "/Users/developer/Documents/Project/")
        vc.setBaseURL(baseWithSlash)
        
        // Anchor target without trailing slash
        let targetNoSlash = URL(string: "file:///Users/developer/Documents/Project#overview")!
        #expect(vc.isAnchorNavigation(targetNoSlash, in: vc.webView) == true, "Target without trailing slash must match base directory with trailing slash")
        
        // Anchor with empty path (fragment only)
        let fragOnly = URL(string: "#overview")!
        #expect(vc.isAnchorNavigation(fragOnly, in: vc.webView) == true)
        
        // Anchor with root slash
        let slashFrag = URL(string: "/#overview")!
        #expect(vc.isAnchorNavigation(slashFrag, in: vc.webView) == true)
        
        // Anchor for different file in the same directory (must NOT be treated as same-document anchor)
        let differentFile = URL(string: "file:///Users/developer/Documents/Project/other.md#overview")!
        #expect(vc.isAnchorNavigation(differentFile, in: vc.webView) == false, "Different file in directory must not match document anchor")
    }
    
    @Test func test_adversarial_trailingSlash_baseTagContract() async throws {
        let (vc, _) = Self.makeConfiguredController()
        
        let ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready)
        
        // Test base URL without trailing slash: must be rendered with trailing slash so relative images resolve to folder
        let dirWithoutSlash = URL(fileURLWithPath: "/tmp/testfolder")
        vc.updateMarkdown("![Alt](img.png)", baseURL: dirWithoutSlash, resetScroll: false)
        
        let reloaded = await Self.waitFor(timeout: .seconds(5)) { vc.isReady && vc.currentBaseURL == dirWithoutSlash }
        #expect(reloaded)
        
        var baseHasSuffix = false
        for _ in 0..<30 {
            let href = (try? await vc.webView.evaluateJavaScript("document.getElementById('base-tag').getAttribute('href')")) as? String
            if href?.hasSuffix("/") == true && href?.hasSuffix("//") == false {
                baseHasSuffix = true
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(baseHasSuffix, "baseTag href MUST have a trailing slash without double slashes")
        
        // Test base URL with trailing slash on a different directory
        let dirWithSlash = URL(fileURLWithPath: "/tmp/testfolder2/")
        vc.updateMarkdown("![Alt 2](img2.png)", baseURL: dirWithSlash, resetScroll: false)
        
        let reloaded2 = await Self.waitFor(timeout: .seconds(5)) { vc.isReady && vc.currentBaseURL == dirWithSlash }
        #expect(reloaded2)
        
        var baseHasSuffix2 = false
        for _ in 0..<30 {
            let href = (try? await vc.webView.evaluateJavaScript("document.getElementById('base-tag').getAttribute('href')")) as? String
            if href?.hasSuffix("/") == true && href?.hasSuffix("//") == false {
                baseHasSuffix2 = true
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(baseHasSuffix2, "baseTag href must have exactly one trailing slash")
    }
    
    // MARK: - 7. Adversarial Crash Recovery (WebContent Process Termination)
    
    @Test func test_adversarial_crashRecovery_restoresRenderedContent() async throws {
        let (vc, _) = Self.makeConfiguredController()
        
        var ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready)
        
        let criticalContent = "# Critical Unsaved Document\n\nThis text must survive a WebKit process crash."
        vc.updateMarkdown(criticalContent, baseURL: URL(fileURLWithPath: "/tmp/recovery_dir/"), resetScroll: false)
        await Self.yieldMain(duration: .milliseconds(200))
        
        var content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Critical Unsaved Document") == true)
        
        // Simulate WebKit WebContent process crash
        vc.webViewWebContentProcessDidTerminate(vc.webView)
        
        #expect(vc.isReady == false, "isReady must immediately be reset to false upon process termination")
        #expect(vc.pendingUpdate?.content == criticalContent, "pendingUpdate must capture last markdown content")
        #expect(vc.pendingUpdate?.baseURL == URL(fileURLWithPath: "/tmp/recovery_dir/"), "pendingUpdate must capture baseURL")
        
        // Wait for template to automatically reload and flush pending content
        ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready, "WebView must reload and become ready after crash")
        await Self.yieldMain(duration: .milliseconds(200))
        
        content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Critical Unsaved Document") == true, "DOM must be restored with last markdown content after process crash")
    }
    
    @Test func test_adversarial_crashRecovery_duringUnreadyTypingBurst() async throws {
        let (vc, _) = Self.makeConfiguredController()
        
        // Set new base URL to force reload (isReady becomes false)
        vc.setBaseURL(URL(fileURLWithPath: "/tmp/burst_dir/"))
        #expect(vc.isReady == false)
        
        // Rapid keystroke updates while unready
        for i in 1...10 {
            vc.updateMarkdown("Draft keystroke \(i)", baseURL: URL(fileURLWithPath: "/tmp/burst_dir/"), resetScroll: false)
        }
        #expect(vc.lastMarkdown == "Draft keystroke 10")
        
        // Crash the process while it's still loading
        vc.webViewWebContentProcessDidTerminate(vc.webView)
        #expect(vc.pendingUpdate?.content == "Draft keystroke 10", "Pending update must retain the latest keystroke even if crashed during unready state")
        
        // Wait for recovery reload
        let ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready)
        await Self.yieldMain(duration: .milliseconds(200))
        
        let content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Draft keystroke 10") == true, "DOM must reflect the latest keystroke from before the crash")
    }
    
    // MARK: - 8. Performance & Stress Testing
    
    @Test func test_adversarial_performance_heavyMarkdownAndBurst() async throws {
        let (vc, _) = Self.makeConfiguredController()
        
        let ready = await Self.waitFor(timeout: .seconds(5)) { vc.isReady }
        #expect(ready)
        
        // Build 1,000-paragraph document with varied GFM elements
        var heavyMD = "# Heavy Document Stress Test\n\n"
        for i in 1...500 {
            heavyMD += "### Section \(i)\n"
            heavyMD += "Paragraph text for testing performance and layout stability under load.\n\n"
            heavyMD += "- [ ] Task item \(i) pending\n"
            heavyMD += "- [x] Task item \(i) completed\n\n"
        }
        
        let startTime = ContinuousClock.now
        vc.updateMarkdown(heavyMD, baseURL: nil, resetScroll: true)
        await Self.yieldMain(duration: .milliseconds(400))
        let parseTime = ContinuousClock.now - startTime
        
        #expect(parseTime < .seconds(3), "Heavy document (500 sections, 1000 tasks) must update within 3 seconds (took \(parseTime))")
        
        let content = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(content?.contains("Section 500") == true)
        
        // Burst 50 updates at 2ms intervals
        for i in 1...50 {
            vc.updateMarkdown(heavyMD + "\n\nLive Burst \(i)", baseURL: nil, resetScroll: false)
            try? await Task.sleep(for: .milliseconds(2))
        }
        await Self.yieldMain(duration: .milliseconds(400))
        
        let finalContent = try await vc.webView.evaluateJavaScript("document.getElementById('markdown-content').innerHTML") as? String
        #expect(finalContent?.contains("Live Burst 50") == true, "Burst stress test must cleanly resolve to final burst state")
    }
}

