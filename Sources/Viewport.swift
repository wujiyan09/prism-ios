import SwiftUI
import UIKit
import PDFKit

// MARK: - Shared viewport control for writing surfaces (scratch, notes, PDF, 手写板):
// page indicator + jump, zoom % + zoom lock, ⌘-scroll / ⌘± zoom.

extension Notification.Name {
    /// userInfo["step"]: 1 = zoom in, -1 = zoom out, 0 = 100 %.
    static let canvasZoom = Notification.Name("canvasZoom")
    /// object = doc key; zoom lock changed in another window.
    static let zoomLockChanged = Notification.Name("zoomLockChanged")
}

enum ZoomLock {
    static func get(_ key: String) -> Bool { !key.isEmpty && UserDefaults.standard.bool(forKey: "zoomlock." + key) }
    static func set(_ key: String, _ on: Bool) {
        guard !key.isEmpty else { return }
        UserDefaults.standard.set(on, forKey: "zoomlock." + key)
        NotificationCenter.default.post(name: .zoomLockChanged, object: key)
    }
}

@Observable
final class ViewCtl {
    /// Zoom relative to fit (1 = 100 %).
    var zoom: CGFloat = 1
    var page = 0
    var count = 1
    var locked = false
    var key = ""
    @ObservationIgnored var setZoom: ((CGFloat) -> Void)?
    @ObservationIgnored var goPage: ((Int) -> Void)?
    @ObservationIgnored var applyLock: ((Bool) -> Void)?
    @ObservationIgnored var thumb: ((Int) -> UIImage?)?
    @ObservationIgnored private var obs: [NSObjectProtocol] = []
    /// Window of the view this controller drives (⌘± only applies in the key window).
    @ObservationIgnored weak var view: UIView?

    init() {
        let nc = NotificationCenter.default
        obs.append(nc.addObserver(forName: .canvasZoom, object: nil, queue: .main) { [weak self] n in
            guard let self, let v = self.view, v.window?.isKeyWindow == true, !self.locked else { return }
            let s = n.userInfo?["step"] as? Int ?? 0
            self.setZoom?(s == 0 ? 1 : min(4, max(0.5, self.zoom * (s > 0 ? 1.25 : 0.8))))
        })
        obs.append(nc.addObserver(forName: .zoomLockChanged, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? String) == self.key else { return }
            let l = ZoomLock.get(self.key)
            if l != self.locked { self.locked = l; self.applyLock?(l) }
        })
    }
    deinit { obs.forEach(NotificationCenter.default.removeObserver) }

    func bind(key k: String) {
        key = k
        locked = ZoomLock.get(k)
        applyLock?(locked)
    }
    func toggleLock() {
        locked.toggle(); applyLock?(locked); ZoomLock.set(key, locked)
    }
    func report(zoom z: CGFloat) { if abs(zoom - z) > 0.005 { zoom = z } }
    func report(page p: Int, of n: Int) {
        if page != p { page = p }
        if count != n { count = max(1, n) }
    }
}

/// Top-right floating glass: 「n / N」(tap = jump) · zoom % (tap = 100 %) · zoom lock.
struct ViewHUD: View {
    @Bindable var ctl: ViewCtl
    var showPages = true
    @State private var jump = false

    var body: some View {
        let row = HStack(spacing: 2) {
            if showPages && ctl.count > 1 {
                Button { jump = true } label: {
                    Text("\(ctl.page + 1) / \(ctl.count)").font(.subheadline.monospacedDigit()).lineLimit(1).fixedSize(horizontal: true, vertical: false).padding(.horizontal, 6)
                }
                .popover(isPresented: $jump) { PageJump(ctl: ctl, done: { jump = false }) }
                .accessibilityLabel("第 \(ctl.page + 1) 页，共 \(ctl.count) 页，跳页")
            }
            if abs(ctl.zoom - 1) > 0.01 || ctl.locked {
                Button { if !ctl.locked { ctl.setZoom?(1) } } label: {
                    Text("\(Int((ctl.zoom * 100).rounded()))%").font(.subheadline.monospacedDigit()).padding(.horizontal, 4)
                }
                .disabled(ctl.locked)
            }
            Button { ctl.toggleLock() } label: {
                Image(systemName: ctl.locked ? "lock.fill" : "lock.open").font(.subheadline)
            }
            .accessibilityLabel(ctl.locked ? "解锁缩放" : "锁定缩放")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(.horizontal, 8).frame(minHeight: 36)
        Group {
            if #available(iOS 26.0, *) { row.glassEffect(.regular.interactive(), in: .capsule) }
            else { row.background(.regularMaterial, in: Capsule()) }
        }
        .padding(10)
    }
}

struct PageJump: View {
    let ctl: ViewCtl
    let done: () -> Void
    @State private var n = 1
    @State private var field = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("页码", text: $field).keyboardType(.numberPad).textFieldStyle(.roundedBorder).frame(width: 56)
                    .onSubmit(go)
                Stepper(value: $n, in: 1...max(1, ctl.count)) {
                    Text("第 \(n) / \(ctl.count) 页").font(.body.monospacedDigit()).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                    .onChange(of: n) { _, v in field = "\(v)" }
                Button("前往", action: go).buttonStyle(.borderedProminent)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(0..<ctl.count, id: \.self) { i in
                            Button { n = i + 1; go() } label: { PageThumb(ctl: ctl, i: i, current: i == ctl.page) }
                                .buttonStyle(.plain).id(i)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear { proxy.scrollTo(ctl.page, anchor: .center) }
            }
        }
        .padding()
        .frame(width: 340, height: 460)
        .onAppear { n = ctl.page + 1; field = "\(n)" }
    }

    private func go() {
        let v = Int(field) ?? n
        ctl.goPage?(min(max(1, v), ctl.count) - 1)
        done()
    }
}

private struct PageThumb: View {
    let ctl: ViewCtl
    let i: Int
    let current: Bool
    @State private var img: UIImage?
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img { Image(uiImage: img).resizable().aspectRatio(contentMode: .fit) }
                else { Rectangle().fill(Color.secondary.opacity(0.12)) }
            }
            .frame(width: 90, height: 120)
            .background(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(current ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: current ? 2 : 0.5))
            Text("第 \(i + 1) 页").font(.body.monospacedDigit())
            Spacer()
        }
        .contentShape(Rectangle())
        .task { if img == nil { img = ctl.thumb?(i) } }
    }
}

// MARK: ⌘ + scroll wheel / trackpad scroll → zoom around the pointer.

final class CmdZoom: NSObject, UIGestureRecognizerDelegate {
    /// (scale factor, pointer location in the gesture view)
    let apply: (CGFloat, CGPoint) -> Void
    let blocked: () -> Bool
    private var last: CGFloat = 0
    init(apply: @escaping (CGFloat, CGPoint) -> Void, blocked: @escaping () -> Bool) { self.apply = apply; self.blocked = blocked }

    static func install(on v: UIView, apply: @escaping (CGFloat, CGPoint) -> Void, blocked: @escaping () -> Bool = { false }) -> CmdZoom {
        let z = CmdZoom(apply: apply, blocked: blocked)
        let g = UIPanGestureRecognizer(target: z, action: #selector(pan(_:)))
        g.allowedScrollTypesMask = .all
        g.allowedTouchTypes = []          // pointer scroll only, never touches
        g.delegate = z
        v.addGestureRecognizer(g)
        return z
    }
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { g.modifierFlags.contains(.command) && !blocked() }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { false }
    @objc func pan(_ g: UIPanGestureRecognizer) {
        guard let v = g.view else { return }
        let y = g.translation(in: v).y
        switch g.state {
        case .began: last = 0
        case .changed:
            let d = y - last; last = y
            apply(exp(d / 300), g.location(in: v))
        default: break
        }
    }
}

extension UIScrollView {
    /// Zoom by k keeping the content point under p (in self coordinates) fixed.
    func zoom(by k: CGFloat, at p: CGPoint) {
        let old = zoomScale
        let z = min(maximumZoomScale, max(minimumZoomScale, old * k))
        guard abs(z - old) > 0.0001 else { return }
        let content = CGPoint(x: p.x / old, y: p.y / old)
        let screen = CGPoint(x: p.x - contentOffset.x, y: p.y - contentOffset.y)
        zoomScale = z
        var o = CGPoint(x: content.x * z - screen.x, y: content.y * z - screen.y)
        o.x = min(max(-contentInset.left, o.x), max(-contentInset.left, contentSize.width - bounds.width + contentInset.right))
        o.y = min(max(-contentInset.top, o.y), max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom))
        contentOffset = o
    }
}

struct ZoomCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("放大") { NotificationCenter.default.post(name: .canvasZoom, object: nil, userInfo: ["step": 1]) }
                .keyboardShortcut("+", modifiers: .command)
            Button("缩小") { NotificationCenter.default.post(name: .canvasZoom, object: nil, userInfo: ["step": -1]) }
                .keyboardShortcut("-", modifiers: .command)
            Button("实际大小") { NotificationCenter.default.post(name: .canvasZoom, object: nil, userInfo: ["step": 0]) }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
