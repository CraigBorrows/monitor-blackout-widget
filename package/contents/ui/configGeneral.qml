import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    // cfg_ prefix is how Plasma binds a control to the config entry of the
    // same name in config/main.xml.
    property alias cfg_dimBacklight: dimCheck.checked

    Kirigami.FormLayout {
        anchors.fill: parent

        QQC2.CheckBox {
            id: dimCheck
            Kirigami.FormData.label: "Backlight:"
            text: "Also dim the backlight to 0"
        }

        QQC2.Label {
            Layout.fillWidth: true
            text: "The black window covers the screen either way. Dimming also\n"
                + "drops the backlight over DDC/CI, which removes the grey glow\n"
                + "a lit panel still gives off. Turn it off for instant toggling,\n"
                + "or if a monitor pops up an on-screen display when its\n"
                + "brightness changes."
            opacity: 0.7
            wrapMode: Text.WordWrap
        }
    }
}
