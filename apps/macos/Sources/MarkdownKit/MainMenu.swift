import AppKit

enum MainMenu {
    private static func item(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let i = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        i.tag = tag
        return i
    }

    private static func submenu(_ main: NSMenu, _ title: String, build: (NSMenu) -> Void) -> NSMenu {
        let menu = NSMenu(title: title)
        build(menu)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    private static func nested(_ parent: NSMenu, _ title: String, build: (NSMenu) -> Void) {
        let menu = NSMenu(title: title)
        build(menu)
        let holder = parent.addItem(withTitle: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
    }

    static func build() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let main = NSMenu()

        _ = submenu(main, name) { m in
            _ = item(m, "About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            m.addItem(.separator())
            _ = item(m, "Settings…", #selector(AppDelegate.showSettings(_:)), ",")
            m.addItem(.separator())
            let services = NSMenu(title: "Services")
            let sItem = m.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
            sItem.submenu = services
            NSApp.servicesMenu = services
            m.addItem(.separator())
            _ = item(m, "Hide \(name)", #selector(NSApplication.hide(_:)), "h")
            _ = item(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            _ = item(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
            m.addItem(.separator())
            _ = item(m, "Quit \(name)", #selector(NSApplication.terminate(_:)), "q")
        }

        _ = submenu(main, "File") { m in
            _ = item(m, "New", #selector(NSDocumentController.newDocument(_:)), "n")
            _ = item(m, "New Tab", #selector(NSResponder.newWindowForTab(_:)), "t")
            _ = item(m, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
            nested(m, "Open Recent") { r in
                _ = item(r, "Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))
            }
            m.addItem(.separator())
            _ = item(m, "Close", #selector(NSWindow.performClose(_:)), "w")
            _ = item(m, "Save…", #selector(NSDocument.save(_:)), "s")
            _ = item(m, "Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift])
            let saveAs = item(m, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift, .option])
            saveAs.isAlternate = true
            _ = item(m, "Rename…", #selector(NSDocument.rename(_:)))
            _ = item(m, "Move To…", #selector(NSDocument.move(_:)))
            nested(m, "Revert To") { r in
                _ = item(r, "Last Saved Version", #selector(NSDocument.revertToSaved(_:)))
                _ = item(r, "Browse All Versions…", #selector(NSDocument.browseVersions(_:)))
            }
        }

        _ = submenu(main, "Edit") { m in
            _ = item(m, "Undo", Selector(("undo:")), "z")
            _ = item(m, "Redo", Selector(("redo:")), "z", [.command, .shift])
            m.addItem(.separator())
            _ = item(m, "Cut", #selector(NSText.cut(_:)), "x")
            _ = item(m, "Copy", #selector(NSText.copy(_:)), "c")
            _ = item(m, "Paste", #selector(NSText.paste(_:)), "v")
            _ = item(m, "Paste as Plain Text", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
            nested(m, "Paste As") { p in
                _ = item(p, "Me", #selector(EditorTextView.pasteAsMe(_:)), "v", [.command, .option])
                _ = item(p, "AI", #selector(EditorTextView.pasteAsAI(_:)), "v", [.command, .shift])
                _ = item(p, "Reference", #selector(EditorTextView.pasteAsReference(_:)), "v", [.command, .control])
            }
            nested(m, "Mark As") { a in
                _ = item(a, "Me", #selector(EditorTextView.markAsMe(_:)), "1", [.command, .control])
                _ = item(a, "AI", #selector(EditorTextView.markAsAI(_:)), "2", [.command, .control])
                _ = item(a, "Reference", #selector(EditorTextView.markAsReference(_:)), "3", [.command, .control])
                a.addItem(.separator())
                _ = item(a, "No Author", #selector(EditorTextView.markAsNoAuthor(_:)), "0", [.command, .control])
            }
            _ = item(m, "Delete", #selector(NSText.delete(_:)))
            _ = item(m, "Select All", #selector(NSText.selectAll(_:)), "a")
            m.addItem(.separator())
            nested(m, "Find") { f in
                let find = #selector(NSResponder.performTextFinderAction(_:))
                _ = item(f, "Find…", find, "f", tag: NSTextFinder.Action.showFindInterface.rawValue)
                _ = item(f, "Find and Replace…", find, "f", [.command, .option], tag: NSTextFinder.Action.showReplaceInterface.rawValue)
                _ = item(f, "Find Next", find, "g", tag: NSTextFinder.Action.nextMatch.rawValue)
                _ = item(f, "Find Previous", find, "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue)
                _ = item(f, "Use Selection for Find", find, "e", tag: NSTextFinder.Action.setSearchString.rawValue)
                _ = item(f, "Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j")
            }
            nested(m, "Spelling") { s in
                _ = item(s, "Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":")
                _ = item(s, "Check Document Now", #selector(NSText.checkSpelling(_:)), ";")
                s.addItem(.separator())
                _ = item(s, "Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)))
                _ = item(s, "Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:)))
                _ = item(s, "Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)))
            }
        }

        _ = submenu(main, "Format") { m in
            _ = item(m, "Strong", #selector(EditorTextView.toggleStrong(_:)), "b")
            _ = item(m, "Emphasis", #selector(EditorTextView.toggleEmphasis(_:)), "i")
            _ = item(m, "Strikethrough", #selector(EditorTextView.toggleStrikethrough(_:)), "x", [.command, .shift])
            _ = item(m, "Inline Code", #selector(EditorTextView.toggleInlineCode(_:)), "c", [.command, .option])
            _ = item(m, "Link", #selector(EditorTextView.insertLink(_:)), "k")
            _ = item(m, "Image…", #selector(EditorTextView.insertImage(_:)), "i", [.command, .option])
            m.addItem(.separator())
            nested(m, "Heading") { h in
                for level in 1...6 {
                    _ = item(h, "Heading \(level)", #selector(EditorTextView.setHeadingLevel(_:)), "\(level)", tag: level)
                }
                h.addItem(.separator())
                _ = item(h, "Body", #selector(EditorTextView.setHeadingLevel(_:)), "0", [.command, .option], tag: 0)
            }
            m.addItem(.separator())
            _ = item(m, "Bulleted List", #selector(EditorTextView.toggleBulletList(_:)), "8", [.command, .shift])
            _ = item(m, "Numbered List", #selector(EditorTextView.toggleNumberedList(_:)), "7", [.command, .shift])
            _ = item(m, "Task List", #selector(EditorTextView.toggleTaskList(_:)), "9", [.command, .shift])
            _ = item(m, "Block Quote", #selector(EditorTextView.toggleBlockQuote(_:)), ".", [.command, .shift])
            _ = item(m, "Code Block", #selector(EditorTextView.toggleCodeBlock(_:)), "k", [.command, .option])
        }

        _ = submenu(main, "Table") { m in
            _ = item(m, "Insert Table…", #selector(EditorTextView.insertTable(_:)), "t", [.command, .option])
            m.addItem(.separator())
            _ = item(m, "Add Row Above", #selector(EditorTextView.tableAddRowAbove(_:)))
            _ = item(m, "Add Row Below", #selector(EditorTextView.tableAddRowBelow(_:)))
            _ = item(m, "Add Column Left", #selector(EditorTextView.tableAddColumnLeft(_:)))
            _ = item(m, "Add Column Right", #selector(EditorTextView.tableAddColumnRight(_:)))
            m.addItem(.separator())
            _ = item(m, "Delete Row", #selector(EditorTextView.tableDeleteRow(_:)))
            _ = item(m, "Delete Column", #selector(EditorTextView.tableDeleteColumn(_:)))
            m.addItem(.separator())
            nested(m, "Column Alignment") { a in
                _ = item(a, "Default", #selector(EditorTextView.tableSetAlignment(_:)), tag: 0)
                _ = item(a, "Left", #selector(EditorTextView.tableSetAlignment(_:)), tag: 1)
                _ = item(a, "Center", #selector(EditorTextView.tableSetAlignment(_:)), tag: 2)
                _ = item(a, "Right", #selector(EditorTextView.tableSetAlignment(_:)), tag: 3)
            }
            _ = item(m, "Re-align Table", #selector(EditorTextView.tableRealign(_:)))
        }

        _ = submenu(main, "View") { m in
            _ = item(m, "Source", #selector(EditorTextView.showSourceMode(_:)), "1", [.command, .option])
            _ = item(m, "Live", #selector(EditorTextView.showLiveMode(_:)), "2", [.command, .option])
            m.addItem(.separator())
            _ = item(m, "Focus Mode", #selector(EditorTextView.toggleFocusMode(_:)), "d")
            nested(m, "Focus Scope") { f in
                _ = item(f, "Sentence", #selector(EditorTextView.setFocusScope(_:)), tag: 0)
                _ = item(f, "Paragraph", #selector(EditorTextView.setFocusScope(_:)), tag: 1)
            }
            nested(m, "Syntax Highlight") { h in
                _ = item(h, "Highlight Parts of Speech", #selector(EditorTextView.toggleSyntaxHighlight(_:)), "d", [.command, .shift])
                h.addItem(.separator())
                for (i, c) in SyntaxClass.allCases.enumerated() {
                    _ = item(h, c.title, #selector(EditorTextView.toggleSyntaxClass(_:)), tag: i)
                }
            }
            _ = item(m, "Show Authorship", #selector(EditorTextView.toggleAuthorshipDisplay(_:)), "a", [.command, .option])
            m.addItem(.separator())
            _ = item(m, "Hide Formatting Toolbar", #selector(AppDelegate.toggleFormattingToolbar(_:)), "t", [.command, .control])
            m.addItem(.separator())
            _ = item(m, "Make Text Bigger", #selector(AppDelegate.biggerText(_:)), "+")
            _ = item(m, "Make Text Smaller", #selector(AppDelegate.smallerText(_:)), "-")
            _ = item(m, "Actual Size", #selector(AppDelegate.actualSize(_:)), "0")
            m.addItem(.separator())
            _ = item(m, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }

        let window = submenu(main, "Window") { m in
            _ = item(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            _ = item(m, "Zoom", #selector(NSWindow.performZoom(_:)))
            m.addItem(.separator())
            _ = item(m, "Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift])
            _ = item(m, "Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", [.control])
            _ = item(m, "Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:)))
            _ = item(m, "Merge All Windows", #selector(NSWindow.mergeAllWindows(_:)))
            m.addItem(.separator())
            _ = item(m, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        }
        NSApp.windowsMenu = window

        let help = submenu(main, "Help") { m in
            _ = item(m, "Markdown Syntax Help", #selector(AppDelegate.openHelp(_:)), "?")
        }
        NSApp.helpMenu = help

        return main
    }
}
