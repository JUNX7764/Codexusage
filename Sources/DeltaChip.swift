import AppKit

// 环比数值的 soft chip：方向配色由调用方传入，胶囊本身不理解额度或比较业务。
// 窄面板时由容器决定两行回退，数字永远不截断。
final class PanelDeltaChip: NSView {
    let valueLabel: NSTextField
    private let foreground: NSColor

    static func size(for text: String, font: NSFont) -> NSSize {
        NSSize(width: ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12, height: 20)
    }

    /// 单行容量判断：说明文字 + 间距 + 胶囊超出半行宽度时需要两行回退。
    static func requiresTwoRows(halfWidth: CGFloat, captionWidth: CGFloat, chipWidth: CGFloat) -> Bool {
        captionWidth + 4 + chipWidth > halfWidth
    }

    init(text: String, foreground: NSColor) {
        self.foreground = foreground
        valueLabel = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        valueLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        valueLabel.textColor = foreground
        valueLabel.maximumNumberOfLines = 1
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        // 数值语义由说明文字的 accessibilityValue 携带，胶囊是装饰，避免 VoiceOver 重复朗读。
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        Self.size(for: valueLabel.stringValue, font: valueLabel.font!)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.backgroundColor = foreground.withAlphaComponent(dark ? 0.16 : 0.10).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
