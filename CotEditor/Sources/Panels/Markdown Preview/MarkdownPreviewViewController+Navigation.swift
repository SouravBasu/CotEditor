//
//  MarkdownPreviewViewController+Navigation.swift
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
import OSLog

extension MarkdownPreviewViewController: WKNavigationDelegate {
    
    // MARK: Navigation Delegate
    
    /// Decides whether to allow or cancel navigation actions triggered within the web view.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Intercept link activations
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            // For programmatic navigations (scripts, meta refresh), prevent navigating away to external web pages
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               (scheme == "http" || scheme == "https") {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
            return
        }
        
        // Allow intra-document anchor jumps (#heading) to scroll smoothly
        if self.isAnchorNavigation(url, in: webView) {
            decisionHandler(.allow)
            return
        }
        
        // Route permitted external links (http, https, mailto, valid file URLs) to default applications
        if self.isPermittedExternalURL(url) {
            _ = self.openURL(url)
        }
        
        // Disallow navigating the preview webview to external destinations or executing unsafe schemes
        decisionHandler(.cancel)
    }
    
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.isReady = true
        self.flushPendingUpdate()
    }
    
    
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        self.isReady = false
        if let markdown = self.lastMarkdown {
            self.pendingUpdate = (markdown, self.currentBaseURL, false)
        }
        self.loadTemplate(baseURL: self.currentBaseURL)
    }
    
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Logger(subsystem: "com.coteditor.CotEditor", category: "MarkdownPreview").error("Markdown preview navigation failed: \(error.localizedDescription)")
        self.isReady = false
    }
    
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        Logger(subsystem: "com.coteditor.CotEditor", category: "MarkdownPreview").error("Markdown preview provisional navigation failed: \(error.localizedDescription)")
        self.isReady = false
    }
    
    
    // MARK: Private Methods
    
    /// Determines whether the given URL is an internal anchor jump within the current preview document.
    func isAnchorNavigation(_ targetURL: URL, in webView: WKWebView) -> Bool {
        
        guard let fragment = targetURL.fragment, !fragment.isEmpty else {
            return false
        }
        
        // External schemes or unsafe schemes are never intra-document anchor jumps
        let scheme = targetURL.scheme?.lowercased()
        if scheme == "http" || scheme == "https" || scheme == "mailto" {
            return false
        }
        if let scheme, scheme != "file", scheme != "about" {
            return false
        }
        
        // Compare target URL with current webview URL ignoring fragment
        if let currentURL = webView.url, self.matchesIgnoringFragment(targetURL, currentURL) {
            return true
        }
        
        // Compare target URL with stored document base URL ignoring fragment
        if let baseURL = self.currentBaseURL, self.matchesIgnoringFragment(targetURL, baseURL) {
            return true
        }
        
        // Relative fragment-only URLs (e.g., "#section")
        if targetURL.path.isEmpty || targetURL.path == "/" {
            return true
        }
        
        return false
    }
    
    
    /// Checks whether two URLs match when fragments are omitted and trailing slashes are normalized.
    private func matchesIgnoringFragment(_ url1: URL, _ url2: URL) -> Bool {
        
        guard var comp1 = URLComponents(url: url1, resolvingAgainstBaseURL: true),
              var comp2 = URLComponents(url: url2, resolvingAgainstBaseURL: true) else {
            return false
        }
        
        comp1.fragment = nil
        comp2.fragment = nil
        
        if comp1 == comp2 {
            return true
        }
        
        comp1.scheme = comp1.scheme?.lowercased()
        comp2.scheme = comp2.scheme?.lowercased()
        comp1.host = comp1.host?.lowercased()
        comp2.host = comp2.host?.lowercased()
        
        let normalizePath: (String) -> String = { path in
            var p = path
            while p.hasSuffix("/") {
                p.removeLast()
            }
            return p
        }
        
        comp1.path = normalizePath(comp1.path)
        comp2.path = normalizePath(comp2.path)
        
        return comp1 == comp2
    }
    
    
    /// Determines whether the given URL uses a safe, permitted scheme for external launch via NSWorkspace.
    private func isPermittedExternalURL(_ url: URL) -> Bool {
        
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        
        switch scheme {
            case "http", "https", "mailto":
                return true
                
            case "file":
                return url.isFileURL
                
            default:
                return false
        }
    }
}


// MARK: - UI Delegate

extension MarkdownPreviewViewController: WKUIDelegate {
    
    // MARK: UI Delegate
    
    /// Intercepts links requesting a new window or frame (such as target="_blank" or window.open).
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        
        if let url = navigationAction.request.url, self.isPermittedExternalURL(url) {
            _ = self.openURL(url)
        }
        return nil
    }
    
    
    /// Suppresses JavaScript alert modal dialogs.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        
        completionHandler()
    }
    
    
    /// Suppresses JavaScript confirm modal dialogs.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        
        completionHandler(false)
    }
}
