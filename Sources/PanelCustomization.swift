import AppKit

// 面板卡片布局模型与原位设置页：稳定卡片 ID + 顺序 + 显隐集合，JSON 存 UserDefaults。
// 仅显隐与纵向顺序；页头、footer、更新提示与凭据恢复区不参与配置。隐藏 ≠ 收起：隐藏的卡片仍照常获取数据。
enum PanelCardID: String, CaseIterable, Codable {
    case quota, resetCards, tibo, tokens, daily, quotaHistory, tools

    var title: String {
        switch self {
        case .quota: return "用量进度"
        case .resetCards: return "重置卡"
        case .tibo: return "Tibo 重置动态"
        case .tokens: return "用量情况"
        case .daily: return "用量简析"
        case .quotaHistory: return "额度周期回顾"
        case .tools: return "工具明细"
        }
    }
}

enum PanelCardMoveDirection {
    case up, down
}

struct PanelCardLayout: Equatable {
    static let defaultsKey = "panelCardLayoutV1"
    static let `default` = PanelCardLayout(order: PanelCardID.allCases, hidden: [])

    private(set) var order: [PanelCardID]
    private(set) var hidden: Set<PanelCardID>

    /// 规范化：剔除未知/重复项，缺失的卡片按默认次序补到末尾；隐藏集合只保留合法 ID。
    init(order: [PanelCardID], hidden: Set<PanelCardID> = []) {
        var seen = Set<PanelCardID>()
        var normalized: [PanelCardID] = []
        for id in order where !seen.contains(id) {
            normalized.append(id)
            seen.insert(id)
        }
        for id in PanelCardID.allCases where !seen.contains(id) {
            normalized.append(id)
        }
        self.order = normalized
        self.hidden = Set(hidden.filter { PanelCardID.allCases.contains($0) })
    }

    var visibleOrder: [PanelCardID] { order.filter { !hidden.contains($0) } }
    func isVisible(_ id: PanelCardID) -> Bool { !hidden.contains(id) }

    mutating func setVisible(_ visible: Bool, for id: PanelCardID) {
        if visible { hidden.remove(id) } else { hidden.insert(id) }
    }

    mutating func move(_ id: PanelCardID, direction: PanelCardMoveDirection) {
        guard let index = order.firstIndex(of: id) else { return }
        let target = direction == .up ? index - 1 : index + 1
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
    }

    // MARK: 持久化

    func encoded() -> Data? {
        let payload: [String: Any] = [
            "order": order.map(\.rawValue),
            "hidden": hidden.map(\.rawValue).sorted()
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    static func decoded(from data: Data) -> PanelCardLayout? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawOrder = payload["order"] as? [String] else { return nil }
        let order = rawOrder.compactMap(PanelCardID.init(rawValue:))
        // 未知 ID 直接判无效回退默认；缺卡片由 init 规范化补齐。
        guard order.count == rawOrder.count else { return nil }
        let hidden = Set((payload["hidden"] as? [String] ?? []).compactMap(PanelCardID.init(rawValue:)))
        return PanelCardLayout(order: order, hidden: hidden)
    }

    static func load(store: UserDefaults = .standard) -> PanelCardLayout {
        guard let data = store.data(forKey: defaultsKey), let layout = decoded(from: data) else { return .default }
        return layout
    }

    func save(store: UserDefaults = .standard) {
        guard let data = encoded() else { return }
        store.set(data, forKey: Self.defaultsKey)
    }
}

// 原位卡片设置页：显隐复选框 + 上/下排序按钮 + 恢复默认/完成。
// 修改即时更新内存并保存，不提供「取消」；关闭 Popover 退出设置页但保留已修改布局。
final class PanelCardSettingsView: NSView {
    private(set) var layout: PanelCardLayout
    var onChange: ((PanelCardLayout) -> Void)?
    var onFinish: (() -> Void)?
    private let rowsStack: NSStackView
    private var rows: [PanelCardID: (checkbox: NSButton, up: NSButton, down: NSButton)] = [:]
    private var finishButton: NSButton?
    private var backButton: NSButton?
    private var resetButton: NSButton?
    private var footerBackButton: NSButton?
    private var tagToID: [Int: PanelCardID] = [:]

    var initialKeyView: NSView { layout.order.first.flatMap { rows[$0]?.checkbox } ?? finishButton ?? NSView() }

    init(layout: PanelCardLayout) {
        self.layout = layout
        rowsStack = NSStackView()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        let back = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "返回面板") ?? NSImage(),
                            target: self, action: #selector(finishPressed))
        back.isBordered = false
        back.contentTintColor = .secondaryLabelColor
        back.setAccessibilityLabel("返回面板")
        backButton = back
        let title = NSTextField(labelWithString: "卡片显示与排序")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        header.addArrangedSubview(back)
        header.addArrangedSubview(title)
        PanelCardSettingsView.pinFullWidth(header, to: root)

        let hint = NSTextField(wrappingLabelWithString: "隐藏后仍照常获取数据；改动自动保存。")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        PanelCardSettingsView.pinFullWidth(hint, to: root)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        PanelCardSettingsView.pinFullWidth(rowsStack, to: root)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false
        let reset = NSButton(title: "恢复默认卡片布局", target: self, action: #selector(resetPressed))
        reset.setAccessibilityLabel("恢复默认卡片布局")
        resetButton = reset
        // 参考 GLM 卡片设置页：三个动作都用系统圆角按钮（bezelStyle .rounded），
        // 「完成」设为回车默认键——系统渲染成蓝色主按钮，一眼可辨主次（用户反馈：按钮要明显）。
        reset.bezelStyle = .rounded
        reset.controlSize = .regular
        let footerBack = NSButton(title: "返回", target: self, action: #selector(finishPressed))
        footerBack.bezelStyle = .rounded
        footerBack.controlSize = .regular
        footerBack.setAccessibilityLabel("返回")
        footerBackButton = footerBack
        let finish = NSButton(title: "完成", target: self, action: #selector(finishPressed))
        finish.keyEquivalent = "\r"
        finish.bezelStyle = .rounded
        finish.controlSize = .regular
        finish.setAccessibilityLabel("完成卡片设置")
        finishButton = finish
        footer.addArrangedSubview(reset)
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(footerBack)
        footer.addArrangedSubview(finish)
        PanelCardSettingsView.pinFullWidth(footer, to: root)

        rebuildRows()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func pinFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func rebuildRows() {
        for (_, row) in rows {
            row.checkbox.nextKeyView = nil
            row.up.nextKeyView = nil
            row.down.nextKeyView = nil
        }
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows = [:]
        var keyChain: [NSView] = []
        if let backButton = backButton { keyChain.append(backButton) }
        for (index, id) in layout.order.enumerated() {
            // 标题合并进复选框：点标题即切换显隐；隐藏项标题用次级色。
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleVisible(_:)))
            checkbox.font = .systemFont(ofSize: 11)
            checkbox.attributedTitle = NSAttributedString(string: id.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: layout.isVisible(id) ? NSColor.labelColor : NSColor.secondaryLabelColor
            ])
            checkbox.state = layout.isVisible(id) ? .on : .off
            checkbox.tag = index
            checkbox.setAccessibilityLabel("显示\(id.title)")
            let up = NSButton(title: "上移", target: self, action: #selector(moveRowUp(_:)))
            let down = NSButton(title: "下移", target: self, action: #selector(moveRowDown(_:)))
            for button in [up, down] {
                button.isBordered = false
                button.font = .systemFont(ofSize: 10)
                button.contentTintColor = .secondaryLabelColor
            }
            up.tag = index; down.tag = index
            up.setAccessibilityLabel("上移\(id.title)")
            down.setAccessibilityLabel("下移\(id.title)")
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 4
            row.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(checkbox)
            row.addArrangedSubview(NSView())
            row.addArrangedSubview(up)
            row.addArrangedSubview(down)
            Self.pinFullWidth(row, to: rowsStack)
            row.heightAnchor.constraint(equalToConstant: 26).isActive = true
            rows[id] = (checkbox, up, down)
            keyChain.append(contentsOf: [checkbox, up, down])
        }
        tagToID = layout.order.enumerated().reduce(into: [:]) { $0[$1.offset] = $1.element }
        refreshRowStates()
        // 键盘链：页头返回 → 逐行 复选框 → 上移 → 下移 → 恢复默认 → footer 返回 → 完成 → 回到页头返回。
        if let resetButton = resetButton { keyChain.append(resetButton) }
        if let footerBackButton = footerBackButton { keyChain.append(footerBackButton) }
        for (index, view) in keyChain.enumerated() {
            view.nextKeyView = index + 1 < keyChain.count ? keyChain[index + 1] : finishButton
        }
        if let finishButton = finishButton { finishButton.nextKeyView = keyChain.first }
    }

    private func refreshRowStates() {
        let order = layout.order
        for (index, id) in order.enumerated() {
            guard let row = rows[id] else { continue }
            let visible = layout.isVisible(id)
            row.checkbox.state = visible ? .on : .off
            row.checkbox.attributedTitle = NSAttributedString(string: id.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: visible ? NSColor.labelColor : NSColor.secondaryLabelColor
            ])
            row.up.isEnabled = index > 0
            row.down.isEnabled = index < order.count - 1
        }
    }

    @objc private func toggleVisible(_ sender: NSButton) {
        guard let id = tagToID[sender.tag] else { return }
        layout.setVisible(sender.state == .on, for: id)
        refreshRowStates()
        onChange?(layout)
    }

    // 命名避开 NSResponder 的 moveUp:/moveDown:，否则 #selector 二义。
    @objc private func moveRowUp(_ sender: NSButton) { move(idForTag(sender.tag), direction: .up, sender: sender) }
    @objc private func moveRowDown(_ sender: NSButton) { move(idForTag(sender.tag), direction: .down, sender: sender) }

    private func idForTag(_ tag: Int) -> PanelCardID? { tagToID[tag] }

    private func move(_ id: PanelCardID?, direction: PanelCardMoveDirection, sender: NSButton) {
        guard let id = id else { return }
        layout.move(id, direction: direction)
        // 重排行后按 id 找到重建出的同名按钮恢复焦点（旧实例已离窗，不能做身份比较），
        // 连续按上/下不需要重新点选。
        rebuildRows()
        if let row = rows[id], let window = row.up.window {
            window.makeFirstResponder(direction == .up ? row.up : row.down)
        }
        onChange?(layout)
    }

    @objc private func resetPressed() {
        layout = .default
        rebuildRows()
        onChange?(layout)
    }

    @objc private func finishPressed() { onFinish?() }
}
