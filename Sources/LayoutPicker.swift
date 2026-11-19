import AppKit

/// Draws a small preview of a grid layout with numbered tiles.
final class LayoutPreviewView: NSView {
    var layout: GridLayout? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        guard let layout else {
            let s = "Invalid layout" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
            return
        }
        let inner = bounds.insetBy(dx: 6, dy: 6)
        for (i, f) in layout.frames(in: inner.size, gap: 4).enumerated() {
            let r = f.offsetBy(dx: inner.minX, dy: inner.minY)
            let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.stroke()
            let label = "\(i + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: max(9, min(18, r.height / 3))),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        }
    }
}

/// Asks how big a grid to open: 2×2, 3×3, or a custom pattern like XOO/XOO.
final class LayoutPickerController: NSWindowController, NSTextFieldDelegate {
    private let asSheet: Bool
    private let completion: (GridLayout) -> Void

    private var radioTwo: NSButton!
    private var radioThreeTwo: NSButton!
    private var radioThree: NSButton!
    private var radioCustom: NSButton!
    private let patternField = NSTextField()
    private let examples = NSPopUpButton(frame: .zero, pullsDown: true)
    private let preview = LayoutPreviewView()
    private let errorLabel = NSTextField(labelWithString: "")
    private var openButton: NSButton!

    static let presets: [(pattern: String, label: String)] = [
        ("XOO/XOO", "1 tall + 4"),
        ("XXO/XXO/OOO", "1 large + 5  (3×3 grid, 6 videos)"),
        ("XO/XO", "1 tall + 2"),
        ("XX/OO", "1 wide + 2"),
        ("OO/OO/OO", "2 across, 3 down (6)"),
        ("XXOO/XXOO/OOOO", "1 large + 8"),
        ("OOOO/OOOO/OOOO/OOOO", "4×4 (16)"),
    ]

    init(asSheet: Bool, completion: @escaping (GridLayout) -> Void) {
        self.asSheet = asSheet
        self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Video Grid: Choose a Layout"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        restoreChoice()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        guard let window else { return }
        radioTwo = NSButton(radioButtonWithTitle: "2 × 2   (4 videos)", target: self, action: #selector(choiceChanged(_:)))
        radioThreeTwo = NSButton(radioButtonWithTitle: "3 × 2   (6 videos: 3 across, 2 down)", target: self, action: #selector(choiceChanged(_:)))
        radioThree = NSButton(radioButtonWithTitle: "3 × 3   (9 videos)", target: self, action: #selector(choiceChanged(_:)))
        radioCustom = NSButton(radioButtonWithTitle: "Custom:", target: self, action: #selector(choiceChanged(_:)))

        let title = NSTextField(labelWithString: "How big a grid do you want?")
        title.font = .boldSystemFont(ofSize: 14)

        patternField.placeholderString = "e.g. XOO/XOO"
        patternField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        patternField.delegate = self
        patternField.widthAnchor.constraint(equalToConstant: 170).isActive = true

        examples.addItem(withTitle: "Examples")
        for p in Self.presets {
            examples.addItem(withTitle: "\(p.pattern)    \(p.label)")
            examples.lastItem?.representedObject = p.pattern
        }
        examples.target = self
        examples.action = #selector(exampleChosen(_:))

        let customRow = NSStackView(views: [radioCustom, patternField, examples])
        customRow.spacing = 6

        let help = NSTextField(wrappingLabelWithString:
            "Rows are separated by “/”. Each O is its own video. Repeat any other letter to make one bigger video: XOO/XOO puts one tall video on the left and four smaller ones beside it.")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 330
        help.widthAnchor.constraint(equalToConstant: 330).isActive = true

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed

        let left = NSStackView(views: [title, radioTwo, radioThreeTwo, radioThree, customRow, help, errorLabel])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 10
        left.setCustomSpacing(14, after: title)

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 200).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 125).isActive = true

        let top = NSStackView(views: [left, preview])
        top.alignment = .top
        top.spacing = 20

        let cancel = NSButton(title: asSheet ? "Cancel" : "Quit", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        openButton = NSButton(title: asSheet ? "Apply" : "Open", target: self, action: #selector(confirm(_:)))
        openButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, openButton])

        let root = NSStackView(views: [top, buttons])
        root.orientation = .vertical
        root.alignment = .trailing
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = root
        window.setContentSize(root.fittingSize)
    }

    // MARK: State

    private func restoreChoice() {
        let d = UserDefaults.standard
        patternField.stringValue = d.string(forKey: "customPattern") ?? "XOO/XOO"
        select(radio: { switch d.string(forKey: "layoutChoice") {
            case "three": return radioThree
            case "threeTwo": return radioThreeTwo
            case "custom": return radioCustom
            default: return radioTwo
        } }())
    }

    private func select(radio: NSButton) {
        for r in [radioTwo, radioThreeTwo, radioThree, radioCustom] { r?.state = (r === radio) ? .on : .off }
    }

    private func refresh() {
        errorLabel.stringValue = ""
        if radioTwo.state == .on {
            preview.layout = .twoByTwo
        } else if radioThreeTwo.state == .on {
            preview.layout = .threeByTwo
        } else if radioThree.state == .on {
            preview.layout = .threeByThree
        } else {
            do { preview.layout = try GridLayout.parse(patternField.stringValue) }
            catch let e as GridLayout.ParseError { preview.layout = nil; errorLabel.stringValue = e.message }
            catch { preview.layout = nil }
        }
        if let layout = preview.layout, radioCustom.state == .on {
            errorLabel.textColor = .secondaryLabelColor
            errorLabel.stringValue = "\(layout.tiles.count) videos"
        } else {
            errorLabel.textColor = .systemRed
        }
        openButton.isEnabled = preview.layout != nil
    }

    // MARK: Actions

    @objc private func choiceChanged(_ sender: NSButton) {
        select(radio: sender)
        refresh()
        if sender === radioCustom { window?.makeFirstResponder(patternField) }
    }

    func controlTextDidChange(_ obj: Notification) {
        select(radio: radioCustom)
        refresh()
    }

    @objc private func exampleChosen(_ sender: NSPopUpButton) {
        guard let pattern = sender.selectedItem?.representedObject as? String else { return }
        patternField.stringValue = pattern
        select(radio: radioCustom)
        refresh()
    }

    @objc private func confirm(_ sender: Any?) {
        guard let layout = preview.layout else { NSSound.beep(); return }
        let d = UserDefaults.standard
        let choice = radioThree.state == .on ? "three" : radioThreeTwo.state == .on ? "threeTwo"
            : radioCustom.state == .on ? "custom" : "two"
        d.set(choice, forKey: "layoutChoice")
        d.set(patternField.stringValue, forKey: "customPattern")
        completion(layout)
        dismiss()
    }

    @objc private func cancel(_ sender: Any?) { dismiss() }

    private func dismiss() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
    }
}
