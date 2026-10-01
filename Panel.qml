import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
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
  property var iconPack: null
  property string iconPackMessage: ""
  property string statusText: ""
  property var activeRequestProcess: null
  property var clipboardProcess: null
  property var deviceScanProcess: null
  property string activeRequest: ""
  property bool requestBusy: false
  property bool refreshPending: false
  property bool settingsOpen: false
  property string lastInventorySignature: ""
  property bool missingDependency: false

  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("ykbridge.py")).replace(/^file:\/\//, ""))
  readonly property string iconPackHelperPath: decodeURIComponent(String(Qt.resolvedUrl("iconpacks.py")).replace(/^file:\/\//, ""))
  readonly property string customIconDirectoryPath: decodeURIComponent(String(Qt.resolvedUrl("icons/custom")).replace(/^file:\/\//, ""))
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color mutedForeground: Qt.darker(foreground, 1.45)
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property int clearTimeoutSeconds: {
    var value = parseInt(String(setting("clipboardClearSeconds", 30)), 10)
    return [30, 60, 120].indexOf(value) >= 0 ? value : 30
  }
  readonly property var clearTimeouts: [30, 60, 120]
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

  function bridgeEnvironment() {
    var environment = { "PATH": "/usr/bin", "HOME": "/nonexistent" }
    var runtime = Quickshell.env("XDG_RUNTIME_DIR")
    var bus = Quickshell.env("DBUS_SESSION_BUS_ADDRESS")
    if (runtime) environment.XDG_RUNTIME_DIR = runtime
    if (bus) environment.DBUS_SESSION_BUS_ADDRESS = bus
    return environment
  }

  function sandboxCommand(action, extraFilePath) {
    var command = [
      "/usr/bin/systemd-run", "--user", "--quiet", "--pipe", "--wait", "--collect",
      "--property=NoNewPrivileges=yes",
      "--property=RestrictAddressFamilies=AF_UNIX",
      "--property=RuntimeMaxSec=6min",
      "--setenv=PATH=/usr/bin",
      "--setenv=HOME=/nonexistent",
      "--setenv=PYTHONNOUSERSITE=1",
      "--setenv=PYTHONDONTWRITEBYTECODE=1",
      "--setenv=LC_ALL=C.UTF-8",
      "--", "/usr/bin/bwrap", "--die-with-parent",
      "--ro-bind", "/usr", "/usr",
      "--ro-bind", "/etc", "/etc",
      "--ro-bind", "/lib", "/lib",
      "--ro-bind", "/lib64", "/lib64",
      "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
      "--dir", "/run",
      "--dir", "/run/omarchy-yubikey",
      "--ro-bind", root.helperPath, "/run/omarchy-yubikey/ykbridge.py",
      "--ro-bind", root.iconPackHelperPath, "/run/omarchy-yubikey/iconpacks.py"
    ]
    if (action === "list" || action === "code" || action === "scan")
      command.push("--dir", "/run/pcscd", "--ro-bind", "/run/pcscd/pcscd.comm", "/run/pcscd/pcscd.comm")
    if (action === "scan") {
      command.push("--ro-bind", "/sys", "/sys", "--dir", "/dev/bus", "--ro-bind", "/dev/bus/usb", "/dev/bus/usb")
    } else if (action === "icon-import") {
      command.push("--dir", "/run/omarchy-yubikey/custom-icons")
      command.push("--ro-bind", extraFilePath, "/run/omarchy-yubikey/icon-pack.zip")
      command.push("--bind", root.customIconDirectoryPath, "/run/omarchy-yubikey/custom-icons")
    } else if (action === "icon-list") {
      command.push("--dir", "/run/omarchy-yubikey/custom-icons")
      command.push("--ro-bind", root.customIconDirectoryPath, "/run/omarchy-yubikey/custom-icons")
    } else if (action === "icon-clear") {
      command.push("--dir", "/run/omarchy-yubikey/custom-icons")
      command.push("--bind", root.customIconDirectoryPath, "/run/omarchy-yubikey/custom-icons")
    }
    var runtime = Quickshell.env("XDG_RUNTIME_DIR")
    var display = Quickshell.env("WAYLAND_DISPLAY")
    if (action === "code" && runtime && display) {
      var socketPath = display.charAt(0) === "/" ? display : runtime + "/" + display
      command.splice(command.indexOf("--"), 0, "--setenv=XDG_RUNTIME_DIR=/run/omarchy-yubikey", "--setenv=WAYLAND_DISPLAY=wayland-1")
      command.push("--ro-bind", socketPath, "/run/omarchy-yubikey/wayland-1")
    }
    command.push("--", "/usr/bin/python3", "/run/omarchy-yubikey/ykbridge.py", action)
    return command
  }

  function accountBrand(account) {
    var label = (String(account.issuer || "") + " " + String(account.name || "")).toLowerCase()
    if (label.indexOf("github") >= 0) return ["GH", "#f0f6fc"]
    if (label.indexOf("google") >= 0) return ["G", "#4285f4"]
    if (label.indexOf("discord") >= 0) return ["D", "#5865f2"]
    if (label.indexOf("activision") >= 0) return ["A", "#ffffff"]
    if (label.indexOf("desec") >= 0) return ["D", "#36c5a4"]
    if (label.indexOf("ea") >= 0) return ["EA", "#ff4747"]
    if (label.indexOf("epic") >= 0) return ["E", "#ffffff"]
    if (label.indexOf("facebook") >= 0) return ["f", "#0866ff"]
    if (label.indexOf("filen") >= 0) return ["F", "#55a8ff"]
    if (label.indexOf("instagram") >= 0) return ["◎", "#e4405f"]
    if (label.indexOf("hotmail") >= 0 || label.indexOf("outlook") >= 0 || label.indexOf("microsoft") >= 0)
      return ["M", "#00a4ef"]
    if (label.indexOf("mercado livre") >= 0 || label.indexOf("mercadolivre") >= 0)
      return ["ML", "#ffe600"]
    if (label.indexOf("playstation") >= 0 || label.indexOf("psn") >= 0)
      return ["PS", "#3695d8"]
    if (label.indexOf("proton") >= 0) return ["P", "#8b6cff"]
    if (label.indexOf("racedepartment") >= 0 || label.indexOf("race department") >= 0 || label.indexOf("overtake") >= 0)
      return ["RD", "#ff6b35"]
    if (label.indexOf("rockstar") >= 0) return ["R★", "#f4c542"]
    if (label.indexOf("tutanota") >= 0 || label.indexOf("tuta") >= 0)
      return ["T", "#e74b3c"]
    if (label.indexOf("twitch") >= 0) return ["T", "#a970ff"]
    var identity = String(account.issuer || account.name || "").trim()
    if (!identity) return ["", ""]
    var colors = ["#4f9bd8", "#42a889", "#b579d2", "#d38b42", "#cf6679", "#6b88cf"]
    var hash = 0
    for (var index = 0; index < identity.length; index++)
      hash = (hash * 31 + identity.charCodeAt(index)) | 0
    return [identity.charAt(0).toUpperCase(), colors[((hash % colors.length) + colors.length) % colors.length]]
  }

  function customIconUrl(account) {
    if (!iconPack || !Array.isArray(iconPack.icons) || !account || typeof account.issuer !== "string") return ""
    var issuer = account.issuer.trim().toLowerCase()
    for (var i = 0; i < iconPack.icons.length; i++) {
      var item = iconPack.icons[i]
      if (!item || !Array.isArray(item.issuer)) continue
      if (item.issuer.some(function(alias) { return String(alias).toLowerCase() === issuer }))
        return Qt.resolvedUrl("icons/custom/" + item.file).toString()
    }
    return ""
  }

  function validIconPack(pack) {
    if (pack === null) return true
    return pack && typeof pack.uuid === "string" && /^[a-f0-9-]{36}$/.test(pack.uuid)
      && Number.isInteger(pack.version) && pack.version > 0
      && typeof pack.name === "string" && pack.name.length > 0 && pack.name.length <= 128
      && !/[\u0000-\u001f\u007f-\u009f]/.test(pack.name)
      && Array.isArray(pack.icons) && pack.icons.length <= 2048
      && pack.icons.every(function(item) {
        return item && Array.isArray(item.issuer) && item.issuer.length > 0 && item.issuer.length <= 32
          && item.issuer.every(function(alias) {
            return typeof alias === "string" && alias.length > 0 && alias.length <= 128
              && !/[\u0000-\u001f\u007f-\u009f]/.test(alias)
          })
          && typeof item.file === "string"
          && /^[a-f0-9-]{36}\/[1-9][0-9]{0,8}\/[a-f0-9]{64}\.(svg|png|jpg)$/.test(item.file)
      })
  }

  function localFilePath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") !== 0) return ""
    var path = decodeURIComponent(value.replace(/^file:\/\//, ""))
    return path.charAt(0) === "/" ? path : ""
  }

  function loadCustomIconPack() {
    requestBridge("icon-list", { schema: 1 })
  }

  function importCustomIconPack(url) {
    var path = localFilePath(url)
    if (!path) {
      iconPackMessage = "Select a local Aegis icon pack ZIP."
      return
    }
    iconPackMessage = "Loading icon pack…"
    requestBridge("icon-import", { schema: 1 }, "", path)
  }

  function removeCustomIconPack() {
    iconPackMessage = "Removing icon pack…"
    requestBridge("icon-clear", { schema: 1 })
  }

  function inventorySignature(devices) {
    return JSON.stringify(devices.map(function(device) {
      return [Number(device.productId), Number(device.count)]
    }))
  }

  function updateDevices(line) {
    var response
    try { response = JSON.parse(String(line)) } catch (e) { return }
    if (!response || response.schema !== 1) return
    if (response.error === "missing_dependency") {
      missingDependency = true
      connectedDevices = []
      return
    }
    if (response.ok !== true || !Number.isInteger(response.state) || !Array.isArray(response.devices)
        || response.devices.length > 16
        || !response.devices.every(function(device) {
          return device && Number.isInteger(device.productId) && device.productId >= 0 && device.productId <= 65535
            && typeof device.model === "string" && device.model.length <= 64
            && Number.isInteger(device.count) && device.count >= 0 && device.count <= 32
        })) return
    missingDependency = false

    var nextDevices = response.devices
    // ykman scan_devices() returns an internal state token that changes on
    // every scan, even when the attached keys have not changed. Use only the
    // stable inventory fields here so polling does not clear passwords.
    var nextSignature = inventorySignature(nextDevices)
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
      if (clipboardProcess) {
        clipboardProcess.signal(15)
        clipboardProcess = null
      }
      if (opened && nextCount > 0) Qt.callLater(refreshAccounts)
    }

    lastInventorySignature = nextSignature
    connectedDevices = nextDevices
    if (nextCount === 0 && opened) close()
  }

  function requestBridge(action, payload, displayLabel, extraFilePath) {
    if (requestBusy) return
    var process = requestComponent.createObject(root, {
      actionName: action,
      requestPayload: payload,
      displayLabel: displayLabel || "",
      extraFilePath: extraFilePath || ""
    })
    if (!process) return
    requestBusy = true
    activeRequest = action
    activeRequestProcess = process
    process.environment = bridgeEnvironment()
    process.clearEnvironment = true
    process.command = sandboxCommand(action, process.extraFilePath)
    process.running = true
  }

  function refreshAccounts() {
    if (requestBusy) {
      if (activeRequest !== "list") refreshPending = true
      return
    }
    refreshPending = false
    statusText = "Reading OATH accounts…"
    requestBridge("list", { schema: 1, passwords: passwords })
  }

  function handleBridgeOutput(action, payload, output, displayLabel) {
    var response
    try { response = JSON.parse(String(output || "").trim()) } catch (e) {
      statusText = "Could not read the YubiKey response."
      return
    }

    if (action === "icon-list") {
      if (response.schema === 1 && response.ok === true && validIconPack(response.pack)) {
        iconPack = response.pack
        iconPackMessage = iconPack ? iconPack.name + " · " + iconPack.icons.length + " icons" : "No icon pack loaded."
      } else {
        iconPack = null
        iconPackMessage = "Could not read the installed icon pack."
      }
      return
    }

    if (action === "icon-import") {
      if (response.schema === 1 && response.ok === true && typeof response.name === "string"
          && Number.isInteger(response.count) && response.count >= 0 && response.count <= 2048) {
        iconPackMessage = "Loaded " + response.name + " · " + response.count + " icons"
        loadCustomIconPack()
      } else {
        iconPackMessage = response.error === "invalid_icon_pack"
          ? "That file is not a valid Aegis icon pack."
          : "Could not load the icon pack."
      }
      return
    }

    if (action === "icon-clear") {
      if (response.schema === 1 && response.ok === true) loadCustomIconPack()
      else iconPackMessage = "Could not remove the icon pack."
      return
    }

    if (action === "list") {
      if (response.schema === 1 && response.ok === true && Array.isArray(response.keys) && response.keys.length <= 16 && response.keys.every(function(key) {
        return key && typeof key.keyId === "string" && /^[A-Za-z0-9:_-]{1,128}$/.test(key.keyId)
          && typeof key.title === "string" && key.title.length <= 128
          && !/[\u0000-\u001f\u007f-\u009f]/.test(key.title)
          && typeof key.locked === "boolean"
          && typeof key.error === "string" && ["", "incorrect_password", "oath_unavailable"].indexOf(key.error) >= 0
          && Array.isArray(key.accounts) && key.accounts.length <= 256
          && key.accounts.every(function(account) {
            return account && typeof account.id === "string" && /^(?:[0-9a-fA-F]{2}){1,512}$/.test(account.id)
              && typeof account.issuer === "string" && account.issuer.length <= 128
              && typeof account.name === "string" && account.name.length <= 128
              && !/[\u0000-\u001f\u007f-\u009f]/.test(account.issuer + account.name)
              && (account.type === "TOTP" || account.type === "HOTP")
              && Number.isInteger(account.period) && account.period >= 1 && account.period <= 3600
              && typeof account.touchRequired === "boolean"
          })
      })) {
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
      if (response.schema !== 1) {
        statusText = "Could not read the YubiKey response."
        return
      }
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
      if (response.copied !== true || (response.type !== "TOTP" && response.type !== "HOTP")) {
        statusText = "Could not copy the code to the clipboard."
        return
      }
      statusText = "Copied " + String(displayLabel || "code") + " to clipboard."
    }
  }

  function errorMessage(code) {
    if (code === "missing_dependency") return "Install yubikey-manager, bubblewrap, and wl-clipboard, then reopen the panel."
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
      schema: 1,
      keyId: keyId,
      accountId: account.id,
      password: String(passwords[keyId] || ""),
      clearTimeoutSeconds: clearTimeoutSeconds
    }, accountLabel)
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
    if (Number(seconds) === 30) return "30 seconds · Recommended"
    return Number(seconds) === 60 ? "1 minute" : "2 minutes"
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

  implicitWidth: connectedKeyCount > 0 ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  Timer {
    interval: 3000
    repeat: true
    running: true
    onTriggered: root.scanDevices()
  }

  Component.onCompleted: {
    Qt.callLater(scanDevices)
    Qt.callLater(loadCustomIconPack)
  }

  FileDialog {
    id: iconPackDialog
    title: "Load an Aegis icon pack"
    fileMode: FileDialog.OpenFile
    nameFilters: ["Aegis icon packs (*.zip)", "ZIP archives (*.zip)"]
    onAccepted: root.importCustomIconPack(selectedFile)
  }

  function scanDevices() {
    if (deviceScanProcess && deviceScanProcess.running) return
    var process = deviceScanComponent.createObject(root)
    if (!process) return
    deviceScanProcess = process
    process.environment = bridgeEnvironment()
    process.clearEnvironment = true
    process.command = sandboxCommand("scan")
    process.running = true
  }

  Component {
    id: deviceScanComponent
    Process {
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: root.updateDevices(text)
      }
      onExited: {
        if (root.deviceScanProcess === this)
          root.deviceScanProcess = null
        Qt.callLater(function() { destroy() })
      }
    }
  }

  Component {
    id: requestComponent
    Process {
      id: bridgeProcess
      property string actionName: ""
      property var requestPayload: ({})
      property string displayLabel: ""
      property string extraFilePath: ""
      property bool responseReceived: false
      environment: root.bridgeEnvironment()
      clearEnvironment: true
      stdinEnabled: true
      stdout: SplitParser {
        onRead: function(line) {
          bridgeProcess.responseReceived = true
          root.requestBusy = false
          if (root.activeRequestProcess === bridgeProcess) {
            root.activeRequestProcess = null
            root.activeRequest = ""
          }
          root.handleBridgeOutput(bridgeProcess.actionName, bridgeProcess.requestPayload, line, bridgeProcess.displayLabel)
          if (bridgeProcess.actionName === "code" && root.statusText.indexOf("Copied ") === 0)
            root.clipboardProcess = bridgeProcess
        }
      }
      onStarted: {
        write(JSON.stringify(requestPayload) + "\n")
        stdinEnabled = false
        requestPayload.password = ""
        requestPayload.passwords = ({})
      }
      onExited: {
        if (root.clipboardProcess === bridgeProcess)
          root.clipboardProcess = null
        if (!responseReceived) {
          if (root.activeRequestProcess === bridgeProcess)
            root.statusText = "The isolated YubiKey helper could not start. Check systemd, bubblewrap, PC/SC, and Wayland."
          root.requestBusy = false
          if (root.activeRequestProcess === bridgeProcess) {
            root.activeRequestProcess = null
            root.activeRequest = ""
          }
        }
        if (root.refreshPending && !root.requestBusy) {
          root.refreshPending = false
          Qt.callLater(root.refreshAccounts)
        }
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
          textFormat: Text.PlainText
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
        textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
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
                    maximumLength: 1024
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
                  textFormat: Text.PlainText
                  visible: keyGroup.error === "incorrect_password"
                  text: "Password not accepted. Try again."
                  color: root.urgentColor
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  textFormat: Text.PlainText
                  visible: keyGroup.error === "oath_unavailable"
                  text: "OATH is unavailable on this key."
                  color: root.mutedForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Repeater {
                  model: keyGroup.accounts || []

                  delegate: Item {
                    id: accountButton
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: modelData.type === "HOTP" ? Style.space(44) : (modelData.touchRequired ? Style.space(40) : Style.space(32))
                    Accessible.name: "Copy " + (modelData.issuer ? modelData.issuer + " " : "") + modelData.name

                    Rectangle {
                      anchors.fill: parent
                      color: accountMouse.pressed ? Style.pressedFill : (accountMouse.containsMouse ? Style.hoverFill : "transparent")
                      border.color: accountMouse.containsMouse ? Style.hoverBorderColor : Color.popups.border
                      border.width: Style.normalBorderWidth
                    }

                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(8)
                      spacing: Style.space(8)

                      Item {
                        id: accountIcon
                        implicitWidth: Style.space(18)
                        implicitHeight: Style.space(18)
                        Layout.preferredWidth: Style.space(18)
                        Layout.preferredHeight: Style.space(18)

                        readonly property var brand: root.accountBrand(modelData)
                        readonly property string iconSource: root.customIconUrl(modelData)

                        Rectangle {
                          anchors.fill: parent
                          visible: accountIcon.iconSource === "" && accountIcon.brand[0] !== ""
                          radius: Style.space(4)
                          color: parent.brand[1] === "#ffffff" ? "#263041" : Qt.darker(parent.brand[1], 2.6)
                          border.color: Qt.darker(parent.brand[1], 1.7)
                          border.width: 1
                        }

                        Text {
                          textFormat: Text.PlainText
                          anchors.centerIn: parent
                          visible: accountIcon.iconSource === "" && accountIcon.brand[0] !== ""
                          text: parent.brand[0]
                          color: parent.brand[1]
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: parent.brand[0].length > 1 ? Style.space(8) : Style.space(12)
                          font.weight: Font.Bold
                        }

                        Image {
                          anchors.fill: parent
                          visible: accountIcon.iconSource !== ""
                          source: accountIcon.iconSource
                          sourceSize: Qt.size(Style.space(18), Style.space(18))
                          fillMode: Image.PreserveAspectFit
                          asynchronous: true
                          cache: true
                        }

                        ThemedIcon {
                          anchors.fill: parent
                          visible: accountIcon.iconSource === "" && accountIcon.brand[0] === ""
                          source: Qt.resolvedUrl(modelData.type === "HOTP" ? "icons/hotp.svg" : "icons/totp.svg")
                          tint: Color.foreground
                        }
                      }

                      ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        Text {
                          textFormat: Text.PlainText
                          Layout.fillWidth: true
                          text: (modelData.issuer ? modelData.issuer + " · " : "") + modelData.name
                          color: Color.foreground
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.bodySmall
                          elide: Text.ElideRight
                          horizontalAlignment: Text.AlignLeft
                        }

                        Text {
                          textFormat: Text.PlainText
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
                          textFormat: Text.PlainText
                          Layout.alignment: Qt.AlignRight
                          text: modelData.type
                          color: modelData.type === "HOTP" ? root.urgentColor : root.mutedForeground
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.caption
                          font.weight: Font.DemiBold
                        }

                        Text {
                          textFormat: Text.PlainText
                          visible: modelData.type === "HOTP"
                          Layout.alignment: Qt.AlignRight
                          text: "Counter advances"
                          color: root.urgentColor
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }

                    MouseArea {
                      id: accountMouse
                      anchors.fill: parent
                      enabled: !root.requestBusy
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.copyAccount(keyGroup.keyId, accountButton.modelData)
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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
            Layout.preferredHeight: iconPackSettings.implicitHeight + contentTopInset + contentBottomInset

            ColumnLayout {
              id: iconPackSettings
              x: parent.contentLeftInset
              y: parent.contentTopInset
              width: parent.width - parent.contentLeftInset - parent.contentRightInset
              spacing: Style.space(5)

              Text {
                textFormat: Text.PlainText
                text: "Account icons"
                color: Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                font.weight: Font.DemiBold
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: root.iconPack
                  ? root.iconPack.name + " · " + root.iconPack.icons.length + " icons loaded"
                  : "Unknown issuers get a colored initial. Load an Aegis icon pack for service logos."
                color: root.mutedForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }

              RowLayout {
                Layout.fillWidth: true

                Button {
                  Layout.fillWidth: true
                  text: root.iconPack ? "Replace icon pack" : "Load icon pack"
                  enabled: !root.requestBusy
                  onClicked: iconPackDialog.open()
                }

                Button {
                  visible: root.iconPack !== null
                  text: "Remove"
                  enabled: !root.requestBusy
                  onClicked: root.removeCustomIconPack()
                }
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                visible: root.iconPackMessage !== ""
                text: root.iconPackMessage
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
            Layout.preferredHeight: clipboardSettings.implicitHeight + contentTopInset + contentBottomInset

            ColumnLayout {
              id: clipboardSettings
              x: parent.contentLeftInset
              y: parent.contentTopInset
              width: parent.width - parent.contentLeftInset - parent.contentRightInset
              spacing: Style.space(5)

              Text {
                textFormat: Text.PlainText
                text: "Clipboard"
                color: Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                font.weight: Font.DemiBold
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "Clear copied codes after. TOTP clears at expiry if sooner."
                color: root.mutedForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(5)

                Repeater {
                  model: root.clearTimeouts
                  delegate: Item {
                    id: timeoutOption
                    required property int modelData
                    property bool selected: root.clearTimeoutSeconds === modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: Style.space(38)
                    Accessible.role: Accessible.Button
                    Accessible.name: root.timeoutLabel(modelData)
                    Accessible.checked: selected

                    Rectangle {
                      anchors.fill: parent
                      color: timeoutOption.selected ? Color.popups.border : "transparent"
                      border.color: Color.popups.border
                      border.width: Style.normalBorderWidth
                    }

                    Column {
                      anchors.centerIn: parent
                      spacing: 1

                      Text {
                        textFormat: Text.PlainText
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: timeoutOption.modelData === 30 ? "30 seconds" : (timeoutOption.modelData === 60 ? "1 minute" : "2 minutes")
                        color: Color.foreground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        textFormat: Text.PlainText
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: timeoutOption.modelData === 30
                        text: "Recommended"
                        color: root.mutedForeground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.saveSetting("clipboardClearSeconds", timeoutOption.modelData)
                    }
                  }
                }
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
                textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
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
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                text: "Security"
                color: Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                font.weight: Font.DemiBold
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "OATH passwords stay in memory while the connected-key inventory is unchanged."
                color: root.mutedForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
              Text {
                textFormat: Text.PlainText
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
