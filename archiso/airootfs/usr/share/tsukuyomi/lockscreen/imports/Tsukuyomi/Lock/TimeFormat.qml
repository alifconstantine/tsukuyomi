pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool is24h: true
    readonly property var locale: Qt.locale()

    function load() {
        var data = {};
        try { data = JSON.parse(cfg.text()) || {}; } catch (e) {}
        var fmt = data && data.time && typeof data.time.format === "string"
            ? data.time.format.trim() : "";
        if (fmt === "") {
            root.is24h = true;
            return;
        }
        root.is24h = fmt.indexOf("H") !== -1 || fmt === "24h" || fmt === "24";
    }

    FileView {
        id: cfg
        path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/illogical-impulse/config.json"
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: root.load()
        onFileChanged: reload()
        onLoadFailed: { root.is24h = true; }
    }
}
