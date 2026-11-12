import AppKit
import SwiftUI

/// 上に向かって開くメニューの項目
enum PopUpItem {
    case entry(String, checked: Bool = false, enabled: Bool = true, action: () -> Void)
    case separator
}

/// 上に向かって開くメニュー。ウィンドウの下端に置くボタン用。
/// SwiftUI の Menu は下に開くので、下端に置くと中身が画面の外へ出てしまう。
struct UpwardMenu<Label: View>: View {
    /// 読み上げの名前
    let name: String
    /// 開くたびに呼ぶ（つながっているマイクなど、その時点の状態で中身を作る）
    let items: @MainActor () -> [PopUpItem]
    let label: Label

    init(name: String, items: @escaping @MainActor () -> [PopUpItem], @ViewBuilder label: () -> Label) {
        self.name = name
        self.items = items
        self.label = label()
    }

    var body: some View {
        label
            .contentShape(Rectangle())
            .overlay { MenuArea(name: name, items: items) }
    }
}

/// ラベルに重ねる透明なビュー。押されたら NSMenu を上向きに出す
private struct MenuArea: NSViewRepresentable {
    let name: String
    let items: @MainActor () -> [PopUpItem]

    func makeNSView(context: Context) -> AreaView { AreaView() }

    func updateNSView(_ view: AreaView, context: Context) {
        view.items = items
        view.setAccessibilityLabel(name)
        // SwiftUI の .disabled は素の NSView には効かないので、自分で見る
        view.isEnabled = context.environment.isEnabled
    }
}

private final class AreaView: NSView {
    var items: @MainActor () -> [PopUpItem] = { [] }
    var isEnabled = true
    private var actions: [() -> Void] = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        showMenu()
    }

    // キーボード操作と読み上げからも開けるようにする
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }

    private func showMenu() {
        guard isEnabled else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        actions = []
        for item in items() {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .entry(let title, let checked, let enabled, let action):
                let menuItem = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.tag = actions.count
                menuItem.state = checked ? .on : .off
                menuItem.isEnabled = enabled
                actions.append(action)
                menu.addItem(menuItem)
            }
        }
        // メニューの左上を「自分の上辺 ＋ メニューの高さ」に置くと、最後の項目がちょうど自分の上に乗る。
        // 画面の上端にぶつかるときは macOS がずらす
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + menu.size.height), in: self)
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}
