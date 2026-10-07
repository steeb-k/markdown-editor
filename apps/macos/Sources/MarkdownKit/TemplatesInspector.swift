import AppKit
import SwiftUI
import MarkdownCore

/// A row for a field that may be unset. Unset is "as the Default template": the row says "Default" and offers to set it,
/// to `initial`; a set field shows its control and a button that clears it again.
struct OptionalRow<Value, Control: View>: View {
    let title: String
    @Binding var value: Value?
    let initial: Value
    @ViewBuilder let control: (Binding<Value>) -> Control

    var body: some View {
        LabeledContent(title) {
            if let current = value {
                HStack(spacing: 6) {
                    control(Binding(get: { value ?? current }, set: { value = $0 }))
                    Button { value = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear: use the Default template's")
                        .accessibilityLabel("Clear \(title)")
                }
            } else {
                Button("Default") { value = initial }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Set \(title.lowercased())")
                    .accessibilityLabel("Set \(title)")
            }
        }
    }
}

/// A number and its unit (em, px, pt). `title` names both for VoiceOver (the row's label is not theirs).
struct LengthControl: View {
    var title = "Length"
    @Binding var length: TemplateLength

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: Binding(get: { length.value }, set: { length.value = $0 }),
                      format: .number.precision(.fractionLength(0...3)))
                .accessibilityLabel(title)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .labelsHidden()
            Picker("\(title) unit", selection: $length.unit) {
                Text("em").tag(TemplateUnit.em)
                Text("px").tag(TemplateUnit.px)
                Text("pt").tag(TemplateUnit.pt)
            }
            .labelsHidden()
            .frame(width: 64)
        }
    }
}

/// A colour: one of the theme's (which follows light and dark) or a fixed one (the same in both, and in print).
struct ColorControl: View {
    var title = "Colour"
    @Binding var color: TemplateColor
    let editor: TemplateEditor

    private enum Source: Hashable { case fixed, theme(TemplateThemeColor) }

    private var source: Binding<Source> {
        Binding(get: {
            if case .theme(let name) = color { return .theme(name) }
            return .fixed
        }, set: { new in
            switch new {
            case .theme(let name): color = .theme(name: name)
            case .fixed:
                // Fixed keeps the look the theme colour had.
                if case .theme(let name) = color { let (r, g, b) = editor.resolve(name); color = .fixed(r: r, g: g, b: b) }
            }
        })
    }

    private var well: Binding<Color> {
        Binding(get: {
            if case .fixed(let r, let g, let b) = color { return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
            return .clear
        }, set: { new in
            guard let c = NSColor(new).usingColorSpace(.sRGB) else { return }
            func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
            color = .fixed(r: byte(c.redComponent), g: byte(c.greenComponent), b: byte(c.blueComponent))
        })
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker(title, selection: source) {
                Text("Fixed").tag(Source.fixed)
                Divider()
                ForEach(TemplateEditor.themeColors, id: \.1) { Text("Theme: \($0.1)").tag(Source.theme($0.0)) }
            }
            .labelsHidden()
            .frame(width: 150)
            if case .fixed = color {
                ColorPicker(title, selection: well, supportsOpacity: false).labelsHidden()
            }
        }
    }
}

/// A choice among a few named values.
struct ChoiceControl<Value: Hashable>: View {
    let title: String
    let options: [(String, Value)]
    @Binding var value: Value

    var body: some View {
        Picker(title, selection: $value) {
            ForEach(options.indices, id: \.self) { Text(options[$0].0).tag(options[$0].1) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// A font: the editor's body or mono face, or a family by name.
struct FontControl: View {
    @Binding var font: TemplateFont
    private static let families = NSFontManager.shared.availableFontFamilies

    private enum Kind: Hashable { case body, mono, named }

    private var kind: Binding<Kind> {
        Binding(get: {
            switch font {
            case .body: return .body
            case .mono: return .mono
            case .named: return .named
            }
        }, set: { new in
            switch new {
            case .body: font = .body
            case .mono: font = .mono
            case .named: font = .named(name: Self.families.first(where: { $0.hasPrefix("Helvetica") }) ?? Self.families.first ?? "Helvetica")
            }
        })
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker("Font", selection: kind) {
                Text("Body").tag(Kind.body)
                Text("Mono").tag(Kind.mono)
                Text("Named").tag(Kind.named)
            }
            .labelsHidden()
            .fixedSize()
            if case .named(let name) = font {
                Picker("Family", selection: Binding(get: { name }, set: { font = .named(name: $0) })) {
                    // A family the template names that is not installed stays in the list: the picker does not lie.
                    if !Self.families.contains(name) { Text(name).tag(name) }
                    ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
        }
    }
}

/// The right-hand column: an "Element" popup (the page, or one kind), then the fields that apply to it, then the template's
/// description and its custom CSS.
struct TemplatesInspector: View {
    @ObservedObject var editor: TemplateEditor

    var body: some View {
        VStack(spacing: 0) {
            Picker("Element", selection: $editor.targetKey) {
                Text("Page").tag(TemplateEditor.pageKey)
                Divider()
                ForEach(TemplateEditor.kinds, id: \.key) { Text($0.name).tag($0.key) }
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 8)
            .accessibilityIdentifier("templates.element")

            if editor.isReadOnly, let t = editor.working {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    Text("\u{201C}\(t.name)\u{201D} is built in.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Duplicate to edit") { editor.duplicateSelected() }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else if let t = editor.working, let error = t.error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\u{201C}\(t.name)\u{201D} could not be read: \(error)")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .accessibilityElement(children: .combine)
            }

            Form {
                Section(editor.isPage ? "Page" : (editor.targetKind.flatMap { k in TemplateEditor.kinds.first { $0.kind == k }?.name } ?? "")) {
                    if editor.isPage { pageRows } else if let kind = editor.targetKind { elementRows(kind) }
                }
                .disabled(!editor.isEditable)
                Section("Template") {
                    TextField("Description", text: editor.descriptionBinding, axis: .vertical)
                        .lineLimit(1...4)
                        .disabled(!editor.isEditable)
                    LabeledContent("Custom CSS") {
                        HStack(spacing: 8) {
                            Text(editor.working?.hasCustomCSS == true ? "present" : "none").foregroundStyle(.secondary)
                            Button("Reveal in Finder") { reveal() }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func reveal() {
        guard let t = editor.working else { return }
        let css = t.url.appendingPathComponent("custom.css")
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: css.path) ? css : t.url])
    }

    // MARK: the page

    @ViewBuilder private var pageRows: some View {
        OptionalRow(title: "Column width", value: editor.pageBinding(.measureCh, "Column Width", \.measureCh), initial: 66) { v in
            HStack(spacing: 4) {
                TextField("", value: v, format: .number.precision(.fractionLength(0...1))).accessibilityLabel("Column width").multilineTextAlignment(.trailing).frame(width: 56).labelsHidden()
                Text("ch").foregroundStyle(.secondary)
            }
        }
        OptionalRow(title: "Side padding", value: editor.pageBinding(.sidePadding, "Side Padding", \.sidePadding), initial: TemplateLength(value: 1.5, unit: .em)) {
            LengthControl(title: "Side padding", length: $0)
        }
        OptionalRow(title: "Background", value: editor.pageBinding(.background, "Background", \.background), initial: .theme(name: .background)) {
            ColorControl(title: "Page background", color: $0, editor: editor)
        }
        OptionalRow(title: "Align", value: editor.pageBinding(.align, "Align", \.align), initial: .left) { alignControl($0) }
    }

    private func alignControl(_ b: Binding<TemplateAlign>) -> some View {
        ChoiceControl(title: "Align", options: [("Left", .left), ("Centre", .center), ("Right", .right), ("Justify", .justify)], value: b)
    }

    // MARK: one element

    @ViewBuilder private func elementRows(_ kind: TemplateElementKind) -> some View {
        ForEach(TemplateField.allCases.filter { $0.applies(to: kind) }, id: \.self) { field in
            row(kind, field)
        }
    }

    private func length(_ kind: TemplateElementKind, _ field: TemplateField, _ path: WritableKeyPath<TemplateElementStyle, TemplateLength?>,
                        initial: TemplateLength) -> some View {
        OptionalRow(title: field.title, value: editor.binding(kind, field, path), initial: initial) { LengthControl(title: field.title, length: $0) }
    }

    private func colour(_ kind: TemplateElementKind, _ field: TemplateField, _ path: WritableKeyPath<TemplateElementStyle, TemplateColor?>,
                        initial: TemplateThemeColor) -> some View {
        OptionalRow(title: field.title, value: editor.binding(kind, field, path), initial: .theme(name: initial)) { ColorControl(title: field.title, color: $0, editor: editor) }
    }

    @ViewBuilder private func row(_ kind: TemplateElementKind, _ field: TemplateField) -> some View {
        let one = TemplateLength(value: 1, unit: .em)
        switch field {
        case .fontFamily:
            OptionalRow(title: field.title, value: editor.binding(kind, field, \.fontFamily), initial: .body) { FontControl(font: $0) }
        case .fontSize: length(kind, field, \.fontSize, initial: one)
        case .weight:
            OptionalRow(title: field.title, value: editor.binding(kind, field, \.weight), initial: 400) { b in
                ChoiceControl(title: "Weight", options: stride(from: 100, through: 900, by: 100).map { (String($0), UInt16($0)) }, value: b)
            }
        case .italic:
            OptionalRow(title: field.title, value: editor.binding(kind, field, \.italic), initial: true) { Toggle("Italic", isOn: $0).labelsHidden() }
        case .color: colour(kind, field, \.color, initial: .text)
        case .background: colour(kind, field, \.background, initial: .codeBackground)
        case .spaceAbove: length(kind, field, \.spaceAbove, initial: one)
        case .spaceBelow: length(kind, field, \.spaceBelow, initial: one)
        case .lineHeight:
            OptionalRow(title: field.title, value: editor.binding(kind, field, \.lineHeight), initial: 1.5) { b in
                TextField("", value: b, format: .number.precision(.fractionLength(0...2))).accessibilityLabel(field.title).multilineTextAlignment(.trailing).frame(width: 56).labelsHidden()
            }
        case .align:
            OptionalRow(title: field.title, value: editor.binding(kind, field, \.align), initial: .left) { alignControl($0) }
        case .indent: length(kind, field, \.indent, initial: TemplateLength(value: 1.5, unit: .em))
        case .letterSpacing: length(kind, field, \.letterSpacing, initial: TemplateLength(value: 0.02, unit: .em))
        case .transform:
            OptionalRow(title: field.title, value: editor.binding(kind, field, \.transform), initial: .uppercase) { b in
                ChoiceControl(title: "Transform", options: [("None", .none), ("Uppercase", .uppercase), ("Small caps", .smallCaps)], value: b)
            }
        case .decoration:
            OptionalRow(title: field.title, value: editor.binding(kind, field, \.decoration), initial: .underline) { b in
                ChoiceControl(title: "Decoration", options: [("None", .none), ("Underline", .underline)], value: b)
            }
        case .border:
            OptionalRow(title: field.title, value: editor.binding(kind, field, \.border),
                        initial: TemplateBorder(side: .bottom, style: .solid, width: TemplateLength(value: 1, unit: .px), color: .theme(name: .border))) { b in
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        ChoiceControl(title: "Border side", options: [("Top", .top), ("Right", .right), ("Bottom", .bottom), ("Left", .left)], value: b.side)
                        ChoiceControl(title: "Border style", options: [("Solid", .solid), ("Dashed", .dashed), ("Dotted", .dotted)], value: b.style)
                    }
                    LengthControl(title: "Border width", length: b.width)
                    ColorControl(title: "Border colour", color: b.color, editor: editor)
                }
            }
        case .radius: length(kind, field, \.radius, initial: TemplateLength(value: 0.25, unit: .em))
        case .numbered:
            OptionalRow(title: field.title, value: editor.binding(kind, field, \.numbered), initial: true) { Toggle("Numbered", isOn: $0).labelsHidden() }
        case .marker:
            let numbered = kind == .numberedList
            OptionalRow(title: field.title, value: editor.binding(kind, field, \.marker), initial: numbered ? .decimal : .disc) { b in
                ChoiceControl(title: "Marker",
                              options: numbered ? [("1. 2. 3.", .decimal), ("a. b. c.", .lowerAlpha), ("i. ii. iii.", .lowerRoman)]
                                                : [("Disc", .disc), ("Circle", .circle), ("Square", .square), ("Dash", .dash)],
                              value: b)
            }
        }
    }
}
