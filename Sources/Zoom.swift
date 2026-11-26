import SwiftUI
import UIKit

/// Native UIScrollView zooming around SwiftUI content: pinch-anchored, no re-layout during the gesture,
/// content centred (and sideways sliding locked) when it is narrower/shorter than the view.
struct ZoomScroll<Content: View>: UIViewRepresentable {
    let size: CGSize                 // unscaled content size
    @Binding var zoom: CGFloat
    @Binding var jump: CGFloat?      // unscaled y to bring to the top
    var onScroll: (CGFloat) -> Void  // unscaled y at the view's centre
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.minimumZoomScale = 0.5
        sv.maximumZoomScale = 4
        sv.bouncesZoom = true
        sv.alwaysBounceVertical = true
        sv.contentInsetAdjustmentBehavior = .never
        sv.backgroundColor = .clear
        sv.delegate = context.coordinator
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.view.frame = CGRect(origin: .zero, size: size)
        sv.addSubview(host.view)
        sv.contentSize = size
        context.coordinator.host = host
        context.coordinator.parent = self
        context.coordinator.size = size
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.host?.rootView = content()
        if c.size != size, let hv = c.host?.view {
            c.size = size
            let z = sv.zoomScale
            hv.bounds = CGRect(origin: .zero, size: size)
            sv.contentSize = CGSize(width: size.width * z, height: size.height * z)
            hv.center = CGPoint(x: sv.contentSize.width / 2, y: sv.contentSize.height / 2)
        }
        if !sv.isZooming && !sv.isZoomBouncing && abs(sv.zoomScale - zoom) > 0.001 { sv.setZoomScale(zoom, animated: true) }
        if let y = jump {
            DispatchQueue.main.async {
                let maxY = max(-sv.contentInset.top, sv.contentSize.height - sv.bounds.height + sv.contentInset.bottom)
                sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: min(maxY, y * sv.zoomScale)), animated: false)
                jump = nil
            }
        }
        DispatchQueue.main.async { c.center(sv) }
    }

    final class Coord: NSObject, UIScrollViewDelegate {
        var parent: ZoomScroll?
        var host: UIHostingController<Content>?
        var size: CGSize = .zero

        func viewForZooming(in s: UIScrollView) -> UIView? { host?.view }
        func scrollViewDidZoom(_ s: UIScrollView) { center(s) }
        func scrollViewDidEndZooming(_ s: UIScrollView, with v: UIView?, atScale z: CGFloat) {
            if let p = parent, abs(p.zoom - z) > 0.001 { p.zoom = z }
            sharpen(v, z)
        }
        func scrollViewDidScroll(_ s: UIScrollView) {
            guard !s.isZooming, s.zoomScale > 0 else { return }
            parent?.onScroll((s.contentOffset.y + s.bounds.height / 2) / s.zoomScale)
        }
        func center(_ s: UIScrollView) {
            let ix = max(0, (s.bounds.width - s.contentSize.width) / 2)
            let iy = max(0, (s.bounds.height - s.contentSize.height) / 2)
            let inset = UIEdgeInsets(top: iy, left: ix, bottom: iy, right: ix)
            if s.contentInset != inset { s.contentInset = inset }
            s.alwaysBounceHorizontal = s.contentSize.width > s.bounds.width + 1
            if ix > 0 && abs(s.contentOffset.x + ix) > 0.5 { s.contentOffset.x = -ix }
        }
        /// Re-render ink at the new scale so strokes stay sharp after zooming in.
        private func sharpen(_ v: UIView?, _ z: CGFloat) {
            guard let v else { return }
            let scale = min(UIScreen.main.scale * max(1, z), 8)
            func walk(_ x: UIView) {
                if String(describing: type(of: x)).contains("Canvas") { x.contentScaleFactor = scale }
                x.subviews.forEach(walk)
            }
            walk(v)
        }
    }
}
