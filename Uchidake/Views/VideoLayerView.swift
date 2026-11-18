import AVFoundation
import SwiftUI

/// AVSampleBufferDisplayLayer を SwiftUI に載せるための入れ物。
struct VideoLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.host(layer)
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.host(layer)
    }

    final class HostView: UIView {
        private weak var hosted: CALayer?

        func host(_ newLayer: CALayer) {
            guard hosted !== newLayer else { return }
            hosted?.removeFromSuperlayer()
            layer.addSublayer(newLayer)
            hosted = newLayer
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // 大きさの変化にアニメーションを付けない（映像がふわっと動いて見えるのを防ぐ）
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}
