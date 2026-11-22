import AppKit

// 悬停显示状态面板：几何/时序纯逻辑 + 控制器（移植自 GlmUsage 同名特性，机制参照 Status Trio issue #355）。
// 图标与面板各挂 NSTrackingArea，边界进出驱动 0.2s 驻留开 / 0.30s 延迟收；
// 图标-面板间 8pt 桥区计入保持区；hover 打开的面板首次点击转常开（pin）。
// 纯逻辑与 AppKit 控制器分离，便于 --self-test 离线断言；控制器只依赖注入的
// 状态读取与动作闭包，测试可整体替换（固定矩形/固定指针位置）做确定性时序验证。

// MARK: - 纯逻辑（可离线测试）

/// hover 组几何：图标矩形 + 面板矩形（含桥区宽容）。
/// 边界判定必须含 maxX/maxY：`NSRect.contains` 是半开的，菜单栏图标小、
/// 悬停与点击常落在边缘像素（Status Trio issue #224 的实测教训）。
struct PanelHoverGeometry: Equatable {
    static let bridgeInset: CGFloat = 8
    let statusItemFrame: NSRect?
    var panelFrames: [NSRect]

    init(statusItemFrame: NSRect?, panelFrames: [NSRect] = []) {
        self.statusItemFrame = statusItemFrame
        self.panelFrames = panelFrames
    }

    func containsStatusItem(_ point: NSPoint) -> Bool {
        statusItemFrame.map { Self.containsInclusive($0, point) } ?? false
    }

    func containsPanel(_ point: NSPoint) -> Bool {
        panelFrames.contains { Self.containsInclusive($0, point) }
    }

    /// 图标、任一面板或二者间的桥区：区内指针不得触发延迟收起。
    /// 桥区只放宽 keep-open，不放宽打开（离开图标向下滑入桥区不会凭空开面板）。
    func isWithinHoverArea(_ point: NSPoint) -> Bool {
        if containsStatusItem(point) || containsPanel(point) { return true }
        if let item = statusItemFrame,
           Self.containsInclusive(item.insetBy(dx: -Self.bridgeInset, dy: -Self.bridgeInset), point) {
            return true
        }
        return panelFrames.contains {
            Self.containsInclusive($0.insetBy(dx: -Self.bridgeInset, dy: -Self.bridgeInset), point)
        }
    }

    static func containsInclusive(_ rect: NSRect, _ point: NSPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }
}

/// 悬停打开后图标点击的处置（决策矩阵，--self-test 覆盖）。
enum PanelHoverClickOutcome: Equatable {
    case present   // 未打开 → 打开
    case pin       // hover 打开中 → 转常开（不关闭，移开鼠标不再自动收）
    case close     // 普通常开 → 关闭
}

func panelHoverClickOutcome(isShown: Bool, presentedByHover: Bool) -> PanelHoverClickOutcome {
    if !isShown { return .present }
    return presentedByHover ? .pin : .close
}

/// 延迟转换簿记：新转换顶替旧转换；定时器凭 token 生效，陈旧/被顶替/已取消的触发被丢弃。
struct PanelHoverIntent: Equatable {
    enum Transition: Equatable { case show, hide }

    private(set) var pending: Transition?
    private var token = 0

    mutating func begin(_ transition: Transition) -> Int {
        token &+= 1
        pending = transition
        return token
    }

    @discardableResult
    mutating func cancel() -> Bool {
        guard pending != nil else { return false }
        pending = nil
        token &+= 1
        return true
    }

    /// 定时器触发时凭 token 认领：成功即清空 pending，重复触发不再生效。
    mutating func consume(_ candidate: Int) -> Bool {
        guard pending != nil, candidate == token else { return false }
        pending = nil
        token &+= 1
        return true
    }
}

/// 偏好：默认开启（产品决策）；store 参数便于自检注入独立 suite，不碰生产偏好。
enum PanelHoverPreference {
    static let defaultsKey = "panel.hoverOpen.enabled"

    static func load(from store: UserDefaults = .standard) -> Bool {
        guard store.object(forKey: defaultsKey) != nil else { return true }
        return store.bool(forKey: defaultsKey)
    }

    static func save(_ value: Bool, to store: UserDefaults = .standard) {
        store.set(value, forKey: defaultsKey)
    }
}

// MARK: - 控制器

/// NSTrackingArea 事件的 NSResponder 转发包装，图标与面板共用一份实现。
/// 主线程专用（与全库惯例一致：AppKit 交互类不做显式 actor 标注）。
final class PanelHoverTracking: NSResponder {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private(set) weak var view: NSView?
    private var area: NSTrackingArea?

    init(view: NSView) {
        self.view = view
        super.init()
        // activeAlways：菜单栏与面板不在 key window 时仍响应悬停；
        // inVisibleRect：图标按钮换图/面板内容变高后自动跟随可视区域。
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        view.addTrackingArea(area)
        self.area = area
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PanelHoverTracking 不支持 NSCoding") }

    func invalidate() {
        if let area, let view { view.removeTrackingArea(area) }
        area = nil
        view = nil
        onEnter = nil
        onExit = nil
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// 悬停开合控制器。只用 tracking area 边界事件，不装 mouseMoved 轮询；
/// v1 不支持多显示器镜像图标的悬停（镜像无真实 view）。
/// 面板关闭后面板 tracking 保留在复用的内容视图上（无窗口时不触发）。
/// 主线程专用（与全库惯例一致：AppKit 交互类不做显式 actor 标注）。
final class PanelHoverController {
    static let showDelay: TimeInterval = 0.2
    static let hideDelay: TimeInterval = 0.30

    // 以下闭包由宿主注入；测试可整体替换为固定值
    var isPanelShown: () -> Bool = { false }
    var presentedByHover: () -> Bool = { false }
    var statusItemFrame: () -> NSRect? = { nil }
    var panelFrame: () -> NSRect? = { nil }
    var panelView: () -> NSView? = { nil }
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    var performShow: () -> Void = {}
    var performHide: () -> Void = {}

    private(set) var isEnabled = false
    private var intent = PanelHoverIntent()
    private var pendingWork: DispatchWorkItem?
    private var iconTracking: PanelHoverTracking?
    private var panelTracking: PanelHoverTracking?
    private weak var iconView: NSView?

    init(iconView: NSView?) {
        self.iconView = iconView
    }

    // MARK: 开关与安装

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            installIconTracking()
        } else {
            cancelPending()
            removeIconTracking()
            removePanelTracking()
            // 关闭开关时收起仍处于 hover 呈现的面板；已 pin 的常开面板不动
            if isPanelShown(), presentedByHover() { performHide() }
        }
    }

    private func installIconTracking() {
        guard iconTracking == nil, let view = iconView else { return }
        let tracking = PanelHoverTracking(view: view)
        tracking.onEnter = { [weak self] in self?.iconEntered() }
        tracking.onExit = { [weak self] in self?.iconExited() }
        iconTracking = tracking
    }

    private func removeIconTracking() {
        iconTracking?.invalidate()
        iconTracking = nil
    }

    /// 面板打开后挂面板 tracking（内容视图跨开合复用，装一次即可）。
    func installPanelTrackingIfNeeded() {
        guard panelTracking == nil, let view = panelView() else { return }
        let tracking = PanelHoverTracking(view: view)
        tracking.onEnter = { [weak self] in self?.panelEntered() }
        tracking.onExit = { [weak self] in self?.panelExited() }
        panelTracking = tracking
    }

    private func removePanelTracking() {
        panelTracking?.invalidate()
        panelTracking = nil
    }

    /// 面板已关闭：丢弃未决转换（真实的鼠标退出事件由 isPanelShown 守卫吞掉）。
    func panelDidClose() {
        cancelPending()
    }

    /// 测试专用：断开真实 tracking 事件，时序回归由合成调用直接驱动状态机，
    /// 不受真实光标位置/移动的扰动（真实鼠标路径属于人工验收范围）。
    func detachTrackingForTesting() {
        removeIconTracking()
        removePanelTracking()
        cancelPending()
    }

    // MARK: tracking 事件入口

    func iconEntered() {
        guard isEnabled else { return }
        cancelPending()
        guard !isPanelShown() else { return }
        schedule(.show)
    }

    func iconExited() {
        guard isEnabled else { return }
        guard isPanelShown() else {
            cancelPending()   // 驻留未满即离开，取消打开
            return
        }
        guard presentedByHover() else { return }   // 已 pin 的常开面板：离开图标不收
        schedule(.hide)
    }

    func panelEntered() {
        guard isEnabled else { return }
        cancelPending()
    }

    func panelExited() {
        guard isEnabled else { return }
        guard isPanelShown(), presentedByHover() else { return }
        schedule(.hide)
    }

    // MARK: 延迟转换

    func cancelPending() {
        intent.cancel()
        pendingWork?.cancel()
        pendingWork = nil
    }

    private func schedule(_ transition: PanelHoverIntent.Transition) {
        cancelPending()
        let token = intent.begin(transition)
        let delay = transition == .show ? Self.showDelay : Self.hideDelay
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.intent.consume(token) else { return }
            switch transition {
            case .show: self.fireShow()
            case .hide: self.fireHide()
            }
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fireShow() {
        guard isEnabled, !isPanelShown() else { return }
        // 驻留期间指针可能已移走：仅在仍悬停于图标上时才打开
        guard let frame = statusItemFrame(),
              PanelHoverGeometry.containsInclusive(frame, pointerLocation()) else { return }
        performShow()
    }

    private func fireHide() {
        guard isEnabled, isPanelShown(), presentedByHover() else { return }
        // 面板内拖拽滑块/按钮或 `···` 菜单跟踪期间指针在面板外是正常交互，挂起重判
        if NSEvent.pressedMouseButtons != 0 || RunLoop.current.currentMode == .eventTracking {
            schedule(.hide)
            return
        }
        let geometry = PanelHoverGeometry(statusItemFrame: statusItemFrame(),
                                          panelFrames: [panelFrame()].compactMap { $0 })
        let point = pointerLocation()
        if geometry.containsPanel(point) { return }   // 指针在面板内但无事件（异常态）：保持打开，不空转重排
        if geometry.isWithinHoverArea(point) {
            schedule(.hide)   // 仍在桥区/图标上：继续重判；移入面板或图标由 tracking 事件取消
            return
        }
        performHide()
    }
}
