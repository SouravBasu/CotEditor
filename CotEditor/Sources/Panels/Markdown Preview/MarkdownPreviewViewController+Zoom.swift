//
//  MarkdownPreviewViewController+Zoom.swift
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

extension MarkdownPreviewViewController: NSUserInterfaceValidations, TextSizeChanging {
    
    private static let zoomRange: ClosedRange<CGFloat> = 0.5...3.0
    private static let zoomStep: CGFloat = 0.1
    private static let defaultZoom: CGFloat = 1.0
    
    
    // MARK: User Interface Validations
    
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        
        switch item.action {
            case #selector(biggerFont):
                return self.webView.pageZoom < Self.zoomRange.upperBound - 0.01
                
            case #selector(smallerFont):
                return self.webView.pageZoom > Self.zoomRange.lowerBound + 0.01
                
            case #selector(resetFont):
                return abs(self.webView.pageZoom - Self.defaultZoom) > 0.01
                
            case nil:
                return false
                
            default:
                return true
        }
    }
    
    
    // MARK: Action Messages
    
    /// Increases the preview content zoom level.
    @IBAction func biggerFont(_ sender: Any?) {
        
        let currentZoom = self.webView.pageZoom
        let nextZoom = (round((currentZoom + Self.zoomStep) * 10) / 10).clamped(to: Self.zoomRange)
        self.webView.pageZoom = nextZoom
    }
    
    
    /// Decreases the preview content zoom level.
    @IBAction func smallerFont(_ sender: Any?) {
        
        let currentZoom = self.webView.pageZoom
        let nextZoom = (round((currentZoom - Self.zoomStep) * 10) / 10).clamped(to: Self.zoomRange)
        self.webView.pageZoom = nextZoom
    }
    
    
    /// Resets the preview content zoom level to default (1.0).
    @IBAction func resetFont(_ sender: Any?) {
        
        self.webView.pageZoom = Self.defaultZoom
    }
}
