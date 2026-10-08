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

    private static func attach(_ parent: NSMenu, _ menu: NSMenu) {
        parent.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
    }

    /// Paste As and Mark As, built once here for the Edit menu and the editor's context menu: the same
    /// selectors and key equivalents (the context menu shows them too), validated by the text view.
    static func pasteAsMenu() -> NSMenu {
        let p = NSMenu(title: "Paste As")
        _ = item(p, "Me", #selector(EditorTextView.pasteAsMe(_:)), "v", [.command, .option])
        _ = item(p, "AI", #selector(EditorTextView.pasteAsAI(_:)), "v", [.command, .shift])
        _ = item(p, "Reference", #selector(EditorTextView.pasteAsReference(_:)), "v", [.command, .control])
        return p
    }

    static func markAsMenu() -> NSMenu {
        let a = NSMenu(title: "Mark As")
        _ = item(a, "Me", #selector(EditorTextView.markAsMe(_:)), "1", [.command, .control])
        _ = item(a, "AI", #selector(EditorTextView.markAsAI(_:)), "2", [.command, .control])
        _ = item(a, "Reference", #selector(EditorTextView.markAsReference(_:)), "3", [.command, .control])
        a.addItem(.separator())
        _ = item(a, "No Author", #selector(EditorTextView.markAsNoAuthor(_:)), "0", [.command, .control])
        return a
    }

    static func build() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let main = NSMenu()

        _ = submenu(main, name) { m in
            _ = item(m, "About \(name)", #selector(AppDelegate.showAbout(_:)))
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
            _ = item(m, "New Folder", #selector(EditorWindowController.newFolder(_:)), "n", [.command, .option])
            _ = item(m, "Today\u{2019}s Note", #selector(EditorWindowController.todaysNote(_:)), "n", [.command, .control])
            nested(m, "New from Template") { t in
                t.delegate = TemplateMenuDelegate.shared
                _ = item(t, "Choose Template\u{2026}", #selector(EditorWindowController.chooseTemplate(_:)), "n", [.command, .shift])
            }
            _ = item(m, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
            nested(m, "Open Recent") { r in
                _ = item(r, "Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))
            }
            m.addItem(.separator())
            _ = item(m, "Close", #selector(NSWindow.performClose(_:)), "w")
            _ = item(m, "Save", #selector(NSDocument.save(_:)), "s")
            _ = item(m, "Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift])
            let saveAs = item(m, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift, .option])
            saveAs.isAlternate = true
            _ = item(m, "Rename…", #selector(NSDocument.rename(_:)))
            _ = item(m, "Move To…", #selector(NSDocument.move(_:)))
            m.addItem(.separator())
            nested(m, "Export") { e in
                _ = item(e, "PDF…", #selector(EditorWindowController.exportPDF(_:)))
            }
            _ = item(m, "Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift])
            _ = item(m, "Print…", #selector(NSDocument.printDocument(_:)), "p")
        }

        _ = submenu(main, "Edit") { m in
            _ = item(m, "Undo", Selector(("undo:")), "z")
            _ = item(m, "Redo", Selector(("redo:")), "z", [.command, .shift])
            m.addItem(.separator())
            _ = item(m, "Cut", #selector(NSText.cut(_:)), "x")
            _ = item(m, "Copy", #selector(NSText.copy(_:)), "c")
            _ = item(m, "Paste", #selector(NSText.paste(_:)), "v")
            _ = item(m, "Paste as Plain Text", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
            attach(m, pasteAsMenu())
            attach(m, markAsMenu())
            nested(m, "Copy As") { c in
                _ = item(c, "HTML", #selector(EditorWindowController.copyAsHTML(_:)))
                _ = item(c, "Rich Text", #selector(EditorWindowController.copyAsRichText(_:)))
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
            // Substitutions are off by default (smart quotes and dashes would corrupt Markdown), and
            // each is a switch here.
            nested(m, "Substitutions") { s in
                _ = item(s, "Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:)))
                s.addItem(.separator())
                _ = item(s, "Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:)))
                _ = item(s, "Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)))
                _ = item(s, "Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:)))
                _ = item(s, "Smart Links", #selector(NSTextView.toggleAutomaticLinkDetection(_:)))
                _ = item(s, "Data Detectors", #selector(NSTextView.toggleAutomaticDataDetection(_:)))
                _ = item(s, "Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:)))
            }
            nested(m, "Transformations") { t in
                _ = item(t, "Make Upper Case", #selector(NSResponder.uppercaseWord(_:)))
                _ = item(t, "Make Lower Case", #selector(NSResponder.lowercaseWord(_:)))
                _ = item(t, "Capitalize", #selector(NSResponder.capitalizeWord(_:)))
            }
            nested(m, "Speech") { s in
                _ = item(s, "Start Speaking", #selector(NSTextView.startSpeaking(_:)))
                _ = item(s, "Stop Speaking", #selector(NSTextView.stopSpeaking(_:)))
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
            m.addItem(.separator())
            // Filled each time it opens, so a template added since appears (see `DocumentTemplateMenu`).
            attach(m, DocumentTemplateMenu.makeMenu())
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

        _ = submenu(main, "Library") { m in
            _ = item(m, "Quick Open\u{2026}", #selector(EditorWindowController.quickOpen(_:)), "o", [.command, .shift])
            _ = item(m, "Search Library", #selector(EditorWindowController.searchLibrary(_:)), "f", [.command, .shift])
            m.addItem(.separator())
            _ = item(m, "Rename", #selector(EditorWindowController.renameSelection(_:)))
            _ = item(m, "Duplicate Note", #selector(EditorWindowController.duplicateSelection(_:)))
            _ = item(m, "Reveal in Finder", #selector(EditorWindowController.revealSelection(_:)))
            // No key equivalent: a menu item that matches ⌘⌫ takes the key even while it is disabled, and ⌘⌫ is the
            // editor's delete to the start of the line. The sidebar's list takes ⌘⌫ itself (`SidebarOutlineView`).
            _ = item(m, "Move to Trash", #selector(EditorWindowController.trashSelection(_:)))
            m.addItem(.separator())
            _ = item(m, "Add Folder\u{2026}", #selector(EditorWindowController.addFolderToLibrary(_:)))
            _ = item(m, "Choose Library Folder\u{2026}", #selector(EditorWindowController.chooseLibraryFolder(_:)))
            _ = item(m, "Remove Folder from Library", #selector(EditorWindowController.removeSelectedFolderFromLibrary(_:)))
        }

        _ = submenu(main, "View") { m in
            // Layouts: the editor alone, beside the preview, the preview alone.
            _ = item(m, "Editor", #selector(EditorWindowController.showEditorLayout(_:)), "3", [.command, .option])
            _ = item(m, "Editor and Preview", #selector(EditorWindowController.showSplitLayout(_:)), "4", [.command, .option])
            _ = item(m, "Preview", #selector(EditorWindowController.showPreviewLayout(_:)), "5", [.command, .option])
            m.addItem(.separator())
            _ = item(m, "Focus Mode", #selector(EditorTextView.toggleFocusMode(_:)), "d")
            nested(m, "Focus Scope") { f in
                _ = item(f, "Sentence", #selector(EditorTextView.setFocusScope(_:)), tag: 0)
                _ = item(f, "Paragraph", #selector(EditorTextView.setFocusScope(_:)), tag: 1)
            }
            _ = item(m, "Keep Focused Line Centred", #selector(AppDelegate.toggleCentreFocusedLine(_:)))
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
            _ = item(m, "Show Outline", #selector(EditorWindowController.toggleSideColumn(_:)), "o", [.command, .control])
            _ = item(m, "Show History", #selector(EditorWindowController.showHistory(_:)), "h", [.command, .control])
            m.addItem(.separator())
            _ = item(m, "Notes Mode", #selector(EditorWindowController.toggleNotesMode(_:)), "l", [.command, .control])
            _ = item(m, "Show Backlinks", #selector(EditorWindowController.toggleBacklinks(_:)), "b", [.command, .option])
            nested(m, "Sort Notes") { s in
                _ = item(s, "By Name", #selector(EditorWindowController.sortNotesByName(_:)))
                _ = item(s, "By Date Modified", #selector(EditorWindowController.sortNotesByModified(_:)))
            }
            m.addItem(.separator())
            _ = item(m, "Make Text Bigger", #selector(AppDelegate.biggerText(_:)), "+")
            _ = item(m, "Make Text Smaller", #selector(AppDelegate.smallerText(_:)), "-")
            _ = item(m, "Actual Size", #selector(AppDelegate.actualSize(_:)), "0")
            attach(m, LineWidthMenu.makeMenu())
            m.addItem(.separator())
            _ = item(m, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }

        let window = submenu(main, "Window") { m in
            _ = item(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            _ = item(m, "Zoom", #selector(NSWindow.performZoom(_:)))
            m.addItem(.separator())
            _ = item(m, "Templates\u{2026}", #selector(AppDelegate.showTemplates(_:)), "t", [.command, .shift])
            m.addItem(.separator())
            _ = item(m, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        }
        NSApp.windowsMenu = window

        let help = submenu(main, "Help") { m in
            _ = item(m, "Markdown Help", #selector(AppDelegate.showWelcome(_:)), "?")
            _ = item(m, "Markdown Syntax Reference", #selector(AppDelegate.openSyntaxReference(_:)))
            m.addItem(.separator())
            _ = item(m, "Acknowledgements", #selector(AppDelegate.showAcknowledgements(_:)))
        }
        NSApp.helpMenu = help

        return main
    }
}
