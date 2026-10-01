import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "gustavx404.yubikey"
  ipcTarget: "gustavx404.yubikey"
  manageIpc: false

  property var connectedDevices: []
  property var keys: []
  property var passwords: ({})
  property var aliases: (settings && settings.keyAliases) ? settings.keyAliases : ({})
  property string statusText: ""
  property string lastCopiedCode: ""
  property string lastCopiedKeyId: ""
  property double lastCopiedValidTo: 0
  property var activeRequestProcess: null
  property string activeRequest: ""
  property bool requestBusy: false
  property bool settingsOpen: false
  property string lastInventorySignature: ""
  property bool missingDependency: false
  property var clipboardOwner: null

  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("ykbridge.py")).replace(/^file:\/\//, ""))
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color mutedForeground: Qt.darker(foreground, 1.45)
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property int clearTimeoutSeconds: {
    var value = parseInt(String(setting("clipboardClearSeconds", 30)), 10)
    return [30, 60, 120, 300].indexOf(value) >= 0 ? value : 30
  }
  readonly property var clearTimeouts: [30, 60, 120, 300]
  readonly property int connectedKeyCount: {
    var total = 0
    for (var i = 0; i < connectedDevices.length; i++) total += Number(connectedDevices[i].count || 0)
    return total
  }

  component ThemedIcon: Item {
    id: themedIcon
    property url source
    property color tint: Color.foreground
    implicitWidth: Style.font.icon
    implicitHeight: Style.font.icon

    IconImage {
      id: sourceIcon
      anchors.fill: parent
      source: themedIcon.source
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: parent
      source: sourceIcon
      autoPaddingEnabled: false
      colorization: 1.0
      colorizationColor: themedIcon.tint
    }
  }

  function saveSetting(name, value) {
    var next = ({})
    for (var key in settings) if (key !== "id") next[key] = settings[key]
    next[name] = value
    settings = next
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, next)
  }

  function keyTitle(key) {
    var alias = String(aliases[key.keyId] || "").trim()
    return alias !== "" ? alias : String(key.title || "YubiKey")
  }

  function inventorySignature(devices) {
    return JSON.stringify(devices.map(function(device) {
      return [Number(device.productId), Number(device.count)]
    }))
  }

  function updateDevices(line) {
    var response
    try { response = JSON.parse(String(line)) } catch (e) { return }
    if (response.error === "missing_dependency") {
      missingDependency = true
      connectedDevices = []
      return
    }
    if (!response.ok || !Array.isArray(response.devices)) return
    missingDependency = false

    var nextDevices = response.devices
    var nextSignature = inventorySignature(nextDevices) + ":" + String(response.state || 0)
    var oldCount = connectedKeyCount
    var nextCount = 0
    for (var i = 0; i < nextDevices.length; i++) nextCount += Number(nextDevices[i].count || 0)

    if (lastInventorySignature !== "" && nextSignature !== lastInventorySignature) {
      // The watcher intentionally reports only product IDs and counts. When
      // that inventory changes, discard every cached access password so no
      // secret can outlive a removed key, including a rapid key swap.
      passwords = ({})
      keys = []
      statusText = "YubiKey connection changed. Reopen the panel to refresh."
      if (requestBusy && activeRequest === "code" && activeRequestProcess)
        activeRequestProcess.signal(15)
      if (lastCopiedCode !== "" && (nextCount < oldCount || nextSignature !== lastInventorySignature))
        clearCopiedCode()
      if (opened && nextCount > 0) Qt.callLater(refreshAccounts)
    }

    lastInventorySignature = nextSignature
    connectedDevices = nextDevices
    if (nextCount === 0 && opened) close()
  }

  function requestBridge(action, payload, isClipboardClear) {
    if (!isClipboardClear && requestBusy) return
    var process = requestComponent.createObject(root, {
      actionName: action,
      requestPayload: payload,
      clearOnly: isClipboardClear === true
    })
    if (!process) return
    if (!isClipboardClear) {
      requestBusy = true
      activeRequest = action
      activeRequestProcess = process
    }
    process.command = ["python3", helperPath, action]
    process.running = true
  }

  function refreshAccounts() {
    statusText = "Reading OATH accounts…"
    requestBridge("list", { passwords: passwords }, false)
  }

  function handleBridgeOutput(action, payload, output, clearOnly) {
    var response
    try { response = JSON.parse(String(output || "").trim()) } catch (e) {
      if (!clearOnly) statusText = "Could not read the YubiKey response."
      return
    }

    if (clearOnly) return
    if (action === "list") {
      if (response.ok && Array.isArray(response.keys)) {
        keys = response.keys
        var acceptedPasswords = Object.assign({}, passwords)
        for (var i = 0; i < keys.length; i++) {
          if (keys[i].error === "incorrect_password") delete acceptedPasswords[keys[i].keyId]
        }
        passwords = acceptedPasswords
        statusText = keys.length === 0 ? "No OATH-enabled YubiKey is available over USB." : ""
      } else {
        statusText = errorMessage(response.error)
      }
      return
    }

    if (action === "code") {
      if (!response.ok) {
        if (response.error === "locked" || response.error === "incorrect_password") {
          var nextPasswords = Object.assign({}, passwords)
          delete nextPasswords[payload.keyId]
          passwords = nextPasswords
          refreshAccounts()
          statusText = response.error === "incorrect_password" ? "OATH password was not accepted." : "Enter the OATH password for this key."
        } else {
          statusText = errorMessage(response.error)
        }
        return
      }
      copyCode(response.code, payload.keyId, response.validTo, payload.label)
    }
  }

  function errorMessage(code) {
    if (code === "missing_dependency") return "Install yubikey-manager and wl-clipboard, then reopen the panel."
    if (code === "oath_unavailable") return "OATH is unavailable on this key. Check its USB applications."
    if (code === "key_disconnected") return "The selected YubiKey was disconnected."
    if (code === "account_missing") return "That OATH account is no longer on the key."
    if (code === "touch_timeout") return "Touch timed out. Click the account and try again."
    if (code === "clipboard_unavailable") return "Could not access the Wayland clipboard."
    return "Could not communicate with the YubiKey. Check CCID and PC/SC."
  }

  function unlockKey(keyId, password) {
    var nextPasswords = Object.assign({}, passwords)
    nextPasswords[keyId] = String(password || "")
    passwords = nextPasswords
    refreshAccounts()
  }

  function copyAccount(keyId, account) {
    if (requestBusy) return
    var accountLabel = (account.issuer ? account.issuer + " · " : "") + account.name
    statusText = account.touchRequired ? "Touch the YubiKey to generate this code…" : "Generating code…"
    if (account.type === "HOTP") statusText = "HOTP advances its counter. Generating the next code…"
    requestBridge("code", {
      keyId: keyId,
      accountId: account.id,
      password: String(passwords[keyId] || ""),
      type: account.type,
      label: accountLabel
    }, false)
  }

  function copyCode(code, keyId, validTo, label) {
    var value = String(code || "")
    if (value === "") return

    lastCopiedCode = value
    lastCopiedKeyId = keyId
    lastCopiedValidTo = Number(validTo || 0)
    statusText = "Copied " + String(label || "code") + " to clipboard."

    var writer = clipboardWriterComponent.createObject(root, { payload: value })
    if (writer) {
      clipboardOwner = writer
      writer.running = true
    } else {
      statusText = "Could not start the clipboard writer."
      lastCopiedCode = ""
      lastCopiedKeyId = ""
      return
    }

    scheduleClipboardClear()
  }

  function scheduleClipboardClear() {
    if (lastCopiedCode === "") return
    var timeoutMs = clearTimeoutSeconds * 1000
    var expiry = lastCopiedValidTo * 1000
    if (expiry > 0) timeoutMs = Math.min(timeoutMs, expiry - Date.now())
    clipboardTimer.interval = Math.max(1000, Math.round(timeoutMs))
    clipboardTimer.restart()
  }

  function clearCopiedCode() {
    clipboardTimer.stop()
    var value = lastCopiedCode
    lastCopiedCode = ""
    lastCopiedKeyId = ""
    lastCopiedValidTo = 0
    if (value !== "") requestBridge("clear", { expected: value }, true)
  }

  function clipboardOwnerExited(owner) {
    if (clipboardOwner === owner) clipboardOwner = null
  }

  function saveAlias(keyId, value) {
    var nextAliases = Object.assign({}, aliases)
    var name = String(value || "").trim()
    if (name === "") delete nextAliases[keyId]
    else nextAliases[keyId] = name
    aliases = nextAliases
    saveSetting("keyAliases", nextAliases)
  }

  function timeoutLabel(seconds) {
    return Number(seconds) === 60 ? "1 minute" : (Number(seconds) === 300 ? "5 minutes" : Number(seconds) + " seconds")
  }

  function handlePanelClose() {
    if (requestBusy && activeRequest === "code" && activeRequestProcess)
      activeRequestProcess.signal(15)
  }

  onOpenedChanged: {
    if (opened) {
      settingsOpen = false
      statusText = ""
      refreshAccounts()
    } else {
      handlePanelClose()
    }
  }
  onClearTimeoutSecondsChanged: scheduleClipboardClear()

  implicitWidth: connectedKeyCount > 0 ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  Process {
    id: deviceWatcher
    command: ["python3", root.helperPath, "watch"]
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.updateDevices(line) }
    }
    onExited: function(exitCode, exitStatus) {
      retryWatcher.restart()
    }
  }

  Timer {
    id: retryWatcher
    interval: 5000
    repeat: false
    onTriggered: deviceWatcher.running = true
  }

  Timer {
    id: clipboardTimer
    repeat: false
    onTriggered: root.clearCopiedCode()
  }

  Component {
    id: requestComponent
    Process {
      property string actionName: ""
      property var requestPayload: ({})
      property bool clearOnly: false
      command: ["python3", root.helperPath, actionName]
      stdinEnabled: true
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: root.handleBridgeOutput(actionName, requestPayload, text, clearOnly)
      }
      onStarted: write(JSON.stringify(requestPayload) + "\n")
      onExited: {
        if (!clearOnly) {
          root.requestBusy = false
          if (root.activeRequestProcess === this) {
            root.activeRequestProcess = null
            root.activeRequest = ""
          }
        }
        Qt.callLater(function() { destroy() })
      }
    }
  }

  Component {
    id: clipboardWriterComponent
    Process {
      property string payload: ""
      property string copiedValue: ""
      command: ["wl-copy", "--foreground", "--sensitive", "--type", "text/plain;charset=utf-8"]
      stdinEnabled: true
      onStarted: {
        copiedValue = payload
        write(payload)
        stdinEnabled = false
        payload = ""
      }
      onExited: {
        root.clipboardOwnerExited(this)
        copiedValue = ""
        Qt.callLater(function() { destroy() })
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    visible: root.connectedKeyCount > 0
    iconComponent: Component {
      ThemedIcon {
        anchors.fill: parent
        source: Qt.resolvedUrl("icons/yubikey.svg")
        tint: root.foreground
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.connectedKeyCount > 0
    focusTarget: null
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(560))

    ColumnLayout {
      id: contentColumn
      anchors.fill: parent
      spacing: Style.space(8)

      RowLayout {
        Layout.fillWidth: true

        Text {
          text: root.settingsOpen ? "Settings" : "YubiKey OATH"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.heading
          font.weight: Font.DemiBold
          Layout.fillWidth: true
        }

        ToolButton {
          contentItem: ThemedIcon {
            source: Qt.resolvedUrl(root.settingsOpen ? "icons/back.svg" : "icons/settings.svg")
            tint: root.foreground
            width: Style.font.icon
            height: Style.font.icon
          }
          Accessible.name: root.settingsOpen ? "Back to accounts" : "Settings"
          onClicked: root.settingsOpen = !root.settingsOpen
        }
      }

      Text {
        Layout.fillWidth: true
        visible: !root.settingsOpen && root.statusText !== ""
        text: root.statusText
        color: root.mutedForeground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      ScrollView {
        id: accountScrollView
        visible: !root.settingsOpen
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: ScrollBar.AsNeeded

        ColumnLayout {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.keys

            delegate: BorderSurface {
              id: keyCard
              required property var modelData
              property var keyGroup: modelData
              Layout.fillWidth: true
              property real cardInset: Style.space(6)
              padding: cardInset
              color: Color.popups.background
              borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)
              Layout.preferredHeight: cardContent.implicitHeight + contentTopInset + contentBottomInset

              ColumnLayout {
                id: cardContent
                x: keyCard.contentLeftInset
                y: keyCard.contentTopInset
                width: keyCard.width - keyCard.contentLeftInset - keyCard.contentRightInset
                spacing: Style.space(4)

                RowLayout {
                  Layout.fillWidth: true

                  Text {
                    text: root.keyTitle(keyGroup)
                    color: root.bar ? root.bar.foreground : Color.foreground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                  }

                }

                RowLayout {
                  visible: keyGroup.locked === true
                  Layout.fillWidth: true
                  TextField {
                    id: oathPassword
                    Layout.fillWidth: true
                    echoMode: TextInput.Password
                    placeholderText: "OATH password"
                    inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                    enabled: !root.requestBusy
                    onAccepted: unlockButton.clicked()
                  }
                  Button {
                    id: unlockButton
                    text: "Unlock"
                    enabled: oathPassword.text !== "" && !root.requestBusy
                    onClicked: {
                      root.unlockKey(keyGroup.keyId, oathPassword.text)
                      oathPassword.text = ""
                    }
                  }
                }

                Text {
                  visible: keyGroup.error === "incorrect_password"
                  text: "Password not accepted. Try again."
                  color: root.urgentColor
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  visible: keyGroup.error === "oath_unavailable"
                  text: "OATH is unavailable on this key."
                  color: root.mutedForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Repeater {
                  model: keyGroup.accounts || []

                  delegate: Button {
                    id: accountButton
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: modelData.type === "HOTP" ? Style.space(44) : (modelData.touchRequired ? Style.space(40) : Style.space(32))
                    enabled: !root.requestBusy
                    horizontalPadding: Style.space(8)
                    verticalPadding: Style.space(4)
                    onClicked: root.copyAccount(keyGroup.keyId, modelData)
                    Accessible.name: "Copy " + (modelData.issuer ? modelData.issuer + " " : "") + modelData.name

                    background: Rectangle {
                      color: accountButton.down ? Style.pressedFill : (accountButton.hovered ? Style.hoverFill : "transparent")
                      border.color: accountButton.hovered ? Style.hoverBorderColor : Color.popups.border
                      border.width: Style.normalBorderWidth
                    }

                    contentItem: RowLayout {
                      spacing: Style.space(8)

                      ThemedIcon {
                        source: Qt.resolvedUrl(modelData.type === "HOTP" ? "icons/hotp.svg" : "icons/totp.svg")
                        tint: Color.foreground
                        implicitWidth: Style.space(18)
                        implicitHeight: Style.space(18)
                        Layout.preferredWidth: Style.space(18)
                        Layout.preferredHeight: Style.space(18)
                      }

                      ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        Text {
                          Layout.fillWidth: true
                          text: (modelData.issuer ? modelData.issuer + " · " : "") + modelData.name
                          color: Color.foreground
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.bodySmall
                          elide: Text.ElideRight
                          horizontalAlignment: Text.AlignLeft
                        }

                        Text {
                          Layout.fillWidth: true
                          visible: modelData.touchRequired
                          text: "Touch required"
                          color: root.mutedForeground
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                          horizontalAlignment: Text.AlignLeft
                        }
                      }

                      ColumnLayout {
                        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
                        spacing: 0

                        Text {
                          Layout.alignment: Qt.AlignRight
                          text: modelData.type
                          color: modelData.type === "HOTP" ? root.urgentColor : root.mutedForeground
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.caption
                          font.weight: Font.DemiBold
                        }

                        Text {
                          visible: modelData.type === "HOTP"
                          Layout.alignment: Qt.AlignRight
                          text: "Counter advances"
                          color: root.urgentColor
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                  }
                }

                Text {
                  visible: (keyGroup.accounts || []).length === 0 && keyGroup.locked !== true && keyGroup.error === ""
                  text: "No OATH accounts on this key."
                  color: root.mutedForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Text {
            Layout.fillWidth: true
            visible: root.keys.length === 0 && root.connectedKeyCount > 0 && root.statusText === ""
            text: "Opening the panel reads OATH accounts from connected keys."
            color: root.mutedForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
        }
      }

      ScrollView {
        visible: root.settingsOpen
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: ScrollBar.AsNeeded

        ColumnLayout {
          width: parent.width
          spacing: Style.space(8)

          BorderSurface {
            Layout.fillWidth: true
            padding: Style.space(8)
            color: Color.popups.background
            borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)
            Layout.preferredHeight: clipboardSettings.implicitHeight + contentTopInset + contentBottomInset

            ColumnLayout {
              id: clipboardSettings
              x: parent.contentLeftInset
              y: parent.contentTopInset
              width: parent.width - parent.contentLeftInset - parent.contentRightInset
              spacing: Style.space(5)

              Text {
                text: "Clipboard"
                color: Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                font.weight: Font.DemiBold
              }

              RowLayout {
                Layout.fillWidth: true
                Text {
                  Layout.fillWidth: true
                  text: "Clear copied code after"
                  color: root.mutedForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
                ComboBox {
                  id: timeoutPicker
                  model: root.clearTimeouts.map(function(value) { return root.timeoutLabel(value) })
                  currentIndex: Math.max(0, root.clearTimeouts.indexOf(root.clearTimeoutSeconds))
                  onActivated: root.saveSetting("clipboardClearSeconds", root.clearTimeouts[timeoutPicker.currentIndex])
                  Accessible.name: "Clear copied code after"
                }
              }

              Text {
                Layout.fillWidth: true
                text: "Codes are marked sensitive. TOTP codes clear at expiry when sooner."
                color: root.mutedForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
            }
          }

          BorderSurface {
            Layout.fillWidth: true
            padding: Style.space(8)
            color: Color.popups.background
            borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)
            Layout.preferredHeight: keySettings.implicitHeight + contentTopInset + contentBottomInset

            ColumnLayout {
              id: keySettings
              x: parent.contentLeftInset
              y: parent.contentTopInset
              width: parent.width - parent.contentLeftInset - parent.contentRightInset
              spacing: Style.space(5)

              Text {
                text: "YubiKeys"
                color: Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                font.weight: Font.DemiBold
              }

              Repeater {
                model: root.keys
                delegate: RowLayout {
                  required property var modelData
                  property var keyGroup: modelData
                  Layout.fillWidth: true

                  Text {
                    Layout.fillWidth: true
                    text: String(keyGroup.title || "YubiKey")
                    color: root.mutedForeground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  TextField {
                    Layout.preferredWidth: Style.space(140)
                    placeholderText: "Optional alias"
                    text: String(root.aliases[keyGroup.keyId] || "")
                    onEditingFinished: root.saveAlias(keyGroup.keyId, text)
                    Accessible.name: "Alias for " + String(keyGroup.title || "YubiKey")
                  }
                }
              }

              Text {
                visible: root.keys.length === 0
                text: "Connect a YubiKey to configure its alias."
                color: root.mutedForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          BorderSurface {
            Layout.fillWidth: true
            padding: Style.space(8)
            color: Color.popups.background
            borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)
            Layout.preferredHeight: securitySettings.implicitHeight + contentTopInset + contentBottomInset

            ColumnLayout {
              id: securitySettings
              x: parent.contentLeftInset
              y: parent.contentTopInset
              width: parent.width - parent.contentLeftInset - parent.contentRightInset
              spacing: Style.space(4)

              Text {
                text: "Security"
                color: Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                font.weight: Font.DemiBold
              }
              Text {
                Layout.fillWidth: true
                text: "OATH passwords stay in memory while the connected-key inventory is unchanged."
                color: root.mutedForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
              Text {
                Layout.fillWidth: true
                text: "HOTP copies advance the key counter. USB only; enrollment and NFC are not supported yet."
                color: root.mutedForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
            }
          }
        }
      }
    }
  }
}
