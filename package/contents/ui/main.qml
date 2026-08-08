import QtQuick
import QtQuick.Layouts
import QtQml
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    readonly property string helper: "python3 '" + Qt.resolvedUrl("../code/outputs.py").toString().replace(/^file:\/\//, "") + "'"
    readonly property string overlayScript: Qt.resolvedUrl("../code/overlay-x11.py").toString().replace(/^file:\/\//, "")

    // outputs: merged Qt geometry + kscreen brightness/priority, keyed by name
    property var outputs: []
    // blanked: name -> brightness (percent) to restore to. Presence == blacked out.
    property var blanked: ({})
    property string loadError: ""
    property int execSeq: 0

    readonly property int blankedCount: Object.keys(blanked).length

    Plasmoid.icon: "video-display"
    toolTipMainText: "Monitor Blackout"
    toolTipSubText: blankedCount === 0
        ? "All screens on"
        : (blankedCount + (blankedCount === 1 ? " screen" : " screens") + " blacked out — click to restore")

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: "Black out all but primary"
            icon.name: "video-display"
            onTriggered: root.blankOthers()
        },
        PlasmaCore.Action {
            text: "Restore all screens"
            icon.name: "edit-undo"
            enabled: root.blankedCount > 0
            onTriggered: root.restoreAll()
        }
    ]

    // ---------- shell out (kscreen-doctor + the outputs helper) ----------
    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            if (sourceName.indexOf("outputs.py") === -1) return   // fire-and-forget setter
            try {
                var p = JSON.parse(data["stdout"])
                if (p.error) { root.loadError = p.error; return }
                root.mergeOutputs(p.outputs)
                root.reconcile(p.overlays || [])
                root.loadError = ""
            } catch (e) {
                root.loadError = "parse"
            }
        }
        // Distinct source name per run: reconnecting an identical source is a
        // no-op, which would silently swallow repeat commands. The counter wraps
        // because Plasma5Support keeps source names in an append-only
        // QQmlOpenMetaObject and rebuilds the whole metaobject on every
        // connect/disconnect — an unbounded counter makes each run cost O(runs so
        // far). This widget only runs on demand, so it never got as bad as the
        // 3 s pollers, but the growth is the same shape.
        function run(cmd) {
            root.execSeq = (root.execSeq + 1) % 8
            connectSource(cmd + " # " + root.execSeq)
        }
    }

    function refreshOutputs() { exec.run(root.helper) }

    function mergeOutputs(fromKscreen) {
        var byName = {}
        for (var i = 0; i < fromKscreen.length; ++i) byName[fromKscreen[i].name] = fromKscreen[i]

        var screens = Qt.application.screens
        var arr = []
        for (var j = 0; j < screens.length; ++j) {
            var s = screens[j]
            var k = byName[s.name] || {}
            arr.push({
                name: s.name,
                screen: s,
                x: s.virtualX, y: s.virtualY,
                w: s.width, h: s.height,
                priority: k.priority !== undefined ? k.priority : 99,
                brightness: k.brightness !== undefined ? k.brightness : null
            })
        }
        root.outputs = arr
    }

    function isPrimary(o) { return o.priority === 1 }

    // ---------- blackout ----------
    function isBlanked(name) { return root.blanked[name] !== undefined }

    function blank(name) {
        if (isBlanked(name)) return
        var o = outputFor(name)
        if (!o) return

        // Remember the level to come back to before we stamp on it.
        var saved = (o.brightness !== null && o.brightness > 0) ? o.brightness : 100
        var b = Object.assign({}, root.blanked)
        b[name] = saved
        root.blanked = b
        persist()

        if (!openOverlay(o)) return
        // Skip the DDC round-trip for panels that report no brightness control
        // — there is nothing to set and the call would just stall.
        if (Plasmoid.configuration.dimBacklight && o.brightness !== null)
            exec.run("kscreen-doctor output." + name + ".brightness.0")
    }

    function restore(name) {
        if (!isBlanked(name)) return
        var saved = root.blanked[name]
        closeOverlay(name)

        var b = Object.assign({}, root.blanked)
        delete b[name]
        root.blanked = b
        persist()

        var o = outputFor(name)
        if (o && o.brightness !== null)
            exec.run("kscreen-doctor output." + name + ".brightness." + saved)
    }

    function toggle(name) { isBlanked(name) ? restore(name) : blank(name) }

    function blankOthers() {
        for (var i = 0; i < outputs.length; ++i)
            if (!isPrimary(outputs[i])) blank(outputs[i].name)
    }

    function restoreAll() {
        var names = Object.keys(root.blanked)
        for (var i = 0; i < names.length; ++i) restore(names[i])
    }

    function outputFor(name) {
        for (var i = 0; i < outputs.length; ++i)
            if (outputs[i].name === name) return outputs[i]
        return null
    }

    // ---------- overlay processes ----------
    // The overlay is an X11 override-redirect window placed at the output's
    // absolute coordinates. A Wayland client cannot pick its output — both a
    // fullscreen toplevel with Window.screen and a layer-shell surface with an
    // explicit screen put every overlay on screen 0 here, even with the
    // layer-shell integration forced. XWayland honours absolute geometry, so
    // the output is addressed by where it is rather than by name.
    //
    // Detached with setsid so the process is not tied to plasmashell's job
    // handling, and killed by its greppable label.
    function openOverlay(o) {
        exec.run("setsid python3 '" + root.overlayScript + "' blackout-" + o.name
                 + " " + o.x + " " + o.y + " " + o.w + " " + o.h
                 + " </dev/null >/dev/null 2>&1 &")
        return true
    }

    // The bracket in overlay-x11[.]py keeps this command's own shell from
    // matching the pattern it is searching for — otherwise pkill races to kill
    // the shell running it. The trailing space anchors the name so DP-1 does
    // not also match a hypothetical DP-11.
    function closeOverlay(name) {
        exec.run("pkill -9 -f \"overlay-x11[.]py blackout-" + name + " \"")
    }

    // An overlay the user clicked away has exited on its own; put that screen's
    // brightness back and drop it from our state.
    function reconcile(live) {
        var names = Object.keys(root.blanked)
        for (var i = 0; i < names.length; ++i)
            if (live.indexOf(names[i]) === -1) restore(names[i])
    }

    // ---------- crash recovery ----------
    // Overlays die with plasmashell but brightness 0 survives it, which would
    // leave a screen dark with no way back. Persist what we dimmed and undo it
    // on the next start.
    function persist() {
        Plasmoid.configuration.savedBrightness = JSON.stringify(root.blanked)
    }

    function recover() {
        // Overlays are detached, so they outlive plasmashell; brightness 0
        // outlives it too. Start from a known-clean state rather than half a
        // blackout with no widget state behind it.
        exec.run("pkill -9 -f \"overlay-x11[.]py blackout-\"")

        var raw = Plasmoid.configuration.savedBrightness
        if (!raw || raw === "" || raw === "{}") return
        try {
            var prev = JSON.parse(raw)
            var names = Object.keys(prev)
            for (var i = 0; i < names.length; ++i)
                exec.run("kscreen-doctor output." + names[i] + ".brightness." + prev[names[i]])
        } catch (e) { /* nothing sensible to do */ }
        Plasmoid.configuration.savedBrightness = "{}"
    }

    Component.onCompleted: {
        recover()
        refreshOutputs()
    }

    // Only polls while something is blacked out — this is how a click on an
    // overlay gets noticed, since the overlay exits without telling us.
    Timer {
        interval: 2000
        running: root.blankedCount > 0
        repeat: true
        onTriggered: root.refreshOutputs()
    }

    // Screens come and go (cables, DPMS, docking) — rebuild when they do.
    Connections {
        target: Qt.application
        function onScreensChanged() { root.refreshOutputs() }
    }

    // ---------- compact (in-panel) ----------
    compactRepresentation: MouseArea {
        id: compact
        Layout.minimumWidth: Kirigami.Units.iconSizes.small
        Layout.minimumHeight: Kirigami.Units.iconSizes.small
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: (mouse) => {
            // Middle-click is the one-handed gaming path: blank everything
            // except the primary without opening the popup.
            if (mouse.button === Qt.MiddleButton)
                root.blankedCount > 0 ? root.restoreAll() : root.blankOthers()
            else
                root.expanded = !root.expanded
        }

        Kirigami.Icon {
            id: icon
            anchors.fill: parent
            source: "video-display"
            active: compact.containsMouse
        }

        // Count badge when something is blacked out.
        Rectangle {
            visible: root.blankedCount > 0
            anchors { right: parent.right; bottom: parent.bottom }
            width: Math.round(parent.width * 0.5)
            height: width
            radius: height / 2
            color: Kirigami.Theme.negativeTextColor
            PlasmaComponents3.Label {
                anchors.centerIn: parent
                text: root.blankedCount
                color: Kirigami.Theme.backgroundColor
                font.pixelSize: Math.round(parent.height * 0.75)
                font.bold: true
            }
        }
    }

    // ---------- full (popup) ----------
    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 22
        Layout.minimumHeight: Kirigami.Units.gridUnit * 16

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing

            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading { level: 3; text: "Monitor Blackout" }
                Item { Layout.fillWidth: true }
                PlasmaComponents3.ToolButton {
                    icon.name: "view-refresh"
                    display: PlasmaComponents3.AbstractButton.IconOnly
                    text: "Rescan screens"
                    onClicked: root.refreshOutputs()
                }
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: "Click a screen to black it out. Nothing moves — the output stays enabled, so your windows stay where they are."
                wrapMode: Text.WordWrap
                opacity: 0.7
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }

            // ---- the monitor map, drawn to real relative geometry ----
            Item {
                id: mapArea
                Layout.fillWidth: true
                Layout.fillHeight: true

                readonly property var bounds: {
                    var minX = 0, minY = 0, maxX = 0, maxY = 0, first = true
                    for (var i = 0; i < root.outputs.length; ++i) {
                        var o = root.outputs[i]
                        if (first) {
                            minX = o.x; minY = o.y; maxX = o.x + o.w; maxY = o.y + o.h
                            first = false
                        } else {
                            minX = Math.min(minX, o.x); minY = Math.min(minY, o.y)
                            maxX = Math.max(maxX, o.x + o.w); maxY = Math.max(maxY, o.y + o.h)
                        }
                    }
                    return { x: minX, y: minY, w: Math.max(1, maxX - minX), h: Math.max(1, maxY - minY) }
                }
                // Uniform scale so the arrangement keeps its real proportions.
                readonly property real scale: Math.min(width / bounds.w, height / bounds.h)
                readonly property real offX: (width - bounds.w * scale) / 2
                readonly property real offY: (height - bounds.h * scale) / 2

                Repeater {
                    model: root.outputs
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool off: root.isBlanked(modelData.name)

                        x: mapArea.offX + (modelData.x - mapArea.bounds.x) * mapArea.scale
                        y: mapArea.offY + (modelData.y - mapArea.bounds.y) * mapArea.scale
                        width: Math.max(2, modelData.w * mapArea.scale - 4)
                        height: Math.max(2, modelData.h * mapArea.scale - 4)

                        radius: 3
                        color: off ? "black" : Kirigami.Theme.alternateBackgroundColor
                        border.width: root.isPrimary(modelData) ? 2 : 1
                        border.color: off ? Kirigami.Theme.negativeTextColor
                                          : (screenMouse.containsMouse ? Kirigami.Theme.highlightColor
                                                                       : Kirigami.Theme.textColor)
                        opacity: screenMouse.containsMouse ? 1 : 0.9

                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 0
                            PlasmaComponents3.Label {
                                Layout.alignment: Qt.AlignHCenter
                                text: modelData.name
                                font.bold: true
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                color: off ? "#888" : Kirigami.Theme.textColor
                            }
                            PlasmaComponents3.Label {
                                Layout.alignment: Qt.AlignHCenter
                                text: modelData.w + "×" + modelData.h
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                opacity: 0.6
                                color: off ? "#888" : Kirigami.Theme.textColor
                                visible: parent.height < parent.parent.height
                            }
                            PlasmaComponents3.Label {
                                Layout.alignment: Qt.AlignHCenter
                                text: root.isPrimary(modelData) ? "primary" : ""
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                opacity: 0.6
                                color: off ? "#888" : Kirigami.Theme.textColor
                                visible: root.isPrimary(modelData)
                            }
                        }

                        MouseArea {
                            id: screenMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.toggle(modelData.name)
                        }
                    }
                }
            }

            // ---- actions ----
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Button {
                    Layout.fillWidth: true
                    icon.name: "video-display"
                    text: "Black out all but primary"
                    onClicked: root.blankOthers()
                }
                PlasmaComponents3.Button {
                    Layout.fillWidth: true
                    icon.name: "edit-undo"
                    text: "Restore all"
                    enabled: root.blankedCount > 0
                    onClicked: root.restoreAll()
                }
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                visible: root.loadError !== ""
                text: root.loadError
                wrapMode: Text.WordWrap
                color: Kirigami.Theme.negativeTextColor
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }
    }
}
