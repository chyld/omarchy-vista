import QtQuick
import QtQuick.Shapes
import qs.Commons

// The Vista mark: the switcher in miniature. A screen
// with two chamfered corners (the large preview) over a filmstrip of four
// workspaces, one lit in the accent colour with the selection bar under it.
//
// Drawn on a 16-unit grid and scaled as vectors, so it stays sharp from the
// 16px bar slot up to large sizes.
Item {
  id: logo

  property color color: Color.foreground
  property color accent: Color.accent
  readonly property int lit: 1

  implicitWidth: 16
  implicitHeight: 16

  Item {
    id: grid
    width: 16
    height: 16
    scale: Math.min(logo.width, logo.height) / 16
    transformOrigin: Item.TopLeft
    x: (logo.width - 16 * scale) / 2
    y: (logo.height - 16 * scale) / 2

    // Screen: chamfered top-left and bottom-right corners.
    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeColor: logo.color
        strokeWidth: 1.3
        fillColor: Util.alpha(logo.color, 0.14)
        joinStyle: ShapePath.MiterJoin
        startX: 3.6; startY: 1.2
        PathLine { x: 14.8; y: 1.2 }
        PathLine { x: 14.8; y: 6.8 }
        PathLine { x: 12.4; y: 9.2 }
        PathLine { x: 1.2; y: 9.2 }
        PathLine { x: 1.2; y: 3.6 }
        PathLine { x: 3.6; y: 1.2 }
      }
    }

    // Filmstrip: four workspaces, one lit.
    Repeater {
      model: 4

      Rectangle {
        required property int index
        readonly property bool on: index === logo.lit

        x: 1.2 + index * 3.75
        y: 10.9
        width: 2.4
        height: 2.4
        radius: 0.3
        color: on ? logo.accent : "transparent"
        border.width: on ? 0 : 0.8
        border.color: Util.alpha(logo.color, 0.6)
      }
    }

    Rectangle {
      x: 1.2 + logo.lit * 3.75
      y: 14.2
      width: 2.4
      height: 0.9
      radius: 0.45
      color: logo.accent
    }
  }
}
