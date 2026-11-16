import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import SddmComponents 2.0

Rectangle {
    id: root
    width: 1920
    height: 1080
    color: config.background || "#060607"

    readonly property color colBg: config.background || "#060607"
    readonly property color colSurface: config.surface || "#120E0E"
    readonly property color colBorder: config.border || "#3A2B2B"
    readonly property color colFg: config.foreground || "#EAE2D5"
    readonly property color colMuted: config.muted || "#8C857A"
    readonly property color colAccent: config.accent || "#C92A2A"
    readonly property string uiFont: config.fontFamily || "Noto Sans"
    readonly property string monoFont: config.monoFamily || "JetBrainsMono Nerd Font"
    readonly property string cjkFont: config.cjkFamily || "Noto Serif CJK JP"

    property int sessionIndex: 0
    property int userIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
    property string errorMessage: ""
    property date now: new Date()

    function resolveDefaultSession() {
        var preferred = (config.preferredSession || "hyprland").toLowerCase()
        var fallback = sessionModel.lastIndex >= 0 ? sessionModel.lastIndex : 0
        for (var i = 0; i < sessionModel.rowCount(); i++) {
            var idx = sessionModel.index(i, 0)
            var file = String(sessionModel.data(idx, Qt.UserRole + 3) || "").toLowerCase()
            var name = String(sessionModel.data(idx, Qt.UserRole + 4) || "").toLowerCase()
            if (file === preferred + ".desktop" || file.indexOf(preferred) !== -1 || name === preferred) {
                return i
            }
        }
        return fallback
    }

    function currentUserName() {
        if (userBox.currentIndex >= 0) {
            return userBox.currentText
        }
        return userModel.lastUser || ""
    }

    function submitLogin() {
        errorMessage = ""
        var uname = currentUserName()
        if (!uname) {
            errorMessage = "Select a user account"
            return
        }
        sddm.login(uname, passwordInput.text, sessionIndex)
    }

    Component.onCompleted: {
        sessionIndex = resolveDefaultSession()
        passwordInput.forceActiveFocus()
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.now = new Date()
    }

    TextConstants { id: textConstants }

    Connections {
        target: sddm
        function onLoginFailed() {
            root.errorMessage = "Authentication failed"
            passwordInput.text = ""
            passwordInput.forceActiveFocus()
        }
        function onLoginSucceeded() {
            root.errorMessage = ""
        }
        function onInformationMessage(message) {
            root.errorMessage = message
        }
    }

    // Subtle dark-crimson radial glow behind center card
    Canvas {
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var grad = ctx.createRadialGradient(
                width * 0.5, height * 0.45, 20,
                width * 0.5, height * 0.45, Math.max(width, height) * 0.45
            )
            grad.addColorStop(0.0, "rgba(201, 42, 42, 0.08)")
            grad.addColorStop(0.6, "rgba(201, 42, 42, 0.02)")
            grad.addColorStop(1.0, "rgba(6, 6, 7, 0.0)")
            ctx.fillStyle = grad
            ctx.fillRect(0, 0, width, height)
        }
    }

    // Top-right minimal clock
    Column {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 36
        anchors.rightMargin: 44
        spacing: 2

        Text {
            anchors.right: parent.right
            text: Qt.formatTime(root.now, "HH:mm")
            color: root.colFg
            font.family: root.monoFont
            font.pixelSize: 28
            font.weight: Font.DemiBold
        }
        Text {
            anchors.right: parent.right
            text: Qt.formatDate(root.now, "ddd, dd MMM yyyy")
            color: root.colMuted
            font.family: root.uiFont
            font.pixelSize: 12
        }
    }

    // Center login card
    Rectangle {
        id: card
        width: 390
        height: cardCol.implicitHeight + 64
        anchors.centerIn: parent
        color: root.colSurface
        border.color: root.colBorder
        border.width: 1
        radius: 10

        ColumnLayout {
            id: cardCol
            anchors.fill: parent
            anchors.margins: 32
            spacing: 18

            // Brand header
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 12

                Canvas {
                    Layout.preferredWidth: 26
                    Layout.preferredHeight: 26
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        ctx.fillStyle = root.colAccent
                        ctx.beginPath()
                        ctx.arc(13, 13, 11, 0, Math.PI * 2)
                        ctx.fill()
                        ctx.globalCompositeOperation = "destination-out"
                        ctx.beginPath()
                        ctx.arc(17, 11, 9.5, 0, Math.PI * 2)
                        ctx.fill()
                    }
                }

                Text {
                    text: "月読"
                    color: root.colFg
                    font.family: root.cjkFont
                    font.pixelSize: 24
                    font.weight: Font.Bold
                }

                Rectangle {
                    Layout.preferredWidth: 2
                    Layout.preferredHeight: 20
                    color: root.colAccent
                }

                Text {
                    text: "TSUKUYOMI"
                    color: root.colFg
                    font.family: root.monoFont
                    font.pixelSize: 16
                    font.letterSpacing: 3
                    font.weight: Font.Bold
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: root.colBorder
            }

            // User selector
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    text: "USER"
                    color: root.colMuted
                    font.family: root.monoFont
                    font.pixelSize: 10
                    font.letterSpacing: 2
                }

                QQC2.ComboBox {
                    id: userBox
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    model: userModel
                    textRole: "name"
                    currentIndex: root.userIndex
                    onCurrentIndexChanged: root.userIndex = currentIndex

                    background: Rectangle {
                        color: root.colBg
                        border.color: userBox.activeFocus ? root.colAccent : root.colBorder
                        border.width: 1
                        radius: 6
                    }
                    contentItem: Text {
                        leftPadding: 12
                        text: userBox.displayText
                        color: root.colFg
                        font.family: root.uiFont
                        font.pixelSize: 14
                        verticalAlignment: Text.AlignVCenter
                    }
                    popup: QQC2.Popup {
                        y: userBox.height + 4
                        width: userBox.width
                        padding: 4
                        background: Rectangle {
                            color: root.colSurface
                            border.color: root.colBorder
                            radius: 6
                        }
                        contentItem: ListView {
                            clip: true
                            implicitHeight: contentHeight
                            model: userBox.popup.visible ? userBox.delegateModel : null
                        }
                    }
                    delegate: QQC2.ItemDelegate {
                        width: userBox.width - 8
                        contentItem: Text {
                            text: model.name || ""
                            color: root.colFg
                            font.family: root.uiFont
                            font.pixelSize: 13
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            color: highlighted ? "#2A1515" : "transparent"
                            radius: 4
                        }
                    }
                }
            }

            // Password field
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    text: "PASSPHRASE"
                    color: root.colMuted
                    font.family: root.monoFont
                    font.pixelSize: 10
                    font.letterSpacing: 2
                }

                QQC2.TextField {
                    id: passwordInput
                    Layout.fillWidth: true
                    Layout.preferredHeight: 42
                    echoMode: TextInput.Password
                    placeholderText: "Enter password"
                    placeholderTextColor: root.colMuted
                    color: root.colFg
                    font.family: root.monoFont
                    font.pixelSize: 14
                    leftPadding: 12
                    rightPadding: 12
                    selectionColor: root.colAccent
                    selectedTextColor: root.colFg

                    background: Rectangle {
                        color: root.colBg
                        border.color: passwordInput.activeFocus ? root.colAccent : root.colBorder
                        border.width: passwordInput.activeFocus ? 1.5 : 1
                        radius: 6
                    }

                    Keys.onReturnPressed: root.submitLogin()
                    Keys.onEnterPressed: root.submitLogin()
                }
            }

            Text {
                Layout.fillWidth: true
                visible: root.errorMessage.length > 0
                text: root.errorMessage
                color: "#E05252"
                font.family: root.uiFont
                font.pixelSize: 12
                horizontalAlignment: Text.AlignHCenter
            }

            // Login button
            QQC2.Button {
                id: loginBtn
                Layout.fillWidth: true
                Layout.preferredHeight: 42
                text: "UNLOCK SESSION"
                onClicked: root.submitLogin()

                background: Rectangle {
                    color: loginBtn.pressed ? "#991B1B" : (loginBtn.hovered ? "#D63434" : root.colAccent)
                    radius: 6
                }
                contentItem: Text {
                    text: loginBtn.text
                    color: root.colFg
                    font.family: root.monoFont
                    font.pixelSize: 12
                    font.letterSpacing: 2
                    font.weight: Font.Bold
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            // Session picker (defaults to Hyprland)
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: "SESSION"
                    color: root.colMuted
                    font.family: root.monoFont
                    font.pixelSize: 10
                    font.letterSpacing: 1.5
                }

                QQC2.ComboBox {
                    id: sessionBox
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    model: sessionModel
                    textRole: "name"
                    currentIndex: root.sessionIndex
                    onCurrentIndexChanged: root.sessionIndex = currentIndex

                    background: Rectangle {
                        color: root.colBg
                        border.color: root.colBorder
                        border.width: 1
                        radius: 5
                    }
                    contentItem: Text {
                        leftPadding: 10
                        text: sessionBox.displayText
                        color: root.colMuted
                        font.family: root.uiFont
                        font.pixelSize: 12
                        verticalAlignment: Text.AlignVCenter
                    }
                    popup: QQC2.Popup {
                        y: sessionBox.height + 4
                        width: sessionBox.width
                        padding: 4
                        background: Rectangle {
                            color: root.colSurface
                            border.color: root.colBorder
                            radius: 6
                        }
                        contentItem: ListView {
                            clip: true
                            implicitHeight: contentHeight
                            model: sessionBox.popup.visible ? sessionBox.delegateModel : null
                        }
                    }
                    delegate: QQC2.ItemDelegate {
                        width: sessionBox.width - 8
                        contentItem: Text {
                            text: model.name || ""
                            color: root.colFg
                            font.family: root.uiFont
                            font.pixelSize: 12
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            color: highlighted ? "#2A1515" : "transparent"
                            radius: 4
                        }
                    }
                }
            }
        }
    }

    // Bottom-right power actions
    Row {
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.bottomMargin: 28
        anchors.rightMargin: 36
        spacing: 12

        Repeater {
            model: [
                { label: "Suspend", action: "suspend" },
                { label: "Reboot", action: "reboot" },
                { label: "Power Off", action: "poweroff" }
            ]

            delegate: QQC2.Button {
                required property var modelData
                height: 32
                width: 88
                text: modelData.label
                onClicked: {
                    if (modelData.action === "suspend") sddm.suspend()
                    else if (modelData.action === "reboot") sddm.reboot()
                    else if (modelData.action === "poweroff") sddm.powerOff()
                }
                background: Rectangle {
                    color: parent.hovered ? root.colSurface : "transparent"
                    border.color: parent.hovered ? root.colAccent : root.colBorder
                    border.width: 1
                    radius: 6
                }
                contentItem: Text {
                    text: parent.text
                    color: parent.hovered ? root.colFg : root.colMuted
                    font.family: root.uiFont
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
