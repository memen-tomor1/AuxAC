import CoreGraphics

/// 菜单栏面板的统一宽度。
///
/// ⚠️ **登录页与控制面板必须引用同一个宽度。**
///
/// 早先的写法是外层 `RootView` 统一套 `.frame(width: 340)`，而 `ControlView` 内部
/// 又写了 `.frame(width: 300)` —— 于是控制面板被**居中**塞进 340 宽的窗口里，
/// 左右各空出 20pt 的底色。用户报的「面板左右多余宽度」就是这个。
///
/// 现在两个界面各自引用这个常量，且 `RootView` 里**刻意不套**外层 frame。
///
/// 为什么要单独成一个文件：`AuxACApp.swift` 含有 `@main`，离屏预览渲染器
/// 编译时必须排除它（否则 `@main` 冲突）。常量若定义在那个文件里，
/// `ControlView`/`LoginView` 引用它就会编不过——共享类型一律放这里。
enum PanelMetrics {
    static let width: CGFloat = 300
}
