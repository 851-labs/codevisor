import CodevisorCoreMac
import SwiftUI

struct PiPResizeHandles: View {
  let size: CGSize
  let coordinateSpace: String
  let onChanged: (ComputerUseLivePreviewResizeHandle, CGSize) -> Void
  let onEnded: () -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(ComputerUseLivePreviewResizeHandle.allCases, id: \.self) { handle in
        let zone = handle.zone(in: size)
        Color.clear
          .contentShape(Rectangle())
          .frame(width: zone.width, height: zone.height)
          .offset(x: zone.minX, y: zone.minY)
          .pointerStyle(.frameResize(position: handle.framePosition))
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace))
              .onChanged { value in onChanged(handle, value.translation) }
              .onEnded { _ in onEnded() }
          )
          .accessibilityHidden(true)
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
  }
}

extension ComputerUseLivePreviewResizeHandle {
  private static let edgeThickness: CGFloat = 6
  private static let cornerLength: CGFloat = 14

  fileprivate func zone(in size: CGSize) -> CGRect {
    let edge = Self.edgeThickness
    let corner = Self.cornerLength
    let horizontalEdge = max(0, size.width - corner * 2)
    let verticalEdge = max(0, size.height - corner * 2)
    switch self {
    case .top: return CGRect(x: corner, y: 0, width: horizontalEdge, height: edge)
    case .bottom: return CGRect(x: corner, y: size.height - edge, width: horizontalEdge, height: edge)
    case .leading: return CGRect(x: 0, y: corner, width: edge, height: verticalEdge)
    case .trailing: return CGRect(x: size.width - edge, y: corner, width: edge, height: verticalEdge)
    case .topLeading: return CGRect(x: 0, y: 0, width: corner, height: corner)
    case .topTrailing: return CGRect(x: size.width - corner, y: 0, width: corner, height: corner)
    case .bottomLeading: return CGRect(x: 0, y: size.height - corner, width: corner, height: corner)
    case .bottomTrailing:
      return CGRect(x: size.width - corner, y: size.height - corner, width: corner, height: corner)
    }
  }

  fileprivate var framePosition: FrameResizePosition {
    switch self {
    case .top: .top
    case .bottom: .bottom
    case .leading: .leading
    case .trailing: .trailing
    case .topLeading: .topLeading
    case .topTrailing: .topTrailing
    case .bottomLeading: .bottomLeading
    case .bottomTrailing: .bottomTrailing
    }
  }
}
