//
//  NSAttributedString.swift
//  Soduto
//
//  Created by Giedrius on 2017-06-30.
//  Copyright © 2017 Soduto. All rights reserved.
//

import Foundation
import Cocoa

extension NSAttributedString {
    
    public func byReplacingMarkdownWithLinks() -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: self)
        mutable.replaceMarkdownWithLinks()
        return mutable
    }
    
}

extension NSMutableAttributedString {
    
    public func applyDefaultAttributes(_ attributes: [NSAttributedString.Key:Any]) {
        let origString = NSAttributedString(attributedString: self)
        let wholeRange = NSMakeRange(0, length)
        for attr in attributes {
            addAttribute(attr.key, value: attr.value, range: wholeRange)
        }
        origString.enumerateAttribute(NSAttributedString.Key.font, in: wholeRange, options: []) { (value, range, _) in
            guard let font = value as? NSFont else { return }
            self.addAttribute(NSAttributedString.Key.font, value: font, range: range)
        }
    }
    
    public func applyDefaultFont(_ defaultFont: NSFont) {
        applyDefaultAttributes([NSAttributedString.Key.font: defaultFont])
    }
    
    public func replaceMarkdownWithLinks() {
        var offset: Int = 0
        let source = self.string as NSString
        
        let regex = try! NSRegularExpression(pattern: "\\[([^]]+)\\]\\(([^\\)]+)\\)")
        regex.enumerateMatches(in: source as String, options: [], range: NSMakeRange(0, length)) { (result, _, _) in
            guard let result = result else { return }
            
            let linkText = source.substring(with: result.range(at: 1))
            let linkUrl = source.substring(with: result.range(at: 2))
            let linkAttributes: [NSAttributedString.Key:Any]?
            if let url = URL(string: linkUrl) {
                linkAttributes = [
                    NSAttributedString.Key.link: url,
                    NSAttributedString.Key.foregroundColor: NSColor.keyboardFocusIndicatorColor
                ]
            }
            else {
                linkAttributes = nil
            }
            let linkString = NSAttributedString(string: linkText, attributes: linkAttributes)
            
            var replaceRange = result.range(at: 0)
            replaceRange.location += offset
            replaceCharacters(in: replaceRange, with: linkString)
            offset += result.range(at: 1).length - result.range(at: 0).length
        }
    }
    
}
