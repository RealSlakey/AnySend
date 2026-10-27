import Defaults

class ContentDropView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    private func setHighlighted(_ highlighted: Bool) {
        (superview as? NSStatusBarButton)?.highlight(highlighted)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        setHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHighlighted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setHighlighted(false)
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        var success = false
        
        // File URLs
        if let fileUrls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            /**
             Although file URLs shared via dragging already contain access permission, we pass this through the bookmark mechanism for uniformity and readability of the code with URLs shared from the share extension.
             - SeeAlso: [Enabling App Sandbox#Enabling User-Selected File Access](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html#//apple_ref/doc/uid/TP40011195-CH4-SW6)
             - SeeAlso: [``Shared/createBookmarkForFile(at:)``](x-source-tag://create-bookmark-func)
             */
            let bookmarks: [Data] = fileUrls.compactMap { createBookmarkForFile(at: $0) }
            Defaults[.pendingFiles].append(contentsOf: bookmarks)
            success = true
        }
        
        // Web URLs and text
        if let items = pasteboard.readObjects(forClasses: [NSURL.self, NSString.self], options: nil) {
            let strings = items.compactMap { item -> String? in
                if let url = item as? URL, !url.isFileURL {
                    return url.absoluteString
                } else if let string = item as? String {
                    return string
                }
                return nil
            }
            Defaults[.pendingStrings].append(contentsOf: strings)
            success = true
        }

        if success {
            // Offer the nearby devices right below the menu bar icon so the file
            // can be sent without opening the main window.
            (NSApp.delegate as? AppDelegate)?.presentTrayDrop()
        }

        return success
    }
}
